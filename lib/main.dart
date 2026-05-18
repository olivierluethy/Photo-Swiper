import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/benefits_screen.dart';
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

  unawaited(AnalyticsService.instance.track(AnalyticsEvents.appOpened));
  unawaited(AnalyticsService.instance.emitSessionStarted());

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
  // First / incomplete onboarding:
  //   /intro → /notif-permission → /permission → /benefits → /paywall → /home
  // Returning launch (onboarding complete):
  //   /launchgate awaits the RevenueCat SDK then routes to /home (still pro)
  //   or the mandatory /paywall (subscription lapsed). The user can never
  //   reach /home without an active entitlement.
  final initialRoute = PreferencesService.instance.isOnboardingComplete
      ? '/launchgate'
      : '/intro';
  runApp(PhotoSwiperApp(initialRoute: initialRoute));
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
    final analytics = AnalyticsService.instance;
    if (state == AppLifecycleState.paused) {
      final screen = analytics.currentScreen;
      unawaited(analytics.track(AnalyticsEvents.appBackgrounded));
      // Dropoff classification: was the user mid-onboarding, mid-paywall,
      // or in the app proper? Each path emits a different drop-off event
      // so dashboard cohorts can filter cleanly without joining sessions.
      if (screen != null) {
        if (_onboardingScreens.contains(screen)) {
          unawaited(analytics.track(
            AnalyticsEvents.userClosedAppDuringOnboarding,
            properties: {
              'which_screen': screen,
              'time_spent_seconds': _secondsSinceScreenEntered(),
            },
          ));
          unawaited(analytics.dropOff(
            lastCompletedStep: _lastFunnelStepForOnboarding(screen),
            reason: FunnelDropOffReason.appClosed,
            extras: {'which_screen': screen},
          ));
        } else if (screen == 'paywall_screen') {
          unawaited(analytics.track(
            AnalyticsEvents.userClosedAppDuringPaywall,
            properties: {
              'time_spent_on_paywall_seconds':
                  _secondsSinceScreenEntered(),
              'plans_viewed': analytics.plansViewed,
            },
          ));
          unawaited(analytics.dropOff(
            lastCompletedStep: FunnelSteps.permissions,
            reason: FunnelDropOffReason.appClosed,
            extras: {'plans_viewed': analytics.plansViewed},
          ));
        }
      }
      unawaited(analytics.emitSessionEnded(finalScreen: screen));
    } else if (state == AppLifecycleState.resumed) {
      // Rotate the session id so the next batch of events is grouped
      // separately in the dashboard.
      analytics.rotateSession();
      unawaited(analytics.emitSessionStarted());
    }
  }

  static const _onboardingScreens = {
    'intro_screen',
    'notif_permission_screen',
    'permission_screen',
    'benefits_screen',
  };

  int _lastFunnelStepForOnboarding(String screen) {
    switch (screen) {
      case 'intro_screen':
        return 0; // hasn't yet completed any step
      case 'notif_permission_screen':
        return FunnelSteps.introSlides;
      case 'permission_screen':
        return FunnelSteps.introSlides;
      case 'benefits_screen':
        return FunnelSteps.permissions;
      default:
        return 0;
    }
  }

  int _secondsSinceScreenEntered() =>
      AnalyticsService.instance.secondsOnCurrentScreen;

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
        '/notif-permission': (_) => const NotificationPermissionScreen(),
        '/permission': (_) => const PermissionScreen(),
        '/benefits': (_) => const BenefitsScreen(),
        '/paywall': (_) =>
            const PaywallScreen(source: PaywallSource.onboarding),
        '/launchgate': (_) => const LaunchGate(),
        '/home': (_) => const HomeScreen(),
      },
    );
  }
}
