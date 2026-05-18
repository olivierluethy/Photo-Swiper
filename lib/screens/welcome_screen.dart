import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/analytics_service.dart';
import 'paywall_screen.dart';
import 'permission_screen.dart';

/// Soft premium nudge shown right after the 3 intro slides. We thank the
/// user, plant the Premium seed, and let them continue — no immediate
/// pricing, no commitment. The actual subscription decision happens deep
/// in the app, after the user has tasted the experience.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  static const Color _bg = Color(0xFF0D0D0D);
  static const Color _accent = Color(0xFF6B4EFF);
  static const Color _accentSoft = Color(0xFF8B7BFF);
  static const Color _muted = Color(0xFF8E8E93);

  @override
  void initState() {
    super.initState();
    unawaited(AnalyticsService.instance.screen('welcome_screen'));
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    WidgetsBinding.instance.addPostFrameCallback((_) => _ctrl.forward());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onContinue() async {
    HapticFeedback.lightImpact();
    Navigator.of(context).pushReplacement(
      _fadeThroughRoute(const PermissionScreen()),
    );
  }

  Future<void> _onTryPremium() async {
    HapticFeedback.selectionClick();
    // Push the paywall on top — if the user subscribes or closes, we
    // continue to permissions afterwards. We never block them here.
    await Navigator.of(context).push<bool>(
      _fadeThroughRoute(
        const PaywallScreen(source: PaywallSource.onboarding),
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      _fadeThroughRoute(const PermissionScreen()),
    );
  }

  /// Smooth crossfade transition — feels more "guided" than the default
  /// platform slide on the welcome → permission hand-off.
  PageRouteBuilder<T> _fadeThroughRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      transitionsBuilder: (_, animation, __, child) {
        final fade =
            CurvedAnimation(parent: animation, curve: Curves.easeOut);
        return FadeTransition(opacity: fade, child: child);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fade,
          child: SlideTransition(
            position: _slide,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 32),
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  _buildHero(),
                  const Spacer(),
                  _buildMessage(),
                  const Spacer(flex: 2),
                  _buildCtas(),
                  const SizedBox(height: 12),
                  const Text(
                    'You can manage or cancel anytime in Settings.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF6E6E73),
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ],
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
          width: 92,
          height: 92,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [_accent, _accentSoft],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: _accent.withOpacity(0.40),
                blurRadius: 36,
                spreadRadius: 4,
              ),
            ],
          ),
          child: const Icon(
            Icons.favorite_rounded,
            color: Colors.white,
            size: 44,
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          "You're all set",
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 30,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Thanks for installing FlickClean.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _muted,
            fontSize: 15,
            height: 1.45,
          ),
        ),
      ],
    );
  }

  Widget _buildMessage() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        color: const Color(0xFF15151A),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF26262C), width: 1),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _accent.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'FLICKCLEAN PREMIUM',
                  style: TextStyle(
                    color: _accentSoft,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            "We'd love for you to try\nFlickClean Premium.",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w600,
              height: 1.3,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Unlimited swiping, faster cleanup, and every new tool we ship — cancel anytime.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _muted,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCtas() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: _onContinue,
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              elevation: 0,
            ),
            child: const Text(
              'Continue',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 44,
          child: TextButton(
            onPressed: _onTryPremium,
            style: TextButton.styleFrom(
              foregroundColor: _accentSoft,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: const Text(
              'See Premium plans',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
