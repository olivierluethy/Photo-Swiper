import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/analytics_service.dart';

/// Benefits showcase shown after permissions and before the paywall. We
/// celebrate the user, then list everything they can do "for free" before
/// presenting the trial timeline + plan tiles.
///
/// This is a distinct step in the navigation — not part of the paywall —
/// so the moment lands as a positive reveal rather than a sales pitch.
class BenefitsScreen extends StatefulWidget {
  const BenefitsScreen({super.key});

  @override
  State<BenefitsScreen> createState() => _BenefitsScreenState();
}

class _BenefitsScreenState extends State<BenefitsScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entry;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  static const Color _bg = Color(0xFF0D0D0D);
  static const Color _surface = Color(0xFF15151A);
  static const Color _accent = Color(0xFF6B4EFF);
  static const Color _accentSoft = Color(0xFF8B7BFF);
  static const Color _muted = Color(0xFF8E8E93);
  static const Color _check = Color(0xFF30D158);

  static const _benefits = [
    _Benefit(
      icon: Icons.all_inclusive_rounded,
      title: 'Unlimited photo swiping',
      subtitle: 'Sort your entire library — no daily caps.',
    ),
    _Benefit(
      icon: Icons.flash_on_rounded,
      title: 'Faster cleanup',
      subtitle: 'Smart previews and instant batching.',
    ),
    _Benefit(
      icon: Icons.sd_storage_rounded,
      title: 'Free up gigabytes',
      subtitle: 'See exactly how much space you reclaim.',
    ),
    _Benefit(
      icon: Icons.shield_rounded,
      title: '100% on-device privacy',
      subtitle: 'Your photos never leave your phone.',
    ),
    _Benefit(
      icon: Icons.workspace_premium_rounded,
      title: 'Every new tool we ship',
      subtitle: 'All future features included.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(AnalyticsService.instance.screen('benefits_screen'));
    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 540),
    );
    _fade = CurvedAnimation(parent: _entry, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entry, curve: Curves.easeOutCubic));
    WidgetsBinding.instance.addPostFrameCallback((_) => _entry.forward());
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  void _onContinue() {
    HapticFeedback.lightImpact();
    unawaited(AnalyticsService.instance.track(
      'benefits_continue_tapped',
    ));
    Navigator.of(context).pushReplacementNamed('/paywall');
  }

  @override
  Widget build(BuildContext context) {
    // Block back gesture — the onboarding funnel is sequential and the
    // benefits screen is a one-way transition into the paywall.
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
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 24),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        physics: const BouncingScrollPhysics(),
                        children: [
                          const SizedBox(height: 12),
                          _buildHero(),
                          const SizedBox(height: 22),
                          _buildBenefitsCard(),
                          const SizedBox(height: 16),
                          _buildFreeBanner(),
                        ],
                      ),
                    ),
                    _buildCta(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─── Hero ───────────────────────────────────────────────────────────────
  Widget _buildHero() {
    return Column(
      children: [
        Container(
          width: 76,
          height: 76,
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
                blurRadius: 30,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Icon(Icons.celebration_rounded,
              color: Colors.white, size: 36),
        ),
        const SizedBox(height: 20),
        const Text(
          'You can now use this app\nfor free',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w700,
            height: 1.18,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 10),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            "You're all set — here's everything you can do with FlickClean, "
            'with no limitations.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _muted,
              fontSize: 14.5,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }

  // ─── Benefits card ──────────────────────────────────────────────────────
  Widget _buildBenefitsCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < _benefits.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            _BenefitRow(benefit: _benefits[i], check: _check),
          ],
        ],
      ),
    );
  }

  // ─── Free banner ────────────────────────────────────────────────────────
  Widget _buildFreeBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _check.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _check.withOpacity(0.30), width: 1),
      ),
      child: Row(
        children: const [
          Icon(Icons.lock_open_rounded, color: _check, size: 18),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'You can now use this app completely free with no limitations.',
              style: TextStyle(
                color: Color(0xFFD7E9DC),
                fontSize: 12.8,
                fontWeight: FontWeight.w500,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── CTA ────────────────────────────────────────────────────────────────
  Widget _buildCta() {
    return SizedBox(
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
          'Great, Let Me Start For Free',
          style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _Benefit {
  final IconData icon;
  final String title;
  final String subtitle;
  const _Benefit({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
}

class _BenefitRow extends StatelessWidget {
  final _Benefit benefit;
  final Color check;
  const _BenefitRow({required this.benefit, required this.check});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: check.withOpacity(0.14),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(benefit.icon, color: check, size: 19),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                benefit.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                benefit.subtitle,
                style: const TextStyle(
                  color: Color(0xFFB7B9BD),
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
