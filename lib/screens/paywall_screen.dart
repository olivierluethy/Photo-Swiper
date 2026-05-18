import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/analytics_events.dart';
import '../services/analytics_service.dart';
import '../services/notification_service.dart';
import '../services/purchase_service.dart';

/// FlickClean's premium paywall. Two plans, no monthly:
///
///   • Weekly  — billed every 7 days, includes a 3-day free trial
///   • Yearly  — billed upfront, biggest savings (shown as "BEST VALUE")
///
/// The user picks one tile, the CTA wording adapts ("Start 3-Day Free Trial"
/// for weekly, "Subscribe Yearly" for yearly), and a single tap purchases
/// the selected package via RevenueCat.
class PaywallScreen extends StatefulWidget {
  /// Where the paywall is being presented from. Drives analytics.
  final PaywallSource source;

  const PaywallScreen({
    super.key,
    this.source = PaywallSource.deepTrigger,
  });

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

enum PaywallSource { onboarding, deepTrigger, settings }

class _PaywallScreenState extends State<PaywallScreen>
    with SingleTickerProviderStateMixin {
  final _service = PurchaseService.instance;

  Offering? _offering;
  Package? _selected;
  bool _loadingOfferings = true;
  bool _purchasing = false;
  bool _restoring = false;
  String? _errorMessage;

  bool _converted = false;
  bool _convertedViaTrial = false;
  final DateTime _shownAt = DateTime.now();

  late final AnimationController _entry;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  // ─── Design tokens ──────────────────────────────────────────────────────
  static const Color _bg = Color(0xFF0D0D0D);
  static const Color _surface = Color(0xFF15151A);
  static const Color _accent = Color(0xFF6B4EFF);
  static const Color _accentSoft = Color(0xFF8B7BFF);
  static const Color _muted = Color(0xFF8E8E93);
  static const Color _privacy = Color(0xFF0A84FF);

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

    _loadOfferings();
    WidgetsBinding.instance.addPostFrameCallback((_) => _entry.forward());
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
    super.dispose();
  }

  // ─── Loading ────────────────────────────────────────────────────────────
  Future<void> _loadOfferings() async {
    final cached = _service.currentOffering;
    if (cached != null && (cached.weekly != null || cached.annual != null)) {
      setState(() {
        _offering = cached;
        _selected = _defaultSelection(cached);
        _loadingOfferings = false;
      });
      return;
    }
    final fetched = await _service.fetchOfferings();
    if (!mounted) return;
    setState(() {
      _offering = fetched;
      _selected =
          fetched != null ? _defaultSelection(fetched) : null;
      _loadingOfferings = false;
      if (fetched == null ||
          (fetched.weekly == null && fetched.annual == null)) {
        _errorMessage = _describeOfferingProblem();
      }
    });
  }

  /// Default to weekly (lowest friction; trial-eligible) and visually
  /// emphasise yearly as the "Best Value" — matches the high-conversion
  /// pattern used across the category.
  Package? _defaultSelection(Offering offering) {
    return offering.weekly ?? offering.annual;
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
  Future<void> _onPurchasePressed() async {
    final pkg = _selected;
    if (pkg == null || _purchasing) return;

    HapticFeedback.mediumImpact();
    setState(() {
      _purchasing = true;
      _errorMessage = null;
    });

    final framedAsTrial = pkg.packageType == PackageType.weekly;

    try {
      final success = await _service.purchase(pkg);
      if (!mounted) return;
      if (success) {
        _converted = true;
        _convertedViaTrial = framedAsTrial && _service.isInTrial;

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

        Navigator.of(context).pop(true);
      } else {
        setState(() => _purchasing = false);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _purchasing = false;
        _errorMessage = 'Purchase could not be completed. Please try again.';
      });
    }
  }

  Future<void> _onRestorePressed() async {
    if (_purchasing || _restoring) return;
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
      Navigator.of(context).pop(true);
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
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fade,
          child: SlideTransition(
            position: _slide,
            child: Stack(
              children: [
                _buildScroll(),
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
    );
  }

  Widget _buildScroll() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 32),
      physics: const BouncingScrollPhysics(),
      children: [
        const SizedBox(height: 8),
        _buildHero(),
        const SizedBox(height: 24),
        _buildValueProps(),
        const SizedBox(height: 16),
        _buildPrivacyCallout(),
        const SizedBox(height: 24),
        _buildPlans(),
        const SizedBox(height: 18),
        _buildErrorBanner(),
        _buildPrimaryCta(),
        const SizedBox(height: 14),
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
          width: 72,
          height: 72,
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
              color: Colors.white, size: 34),
        ),
        const SizedBox(height: 18),
        const Text(
          'Unlock FlickClean Premium',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w700,
            height: 1.1,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            'Clean your library calmly, beautifully, and entirely on your own device.',
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

  // ─── Value props ────────────────────────────────────────────────────────
  Widget _buildValueProps() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ValueRow(
            icon: Icons.all_inclusive_rounded,
            title: 'Unlimited photo swiping',
            subtitle: 'Sort your entire library — no daily caps.',
          ),
          SizedBox(height: 14),
          _ValueRow(
            icon: Icons.flash_on_rounded,
            title: 'Faster cleanup',
            subtitle: 'Smart previews and instant batching.',
          ),
          SizedBox(height: 14),
          _ValueRow(
            icon: Icons.sd_storage_rounded,
            title: 'Free up gigabytes',
            subtitle: 'See exactly how much space you reclaim.',
          ),
          SizedBox(height: 14),
          _ValueRow(
            icon: Icons.workspace_premium_rounded,
            title: 'Every new tool we ship',
            subtitle: 'All future features included.',
          ),
        ],
      ),
    );
  }

  // ─── Privacy callout ────────────────────────────────────────────────────
  Widget _buildPrivacyCallout() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: _privacy.withOpacity(0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _privacy.withOpacity(0.26), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: _privacy.withOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.shield_rounded,
                color: _privacy, size: 18),
          ),
          const SizedBox(width: 11),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '100% on-device privacy',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'No cloud uploads. Your photos never leave your phone.',
                  style: TextStyle(
                    color: Color(0xFFBFC1C6),
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Plans ──────────────────────────────────────────────────────────────
  Widget _buildPlans() {
    if (_loadingOfferings) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
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
            title: 'Yearly',
            priceLabel: annual.storeProduct.priceString,
            cadence: 'per year',
            sublabel: _perWeekFromAnnual(annual) != null
                ? '${_perWeekFromAnnual(annual)} per week · billed upfront'
                : 'billed upfront',
            badge: savings != null ? 'BEST VALUE · SAVE $savings%' : 'BEST VALUE',
            selected: _selected?.identifier == annual.identifier,
            highlight: true,
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _selected = annual);
            },
          ),
        if (weekly != null && annual != null) const SizedBox(height: 10),
        if (weekly != null)
          _PlanTile(
            title: 'Weekly',
            priceLabel: weekly.storeProduct.priceString,
            cadence: 'per week',
            sublabel: '3-day free trial included',
            selected: _selected?.identifier == weekly.identifier,
            highlight: false,
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _selected = weekly);
            },
          ),
      ],
    );
  }

  /// Returns the % saved on yearly vs paying weekly for a full year.
  /// Null if either price is missing or yearly isn't actually cheaper.
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

  // ─── CTA ────────────────────────────────────────────────────────────────
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

  Widget _buildPrimaryCta() {
    final canPurchase = _selected != null && !_purchasing && !_restoring;
    final framedAsTrial =
        _selected?.packageType == PackageType.weekly;
    final label = framedAsTrial
        ? 'Start 3-Day Free Trial'
        : 'Subscribe Yearly';

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: canPurchase ? _onPurchasePressed : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: _accent,
          disabledBackgroundColor: _accent.withOpacity(0.4),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
        child: _purchasing
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.4,
                ),
              )
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Text(
                  label,
                  key: ValueKey(label),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
      ),
    );
  }

  // ─── Trust row ──────────────────────────────────────────────────────────
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

  // ─── Fine print ─────────────────────────────────────────────────────────
  Widget _buildFinePrint() {
    final framedAsTrial =
        _selected?.packageType == PackageType.weekly;
    final summary = framedAsTrial
        ? 'Free for 3 days, then renews weekly until cancelled.'
        : 'Billed upfront yearly, renews each year until cancelled.';
    return Column(
      children: [
        Text(
          '$summary Cancel anytime in your Apple account settings.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, fontSize: 11.5, height: 1.45),
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

// ─── Plan tile ────────────────────────────────────────────────────────────────
class _PlanTile extends StatelessWidget {
  final String title;
  final String priceLabel;
  final String cadence;
  final String? sublabel;
  final String? badge;
  final bool selected;
  final bool highlight;
  final VoidCallback onTap;

  const _PlanTile({
    required this.title,
    required this.priceLabel,
    required this.cadence,
    required this.selected,
    required this.highlight,
    required this.onTap,
    this.sublabel,
    this.badge,
  });

  static const Color _accent = Color(0xFF6B4EFF);
  static const Color _accentSoft = Color(0xFF8B7BFF);
  static const Color _muted = Color(0xFF8E8E93);
  static const Color _surface = Color(0xFF15151A);

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? _accent
        : (highlight ? _accent.withOpacity(0.45) : const Color(0xFF26262C));
    final bg = selected
        ? _accent.withOpacity(0.14)
        : (highlight ? _accent.withOpacity(0.06) : _surface);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: EdgeInsets.fromLTRB(
            16, badge != null ? 12 : 16, 14, 16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: borderColor,
            width: selected ? 2 : 1.2,
          ),
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
                _Radio(selected: selected),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (sublabel != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          sublabel!,
                          style: TextStyle(
                            color: highlight ? _accentSoft : _muted,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      priceLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      cadence,
                      style:
                          const TextStyle(color: _muted, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Sub-widgets ──────────────────────────────────────────────────────────
class _ValueRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _ValueRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xFF6B4EFF).withOpacity(0.16),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon,
              color: const Color(0xFF8B7BFF), size: 19),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
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

class _Radio extends StatelessWidget {
  final bool selected;
  const _Radio({required this.selected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color:
              selected ? const Color(0xFF6B4EFF) : const Color(0xFF3A3A3C),
          width: 2,
        ),
        color: selected ? const Color(0xFF6B4EFF) : Colors.transparent,
      ),
      child: selected
          ? const Icon(Icons.check_rounded, color: Colors.white, size: 14)
          : null,
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
