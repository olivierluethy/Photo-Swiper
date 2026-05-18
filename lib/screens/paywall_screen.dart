import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/analytics_events.dart';
import '../services/analytics_service.dart';
import '../services/notification_service.dart';
import '../services/purchase_service.dart';

/// FlickClean's mandatory trial paywall.
///
/// Layout, top → bottom:
///   1. Hero copy framing the 3-day free trial
///   2. Vertical animated timeline showing Day 1 / Day 2 / Day 3
///   3. Two plan tiles. Tapping a tile is the purchase action — no
///      separate Continue button. The tap calls
///      `Purchases.purchasePackage(...)`, which surfaces Apple's native
///      StoreKit confirmation sheet (with the intro-offer details Apple
///      auto-renders from App Store Connect). On success we replace the
///      route stack with /home.
///
/// Onboarding/launch-gate presentations are blocking — no close button,
/// no back gesture. From `PaywallSource.settings` we honour close + pop.
class PaywallScreen extends StatefulWidget {
  /// Where the paywall is being presented from. Drives analytics and
  /// whether the close button + back gesture are enabled.
  final PaywallSource source;

  const PaywallScreen({
    super.key,
    this.source = PaywallSource.onboarding,
  });

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

enum PaywallSource { onboarding, launchGate, settings }

class _PaywallScreenState extends State<PaywallScreen>
    with TickerProviderStateMixin {
  final _service = PurchaseService.instance;

  Offering? _offering;
  bool _loadingOfferings = true;
  String? _purchasingId;
  bool _restoring = false;
  String? _errorMessage;

  bool _converted = false;
  bool _convertedViaTrial = false;
  final DateTime _shownAt = DateTime.now();

  late final AnimationController _entry;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  late final AnimationController _timeline;

  // ─── Design tokens ──────────────────────────────────────────────────────
  static const Color _bg = Color(0xFF0D0D0D);
  static const Color _accent = Color(0xFF6B4EFF);
  static const Color _accentSoft = Color(0xFF8B7BFF);
  static const Color _muted = Color(0xFF8E8E93);

  @override
  void initState() {
    super.initState();
    unawaited(AnalyticsService.instance.screen('paywall_screen'));
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.paywallShown,
      properties: {'source': widget.source.name},
    ));

    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _fade = CurvedAnimation(parent: _entry, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entry, curve: Curves.easeOutCubic));

    _timeline = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    _loadOfferings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _entry.forward();
      // Slight delay so the timeline plays once the page has settled,
      // making the progression feel intentional rather than racing the
      // page transition.
      Future<void>.delayed(const Duration(milliseconds: 220), () {
        if (mounted) _timeline.forward();
      });
    });
  }

  @override
  void dispose() {
    if (!_converted) {
      final seconds = DateTime.now().difference(_shownAt).inSeconds;
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.paywallDismissed,
        properties: {
          'seconds_visible': seconds,
          'source': widget.source.name,
        },
      ));
    }
    _entry.dispose();
    _timeline.dispose();
    super.dispose();
  }

  // ─── Loading ────────────────────────────────────────────────────────────
  Future<void> _loadOfferings() async {
    final cached = _service.currentOffering;
    if (cached != null && (cached.weekly != null || cached.annual != null)) {
      setState(() {
        _offering = cached;
        _loadingOfferings = false;
      });
      return;
    }
    final fetched = await _service.fetchOfferings();
    if (!mounted) return;
    setState(() {
      _offering = fetched;
      _loadingOfferings = false;
      if (fetched == null ||
          (fetched.weekly == null && fetched.annual == null)) {
        _errorMessage = _describeOfferingProblem();
      }
    });
  }

  String _describeOfferingProblem() {
    final err = _service.lastError;
    if (err != null) return err;
    if (_service.hasNoCurrentOffering) {
      return 'Subscription options are temporarily unavailable. Please try '
          'again in a moment.';
    }
    return 'Could not load subscription options. Please try again.';
  }

  // ─── Purchase ───────────────────────────────────────────────────────────
  // Tapping a plan tile is itself the purchase action. We dispatch
  // straight into RevenueCat, which raises Apple's native StoreKit sheet —
  // that sheet is what shows "3 days free, then $X" and collects the
  // confirmation. We don't simulate Apple's UI in our own.
  Future<void> _purchase(Package pkg) async {
    if (_purchasingId != null || _restoring) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _purchasingId = pkg.identifier;
      _errorMessage = null;
    });

    final framedAsTrial = pkg.packageType == PackageType.weekly;

    try {
      final success = await _service.purchase(pkg);
      if (!mounted) return;
      if (success) {
        _converted = true;
        _convertedViaTrial = _service.isInTrial;

        unawaited(AnalyticsService.instance.track(
          AnalyticsEvents.subscriptionStarted,
          properties: {
            'tier': _tierFor(pkg),
            'framed_as_trial': framedAsTrial,
            'in_trial': _service.isInTrial,
            'price': pkg.storeProduct.price,
            'currency_code': pkg.storeProduct.currencyCode,
            'source': widget.source.name,
          },
        ));
        HapticFeedback.heavyImpact();

        if (_convertedViaTrial) {
          unawaited(NotificationService.instance.requestPermission());
        }

        _exitOnSuccess();
      } else {
        setState(() => _purchasingId = null);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _purchasingId = null;
        _errorMessage = 'Purchase could not be completed. Please try again.';
      });
    }
  }

  void _exitOnSuccess() {
    if (widget.source == PaywallSource.settings) {
      Navigator.of(context).pop(true);
    } else {
      Navigator.of(context).pushReplacementNamed('/home');
    }
  }

  bool get _isMandatory => widget.source != PaywallSource.settings;

  Future<void> _onRestorePressed() async {
    if (_purchasingId != null || _restoring) return;
    HapticFeedback.selectionClick();
    setState(() {
      _restoring = true;
      _errorMessage = null;
    });
    final ok = await _service.restore();
    if (!mounted) return;
    if (ok) {
      _converted = true;
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.subscriptionRestored,
      ));
      _exitOnSuccess();
      return;
    }
    setState(() {
      _restoring = false;
      _errorMessage = 'No previous purchases found on this account.';
    });
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String _tierFor(Package pkg) {
    if (pkg.packageType == PackageType.weekly) return 'weekly';
    if (pkg.packageType == PackageType.annual) return 'yearly';
    return pkg.identifier;
  }

  void _onClosePressed() {
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(false);
  }

  // ─── Build ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isMandatory,
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: FadeTransition(
            opacity: _fade,
            child: SlideTransition(
              position: _slide,
              child: Stack(
                children: [
                  _buildScroll(),
                  if (!_isMandatory)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: IconButton(
                        icon: const Icon(Icons.close_rounded,
                            color: _muted, size: 26),
                        onPressed: _onClosePressed,
                        tooltip: 'Close',
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

  Widget _buildScroll() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
      physics: const BouncingScrollPhysics(),
      children: [
        const SizedBox(height: 8),
        _buildHero(),
        const SizedBox(height: 26),
        _Timeline(controller: _timeline),
        const SizedBox(height: 28),
        _buildPlans(),
        const SizedBox(height: 16),
        _buildErrorBanner(),
        _buildTrustRow(),
        const SizedBox(height: 14),
        _buildFinePrint(),
      ],
    );
  }

  // ─── Hero ───────────────────────────────────────────────────────────────
  Widget _buildHero() {
    return Column(
      children: [
        Container(
          width: 70,
          height: 70,
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
                blurRadius: 28,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Icon(Icons.auto_awesome_rounded,
              color: Colors.white, size: 32),
        ),
        const SizedBox(height: 18),
        const Text(
          'Try FlickClean free\nfor 3 days',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w700,
            height: 1.15,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            "Here's how your trial works. Cancel anytime — no questions asked.",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _muted,
              fontSize: 14,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }

  // ─── Plans ──────────────────────────────────────────────────────────────
  Widget _buildPlans() {
    if (_loadingOfferings) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(child: CircularProgressIndicator(color: _accent)),
      );
    }

    final weekly = _offering?.weekly;
    final annual = _offering?.annual;

    if (weekly == null && annual == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Text(
              _errorMessage ?? 'Subscriptions are unavailable right now.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted, fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                setState(() {
                  _loadingOfferings = true;
                  _errorMessage = null;
                });
                _loadOfferings();
              },
              child: const Text('Retry',
                  style: TextStyle(color: _accent, fontSize: 15)),
            ),
          ],
        ),
      );
    }

    final savings = _yearlySavingsPercent(weekly, annual);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (annual != null)
          _PlanTile(
            label: 'Yearly',
            priceTagline: '3 days free, then ${annual.storeProduct.priceString} / year',
            secondaryTagline: _perWeekFromAnnual(annual) != null
                ? 'Just ${_perWeekFromAnnual(annual)} / week'
                : null,
            badge: savings != null
                ? 'BEST VALUE · SAVE $savings%'
                : 'BEST VALUE',
            highlight: true,
            loading: _purchasingId == annual.identifier,
            anyLoading: _purchasingId != null || _restoring,
            onTap: () => _purchase(annual),
          ),
        if (weekly != null && annual != null) const SizedBox(height: 10),
        if (weekly != null)
          _PlanTile(
            label: 'Weekly',
            priceTagline: '3 days free, then ${weekly.storeProduct.priceString} / week',
            highlight: false,
            loading: _purchasingId == weekly.identifier,
            anyLoading: _purchasingId != null || _restoring,
            onTap: () => _purchase(weekly),
          ),
      ],
    );
  }

  int? _yearlySavingsPercent(Package? weekly, Package? annual) {
    if (weekly == null || annual == null) return null;
    final weeklyPrice = weekly.storeProduct.price;
    final annualPrice = annual.storeProduct.price;
    if (weeklyPrice <= 0 || annualPrice <= 0) return null;
    final yearOfWeeks = weeklyPrice * 52;
    if (yearOfWeeks <= annualPrice) return null;
    final saved = ((yearOfWeeks - annualPrice) / yearOfWeeks) * 100;
    return saved.round();
  }

  String? _perWeekFromAnnual(Package annual) {
    final price = annual.storeProduct.price;
    if (price <= 0) return null;
    final perWeek = price / 52.0;
    final code = annual.storeProduct.currencyCode;
    return '$code ${perWeek.toStringAsFixed(2)}';
  }

  Widget _buildErrorBanner() {
    if (_errorMessage == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        _errorMessage!,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0xFFFF453A), fontSize: 13),
      ),
    );
  }

  Widget _buildTrustRow() {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _TrustChip(icon: Icons.shield_rounded, label: 'On-device'),
        SizedBox(width: 8),
        _TrustChip(
            icon: Icons.cancel_schedule_send_rounded,
            label: 'Cancel anytime'),
        SizedBox(width: 8),
        _TrustChip(icon: Icons.lock_outline_rounded, label: 'No account'),
      ],
    );
  }

  Widget _buildFinePrint() {
    return Column(
      children: [
        const Text(
          'Free for 3 days, then your chosen plan renews automatically until you cancel. '
          'Cancel anytime in your Apple account settings.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, fontSize: 11.5, height: 1.45),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _FineLink(
              label: _restoring ? 'Restoring…' : 'Restore',
              onTap: _onRestorePressed,
            ),
            const _FineDot(),
            _FineLink(
              label: 'Terms',
              onTap: () => _openUrl(
                  'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/'),
            ),
            const _FineDot(),
            _FineLink(
              label: 'Privacy',
              onTap: () => _openUrl('https://flickclean.app/privacy'),
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Timeline ─────────────────────────────────────────────────────────────────
//
// Vertical "Day 1 → Day 2 → Day 3" reveal. A single AnimationController is
// driven from 0 → 1; the connecting rail grows continuously, and each row
// fades in at a staggered interval so the progression reads like a story.
class _Timeline extends StatelessWidget {
  final AnimationController controller;
  const _Timeline({required this.controller});

  static const Color _accent = Color(0xFF6B4EFF);
  static const Color _check = Color(0xFF30D158);
  static const Color _warm = Color(0xFFFFD60A);
  static const Color _railIdle = Color(0xFF2C2C2E);

  static const List<_Step> _steps = [
    _Step(
      tag: 'Day 1',
      title: 'Free',
      body: 'No payment required — full access from the moment you tap below.',
      icon: Icons.lock_open_rounded,
      color: _check,
    ),
    _Step(
      tag: 'Day 2',
      title: 'Enjoy Unlimited',
      body: 'Every feature stays unlocked. Zero limitations, zero gotchas.',
      icon: Icons.all_inclusive_rounded,
      color: _accent,
    ),
    _Step(
      tag: 'Day 3',
      title: 'Trial Ends',
      body: 'Your subscription begins — only if you decide to continue.',
      icon: Icons.event_available_rounded,
      color: _warm,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final t = controller.value;
        return CustomPaint(
          painter: _TimelineRailPainter(
            progress: t,
            stops: _steps.length,
            activeColor: _accent.withOpacity(0.85),
            idleColor: _railIdle,
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 0),
            child: Column(
              children: [
                for (int i = 0; i < _steps.length; i++) ...[
                  _TimelineRow(
                    step: _steps[i],
                    index: i,
                    total: _steps.length,
                    progress: t,
                  ),
                  if (i < _steps.length - 1) const SizedBox(height: 18),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Step {
  final String tag;
  final String title;
  final String body;
  final IconData icon;
  final Color color;
  const _Step({
    required this.tag,
    required this.title,
    required this.body,
    required this.icon,
    required this.color,
  });
}

class _TimelineRow extends StatelessWidget {
  final _Step step;
  final int index;
  final int total;
  final double progress;

  const _TimelineRow({
    required this.step,
    required this.index,
    required this.total,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    // Stagger: each row owns a slice of the [0, 1] progress range and
    // fades + slides in over its slice.
    final slice = 1.0 / total;
    final start = index * slice;
    final localT =
        ((progress - start) / slice).clamp(0.0, 1.0);
    final fade = Curves.easeOut.transform(localT);
    final slideY = (1 - fade) * 12;
    final active = localT > 0.05;

    return Opacity(
      opacity: fade,
      child: Transform.translate(
        offset: Offset(0, slideY),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Dot(active: active, color: step.color, icon: step.icon),
            const SizedBox(width: 14),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          step.tag,
                          style: TextStyle(
                            color: step.color,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_right_alt_rounded,
                            color: Color(0xFF3A3A3C), size: 16),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            step.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      step.body,
                      style: const TextStyle(
                        color: Color(0xFFB7B9BD),
                        fontSize: 12.5,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final bool active;
  final Color color;
  final IconData icon;
  const _Dot({
    required this.active,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? color.withOpacity(0.18) : const Color(0xFF1A1A1F),
        border: Border.all(
          color: active ? color : const Color(0xFF2C2C2E),
          width: 1.4,
        ),
      ),
      child: Icon(icon,
          color: active ? color : const Color(0xFF6E6E73), size: 16),
    );
  }
}

class _TimelineRailPainter extends CustomPainter {
  final double progress;
  final int stops;
  final Color activeColor;
  final Color idleColor;

  _TimelineRailPainter({
    required this.progress,
    required this.stops,
    required this.activeColor,
    required this.idleColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0) return;
    // The dot is 34 wide; the rail centres on it at x = 17.
    const x = 17.0;
    final top = 17.0;
    final bottom = size.height - 17.0;
    if (bottom <= top) return;

    final idlePaint = Paint()
      ..color = idleColor
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(x, top), Offset(x, bottom), idlePaint);

    final activePaint = Paint()
      ..color = activeColor
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    final activeEnd = top + (bottom - top) * progress;
    canvas.drawLine(Offset(x, top), Offset(x, activeEnd), activePaint);
  }

  @override
  bool shouldRepaint(covariant _TimelineRailPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

// ─── Plan tile ────────────────────────────────────────────────────────────────
class _PlanTile extends StatelessWidget {
  final String label;
  final String priceTagline;
  final String? secondaryTagline;
  final String? badge;
  final bool highlight;
  final bool loading;
  final bool anyLoading;
  final VoidCallback onTap;

  const _PlanTile({
    required this.label,
    required this.priceTagline,
    required this.highlight,
    required this.loading,
    required this.anyLoading,
    required this.onTap,
    this.secondaryTagline,
    this.badge,
  });

  static const Color _accent = Color(0xFF6B4EFF);
  static const Color _accentSoft = Color(0xFF8B7BFF);
  static const Color _muted = Color(0xFF8E8E93);
  static const Color _surface = Color(0xFF15151A);

  @override
  Widget build(BuildContext context) {
    final borderColor = highlight
        ? _accent.withOpacity(0.65)
        : const Color(0xFF26262C);
    final bg = highlight ? _accent.withOpacity(0.10) : _surface;
    final disabled = anyLoading && !loading;

    return Opacity(
      opacity: disabled ? 0.55 : 1.0,
      child: GestureDetector(
        onTap: anyLoading ? null : onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding: EdgeInsets.fromLTRB(
              16, badge != null ? 12 : 16, 16, 16),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: borderColor, width: 1.4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (badge != null) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: _accent,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    badge!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          priceTagline,
                          style: TextStyle(
                            color: highlight ? _accentSoft : Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (secondaryTagline != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            secondaryTagline!,
                            style: const TextStyle(
                              color: _muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  _Trailing(loading: loading),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Trailing extends StatelessWidget {
  final bool loading;
  const _Trailing({required this.loading});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 34,
      child: Center(
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  color: Color(0xFF8B7BFF),
                  strokeWidth: 2.4,
                ),
              )
            : Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF6B4EFF).withOpacity(0.16),
                ),
                child: const Icon(Icons.arrow_forward_rounded,
                    color: Color(0xFF8B7BFF), size: 18),
              ),
      ),
    );
  }
}

class _TrustChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _TrustChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF15151A),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF26262C), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xFF8E8E93), size: 13),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF8E8E93),
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _FineLink extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _FineLink({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFF8E8E93),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _FineDot extends StatelessWidget {
  const _FineDot();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 2),
      child: Text('·', style: TextStyle(color: Color(0xFF3A3A3C))),
    );
  }
}
