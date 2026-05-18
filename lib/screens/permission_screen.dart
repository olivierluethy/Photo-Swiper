import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../services/analytics_events.dart';
import '../services/analytics_service.dart';

/// Step 2 of the post-onboarding flow: photo-library permission.
///
/// Behaviour by initial state (queried with `PhotoManager.getPermissionState`
/// before the user taps anything):
///
///   • notDetermined        → tapping Continue raises the native iOS
///                            permission dialog ("FlickClean Would Like
///                            to Access Your Photos"). When the user
///                            responds we either advance (Authorized /
///                            Limited) or surface the denied view
///                            (Don't Allow).
///   • authorized / limited → tapping Continue simply advances; iOS would
///                            not re-prompt in this case anyway.
///   • denied / restricted  → the request view is replaced *immediately*
///                            with the denied view. We can't re-show the
///                            system dialog from a denied state; the user
///                            must change the setting in iOS Settings.
///
/// The denied view stays in place until the user grants access (via
/// Settings — we auto-re-check on resume) or taps Continue, which advances
/// to `/benefits`. Every code path requires an explicit user response
/// before navigation; we never silently bypass the dialog.
class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  bool _requesting = false;
  bool _showDeniedFallback = false;
  PermissionState? _currentState;

  late final AnimationController _entry;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  // Read access for both reading photos *and* invoking the iOS deletion
  // editor (PHAssetChangeRequest). photo_manager's default is also
  // readWrite, but the SDK has shipped builds that varied on this — making
  // the request explicit pins the access level we actually need.
  static const _permRequestOption = PermissionRequestOption(
    iosAccessLevel: IosAccessLevel.readWrite,
  );

  static const Color _bg = Color(0xFF0D0D0D);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(AnalyticsService.instance.screen('permission_screen'));
    unawaited(AnalyticsService.instance
        .track(AnalyticsEvents.photoPermissionShown));
    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _fade = CurvedAnimation(parent: _entry, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entry, curve: Curves.easeOutCubic));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _entry.forward();
      _readInitialState();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _entry.dispose();
    super.dispose();
  }

  /// On the very first build we don't yet know whether iOS will prompt or
  /// already has a stored answer. Querying [getPermissionState] is a
  /// silent read — no dialog. If we learn the answer is already "denied",
  /// we render the denied view up-front so the user isn't shown a
  /// Continue button that would do nothing.
  Future<void> _readInitialState() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final ps = await PhotoManager.getPermissionState(
      requestOption: _permRequestOption,
    );
    if (!mounted) return;
    setState(() {
      _currentState = ps;
      if (_isDeniedState(ps)) _showDeniedFallback = true;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user might have flipped the toggle in iOS Settings → Privacy →
    // Photos and come back. Re-check silently so we can either auto-
    // advance (now granted) or leave the denied view in place.
    if (state == AppLifecycleState.resumed && _showDeniedFallback) {
      _recheckAfterSettings();
    }
  }

  Future<void> _recheckAfterSettings() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final ps = await PhotoManager.getPermissionState(
      requestOption: _permRequestOption,
    );
    if (!mounted) return;
    if (_isGrantedState(ps)) {
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.photoPermissionAccepted,
        properties: const {'source': 'settings_return'},
      ));
      HapticFeedback.lightImpact();
      _advance(
        funnelStatus:
            ps == PermissionState.limited ? 'partially_granted' : 'granted',
      );
    } else {
      setState(() => _currentState = ps);
    }
  }

  bool _isGrantedState(PermissionState ps) =>
      ps == PermissionState.authorized || ps == PermissionState.limited;

  bool _isDeniedState(PermissionState ps) =>
      ps == PermissionState.denied || ps == PermissionState.restricted;

  void _advance({String funnelStatus = 'granted'}) {
    // Step 2 was photos; on to the benefits showcase. Emit both the
    // section-completed marker and the funnel-step event so the dashboard
    // can answer "how many users finished both permissions?" in one query.
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.permissionsSectionCompleted,
    ));
    unawaited(AnalyticsService.instance.funnelStep(
      FunnelSteps.permissions,
      event: AnalyticsEvents.funnelStepPermissions,
      status: funnelStatus,
    ));
    Navigator.of(context).pushReplacementNamed('/benefits');
  }

  Future<void> _onContinue() async {
    if (_requesting) return;

    // Non-mobile platforms (web/desktop test runs) can't request library
    // permission via photo_manager; just continue the flow.
    if (!Platform.isAndroid && !Platform.isIOS) {
      _advance();
      return;
    }

    setState(() => _requesting = true);
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.photoPermissionRequested,
    ));

    // If iOS already has an answer on file, requestPermissionExtend will
    // *not* re-show the dialog. To keep our contract — "do not proceed
    // until the user has responded" — branch on the current state.
    final preState = _currentState ??
        await PhotoManager.getPermissionState(
          requestOption: _permRequestOption,
        );

    if (_isDeniedState(preState)) {
      // System will stay silent. Show the denied view so the user has a
      // path to Settings instead of feeling like the button did nothing.
      if (!mounted) return;
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.photoPermissionDenied,
      ));
      setState(() {
        _requesting = false;
        _showDeniedFallback = true;
      });
      return;
    }

    if (_isGrantedState(preState)) {
      _advance(funnelStatus: 'granted');
      return;
    }

    // notDetermined → this call shows Apple's native dialog. We await the
    // user's response (Full Access / Limited / Don't Allow) before doing
    // anything else.
    try {
      final ps = await PhotoManager.requestPermissionExtend(
        requestOption: _permRequestOption,
      );
      if (!mounted) return;
      setState(() => _currentState = ps);

      if (_isGrantedState(ps)) {
        unawaited(AnalyticsService.instance.track(
          AnalyticsEvents.photoPermissionAccepted,
          properties: {
            'source': 'prompt',
            'level':
                ps == PermissionState.limited ? 'limited' : 'full',
          },
        ));
        HapticFeedback.lightImpact();
        _advance(
          funnelStatus: ps == PermissionState.limited
              ? 'partially_granted'
              : 'granted',
        );
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
      if (!mounted) return;
      // On an unexpected error the safest option is to surface the denied
      // view; the user can still get to Settings or Continue from there.
      setState(() {
        _requesting = false;
        _showDeniedFallback = true;
      });
    }
  }

  void _openSettings() {
    HapticFeedback.selectionClick();
    PhotoManager.openSetting();
  }

  void _continueDespiteDenial() {
    HapticFeedback.selectionClick();
    _advance(funnelStatus: 'denied');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: FadeTransition(
            opacity: _fade,
            child: SlideTransition(
              position: _slide,
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
                          onContinue: _continueDespiteDenial,
                        )
                      : _RequestView(
                          key: const ValueKey('request'),
                          requesting: _requesting,
                          onContinue: _onContinue,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Request view ─────────────────────────────────────────────────────────────

class _RequestView extends StatelessWidget {
  final bool requesting;
  final VoidCallback onContinue;
  const _RequestView({
    super.key,
    required this.requesting,
    required this.onContinue,
  });

  static const Color _accent = Color(0xFF6B4EFF);
  static const Color _privacy = Color(0xFF0A84FF);
  static const Color _muted = Color(0xFF8E8E93);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Spacer(),
        Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            color: _accent.withOpacity(0.10),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.photo_library_outlined,
              color: _accent, size: 34),
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
              color: _muted,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 22),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: _privacy.withOpacity(0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _privacy.withOpacity(0.25), width: 1),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline_rounded,
                  color: _privacy, size: 16),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Your photos stay on this device. Always.',
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
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              disabledBackgroundColor: _accent.withOpacity(0.5),
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
                      valueColor:
                          AlwaysStoppedAnimation(Colors.white),
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
        const SizedBox(height: 16),
        _StepIndicator(activeStep: 1),
      ],
    );
  }
}

// ─── Denied fallback ──────────────────────────────────────────────────────────

class _DeniedView extends StatelessWidget {
  final VoidCallback onOpenSettings;
  final VoidCallback onContinue;
  const _DeniedView({
    super.key,
    required this.onOpenSettings,
    required this.onContinue,
  });

  static const Color _accent = Color(0xFF6B4EFF);
  static const Color _danger = Color(0xFFFF453A);
  static const Color _muted = Color(0xFF8E8E93);
  static const Color _mutedSoft = Color(0xFF6E6E73);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Spacer(),
        Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            color: _danger.withOpacity(0.10),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.no_photography_outlined,
              color: _danger, size: 32),
        ),
        const SizedBox(height: 22),
        const Text(
          'Photo access is off',
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
            "Without access we can't show your photos, so swiping and cleanup won't work. "
            'Open Settings to turn on “All Photos” for FlickClean. Your media still stays on this device.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _muted,
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
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
              elevation: 0,
            ),
            child: const Text(
              'Open Settings',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: onContinue,
          child: const Text(
            'Continue without photos',
            style: TextStyle(
              color: _mutedSoft,
              fontSize: 13.5,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _StepIndicator(activeStep: 1),
      ],
    );
  }
}

// ─── Step indicator ───────────────────────────────────────────────────────────

class _StepIndicator extends StatelessWidget {
  final int activeStep;
  const _StepIndicator({required this.activeStep});

  static const Color _accent = Color(0xFF6B4EFF);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(2, (i) {
        final active = i == activeStep;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: active ? 20 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: active ? _accent : const Color(0xFF3A3A3C),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}
