import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/analytics_service.dart';
import '../services/notification_service.dart';

/// Step 2 of the post-onboarding flow: notification permission.
///
/// Continue triggers the native OS prompt for notifications and then
/// advances to the paywall — granted or not. The only notification this
/// app will ever fire is the single Day-3 trial-ending reminder.
class NotificationPermissionScreen extends StatefulWidget {
  const NotificationPermissionScreen({super.key});

  @override
  State<NotificationPermissionScreen> createState() =>
      _NotificationPermissionScreenState();
}

class _NotificationPermissionScreenState
    extends State<NotificationPermissionScreen>
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
    unawaited(AnalyticsService.instance.screen('notif_permission_screen'));
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

    try {
      // System dialog. Result is intentionally ignored — the user is
      // advanced to the paywall either way.
      await NotificationService.instance.requestPermission();
    } catch (_) {
      // Silent — analytics layer logs nothing here, and a failed system
      // dialog must never block the funnel.
    }

    if (!mounted) return;
    HapticFeedback.lightImpact();
    Navigator.of(context).pushReplacementNamed('/paywall');
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
                child: Column(
                  children: [
                    const Spacer(),
                    _buildHero(),
                    const SizedBox(height: 22),
                    _buildPrivacyChip(),
                    const Spacer(),
                    _buildCta(),
                    const SizedBox(height: 16),
                    _buildStepIndicator(),
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
          child: const Icon(Icons.notifications_active_outlined,
              color: _accent, size: 32),
        ),
        const SizedBox(height: 22),
        const Text(
          'Enable notifications',
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
            'We only ever send one notification — a friendly reminder when your free trial is ending. Nothing else.',
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
              'Reminders are scheduled locally on this device.',
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

  Widget _buildStepIndicator() {
    const active = 1;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(3, (i) {
        final isActive = i == active;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: isActive ? 20 : 6,
          height: 6,
          decoration: BoxDecoration(
            color:
                isActive ? _accent : const Color(0xFF3A3A3C),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}
