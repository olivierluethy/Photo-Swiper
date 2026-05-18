import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../services/analytics_events.dart';
import '../services/analytics_service.dart';
import '../services/preferences_service.dart';

/// Soft photo-library permission step. Shown after the welcome / premium
/// nudge. The tone is intentionally quiet — small text, low-contrast
/// background — and the privacy promise is the focal point. No paywall
/// gating happens here; the actual subscription decision is deferred
/// until the user is deep inside the app.
class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  bool _requesting = false;
  bool _silentChecking = false;

  // True once the user has explicitly denied and we've shown the fallback.
  // Used to gate the Settings-return re-check so we don't fire it on every
  // unrelated app-resume event.
  bool _showDeniedFallback = false;

  late final AnimationController _entry;
  late final Animation<double> _fade;

  static const Color _bg = Color(0xFF0D0D0D);
  static const Color _accent = Color(0xFF6B4EFF);
  static const Color _privacy = Color(0xFF0A84FF);
  static const Color _muted = Color(0xFF8E8E93);
  static const Color _mutedSoft = Color(0xFF6E6E73);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(AnalyticsService.instance.screen('permission_screen'));

    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _fade = CurvedAnimation(parent: _entry, curve: Curves.easeOut);

    // Returning launches silently re-check permission and bounce straight
    // to /home. First-time launches stay on this screen and animate in.
    if (PreferencesService.instance.hasSeenOnboarding) {
      _silentChecking = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _silentCheck());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _entry.forward());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _entry.dispose();
    super.dispose();
  }

  // ─── Lifecycle ────────────────────────────────────────────────────────────
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _showDeniedFallback) {
      _recheckAfterSettings();
    }
  }

  Future<void> _silentCheck() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      _goHome();
      return;
    }
    final ps = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
    if (ps.isAuth || ps.hasAccess) {
      _goHome();
    } else {
      setState(() {
        _silentChecking = false;
        _showDeniedFallback = true;
      });
      _entry.forward();
    }
  }

  Future<void> _recheckAfterSettings() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
    if (ps.isAuth || ps.hasAccess) {
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.photoPermissionGranted,
        properties: const {'source': 'settings_return'},
      ));
      _goHome();
    }
  }

  // ─── Permission request ───────────────────────────────────────────────────
  Future<void> _requestPermission() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      _goHome();
      return;
    }

    setState(() {
      _requesting = true;
      _showDeniedFallback = false;
    });

    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.photoPermissionRequested,
    ));

    try {
      final ps = await PhotoManager.requestPermissionExtend();
      if (!mounted) return;

      if (ps.isAuth || ps.hasAccess) {
        unawaited(AnalyticsService.instance.track(
          AnalyticsEvents.photoPermissionGranted,
          properties: const {'source': 'prompt'},
        ));
        HapticFeedback.lightImpact();
        _goHome();
      } else {
        unawaited(AnalyticsService.instance.track(
          AnalyticsEvents.photoPermissionDenied,
        ));
        setState(() {
          _requesting = false;
          _showDeniedFallback = true;
        });
      }
    } catch (e) {
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.errorOccurred,
        properties: {
          'error_type': e.runtimeType.toString(),
          'context': 'permission_request',
        },
      ));
      if (mounted) _goHome();
    }
  }

  void _openSettings() {
    PhotoManager.openSetting();
  }

  /// Navigates to /home. No paywall gating — the deep-in-app trigger
  /// surfaces the subscription decision later, once the user has tasted
  /// the experience.
  void _goHome() {
    Navigator.of(context).pushReplacementNamed('/home');
  }

  // ─── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_silentChecking) {
      return const Scaffold(backgroundColor: _bg);
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goHome());
      return const Scaffold(
        backgroundColor: _bg,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fade,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 12, 28, 28),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: _showDeniedFallback
                  ? _DeniedView(
                      key: const ValueKey('denied'),
                      onOpenSettings: _openSettings,
                      onSkip: _goHome,
                    )
                  : _RequestView(
                      key: const ValueKey('request'),
                      requesting: _requesting,
                      onContinue: _requestPermission,
                      onSkip: _goHome,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Default view: soft, small-text ask ──────────────────────────────────────
class _RequestView extends StatelessWidget {
  final bool requesting;
  final VoidCallback onContinue;
  final VoidCallback onSkip;

  const _RequestView({
    super.key,
    required this.requesting,
    required this.onContinue,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(),
        // Soft glyph — restrained size, lower visual weight than the
        // earlier "permission gate" version.
        Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            color: _PermissionScreenState._accent.withOpacity(0.10),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.photo_library_outlined,
            color: _PermissionScreenState._accent,
            size: 34,
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          'Allow photo access',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            'FlickClean needs read access to your library so you can swipe through and tidy up your photos.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _PermissionScreenState._muted,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 22),
        // Privacy promise — small, low-key, but visually distinct.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: _PermissionScreenState._privacy.withOpacity(0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _PermissionScreenState._privacy.withOpacity(0.25),
              width: 1,
            ),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline_rounded,
                  color: _PermissionScreenState._privacy, size: 16),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Your media stays on this device. Always.',
                  style: TextStyle(
                    color: Color(0xFFCED2D8),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed: requesting ? null : onContinue,
            style: ElevatedButton.styleFrom(
              backgroundColor: _PermissionScreenState._accent,
              foregroundColor: Colors.white,
              disabledBackgroundColor:
                  _PermissionScreenState._accent.withOpacity(0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
              elevation: 0,
            ),
            child: requesting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : const Text(
                    'Allow Photos',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: requesting ? null : onSkip,
          child: const Text(
            'Maybe later',
            style: TextStyle(
              color: _PermissionScreenState._mutedSoft,
              fontSize: 13.5,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Denied fallback (also softened) ─────────────────────────────────────────
class _DeniedView extends StatelessWidget {
  final VoidCallback onOpenSettings;
  final VoidCallback onSkip;

  const _DeniedView({
    super.key,
    required this.onOpenSettings,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(),
        Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            color: const Color(0xFFFF453A).withOpacity(0.10),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.no_photography_outlined,
            color: Color(0xFFFF453A),
            size: 32,
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          'Access turned off',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 10),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Open Settings → Privacy → Photos → FlickClean and switch on “All Photos” to start cleaning.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _PermissionScreenState._muted,
              fontSize: 13.5,
              height: 1.55,
            ),
          ),
        ),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed: onOpenSettings,
            style: ElevatedButton.styleFrom(
              backgroundColor: _PermissionScreenState._accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
              elevation: 0,
            ),
            child: const Text(
              'Open Settings',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: onSkip,
          child: const Text(
            'Continue without photos',
            style: TextStyle(
              color: _PermissionScreenState._mutedSoft,
              fontSize: 13.5,
            ),
          ),
        ),
      ],
    );
  }
}
