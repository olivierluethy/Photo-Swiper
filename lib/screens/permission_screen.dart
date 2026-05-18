import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../services/analytics_events.dart';
import '../services/analytics_service.dart';

/// Step 1 of the post-onboarding flow: photo-library permission.
///
/// The user cannot skip — Continue is the only action. Tapping it triggers
/// the native iOS permission dialog and advances to the notification step
/// regardless of the user's choice. If the user denies, photos simply won't
/// load until they re-enable access from iOS Settings later; we don't
/// dead-end them here because there's no way out of the onboarding flow.
class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen>
    with SingleTickerProviderStateMixin {
  bool _requesting = false;

  late final AnimationController _entry;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  static const Color _bg = Color(0xFF0D0D0D);
  static const Color _accent = Color(0xFF6B4EFF);
  static const Color _privacy = Color(0xFF0A84FF);
  static const Color _muted = Color(0xFF8E8E93);

  @override
  void initState() {
    super.initState();
    unawaited(AnalyticsService.instance.screen('permission_screen'));
    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _fade = CurvedAnimation(parent: _entry, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entry, curve: Curves.easeOutCubic));
    WidgetsBinding.instance.addPostFrameCallback((_) => _entry.forward());
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  Future<void> _onContinue() async {
    if (_requesting) return;
    setState(() => _requesting = true);

    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.photoPermissionRequested,
    ));

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final ps = await PhotoManager.requestPermissionExtend();
        if (ps.isAuth || ps.hasAccess) {
          unawaited(AnalyticsService.instance.track(
            AnalyticsEvents.photoPermissionGranted,
            properties: const {'source': 'prompt'},
          ));
        } else {
          unawaited(AnalyticsService.instance.track(
            AnalyticsEvents.photoPermissionDenied,
          ));
        }
      } catch (e) {
        unawaited(AnalyticsService.instance.track(
          AnalyticsEvents.errorOccurred,
          properties: {
            'error_type': e.runtimeType.toString(),
            'context': 'permission_request',
          },
        ));
      }
    }

    if (!mounted) return;
    HapticFeedback.lightImpact();
    // Regardless of grant/deny we move forward — the user is not allowed
    // to remain on this screen indefinitely. Photos is the last permission
    // step, so we hand off to the benefits showcase.
    Navigator.of(context).pushReplacementNamed('/benefits');
  }

  @override
  Widget build(BuildContext context) {
    // The user is mid-onboarding; back gestures must not let them out.
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
                child: Column(
                  children: [
                    const Spacer(),
                    _buildHero(),
                    const SizedBox(height: 22),
                    _buildPrivacyChip(),
                    const Spacer(),
                    _buildCta(),
                    const SizedBox(height: 16),
                    _buildStepIndicator(activeStep: 1),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHero() {
    return Column(
      children: [
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
      ],
    );
  }

  Widget _buildPrivacyChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: _privacy.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _privacy.withOpacity(0.25), width: 1),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline_rounded, color: _privacy, size: 16),
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
    );
  }

  Widget _buildCta() {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton(
        onPressed: _requesting ? null : _onContinue,
        style: ElevatedButton.styleFrom(
          backgroundColor: _accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: _accent.withOpacity(0.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          elevation: 0,
        ),
        child: _requesting
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation(Colors.white),
                ),
              )
            : const Text(
                'Continue',
                style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
      ),
    );
  }

  Widget _buildStepIndicator({required int activeStep}) {
    // 2 dots — step 1 = notifications (done), step 2 = photos (active).
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
