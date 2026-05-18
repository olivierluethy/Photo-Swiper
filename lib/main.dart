import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'screens/intro_screen.dart';
import 'screens/launch_gate.dart';
import 'screens/notification_permission_screen.dart';
import 'screens/permission_screen.dart';
import 'screens/home_screen.dart';
import 'screens/paywall_screen.dart';
import 'services/analytics_events.dart';
import 'services/analytics_service.dart';
import 'services/notification_service.dart';
import 'services/preferences_service.dart';
import 'services/purchase_service.dart';
import 'services/review_prompt_service.dart';

/// When the current app session began. Used by [PhotoSwiperApp]'s lifecycle
/// observer to compute `session_duration_seconds` for `app_backgrounded`.
final DateTime _appOpenedAt = DateTime.now();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PreferencesService.instance.init();
  await AnalyticsService.instance.init();
  await ReviewPromptService.instance.recordAppLaunch();
  // RevenueCat init runs in the background — the permission gate awaits it
  // via [PurchaseService.waitForInit] before routing to home/paywall.
  unawaited(PurchaseService.instance.init());
  // Notifications are initialized eagerly so the post-purchase permission
  // request resolves instantly. We never schedule anything outside the
  // Day-3 trial reminder.
  unawaited(NotificationService.instance.init());

  // Attach non-PII super properties so every event is segmentable by app
  // version and platform. Non-blocking.
  unawaited(_registerSuperProperties());

  unawaited(AnalyticsService.instance.track(AnalyticsEvents.appOpened));

  // Lock to portrait
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // Force light status-bar icons on dark background
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
  ));
  // First launch: /intro → /permission → /notif-permission → /paywall → /home
  // Returning launch: /launchgate awaits the SDK then routes to /home (pro)
  //                   or the mandatory /paywall (non-pro). The user can
  //                   never reach /home without an active entitlement.
  final initialRoute = PreferencesService.instance.hasSeenOnboarding
      ? '/launchgate'
      : '/intro';
  runApp(PhotoSwiperApp(initialRoute: initialRoute));
}

Future<void> _registerSuperProperties() async {
  try {
    final info = await PackageInfo.fromPlatform();
    await AnalyticsService.instance.setUserProperties({
      'app_version': info.version,
      'platform': Platform.isIOS ? 'ios' : 'android',
    });
  } catch (_) {
    // Silent — analytics setup must never crash the app.
  }
}

class PhotoSwiperApp extends StatefulWidget {
  final String initialRoute;
  const PhotoSwiperApp({super.key, required this.initialRoute});

  @override
  State<PhotoSwiperApp> createState() => _PhotoSwiperAppState();
}

class _PhotoSwiperAppState extends State<PhotoSwiperApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      final seconds = DateTime.now().difference(_appOpenedAt).inSeconds;
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.appBackgrounded,
        properties: {'session_duration_seconds': seconds},
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FlickClean',
      debugShowCheckedModeBanner: false,

      // ── Pure dark theme ──────────────────────────────────────────────────────
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF6B4EFF),
          secondary: const Color(0xFF30D158),
          surface: const Color(0xFF1C1C1E),
          error: const Color(0xFFFF453A),
          onPrimary: Colors.white,
          onSurface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0D0D0D),
          surfaceTintColor: Colors.transparent,
          foregroundColor: Colors.white,
          elevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
          ),
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white),
        ),
      ),

      // ── Routes ───────────────────────────────────────────────────────────────
      initialRoute: widget.initialRoute,
      routes: {
        '/intro': (_) => const IntroScreen(),
        '/permission': (_) => const PermissionScreen(),
        '/notif-permission': (_) => const NotificationPermissionScreen(),
        '/paywall': (_) =>
            const PaywallScreen(source: PaywallSource.onboarding),
        '/launchgate': (_) => const LaunchGate(),
        '/home': (_) => const HomeScreen(),
      },
    );
  }
}
