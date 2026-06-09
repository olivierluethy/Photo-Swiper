import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/analytics_events.dart';
import '../services/analytics_service.dart';
import '../services/notification_service.dart';
import '../services/preferences_service.dart';
import '../services/purchase_service.dart';

/// FlickClean's mandatory subscription paywall.
///
/// Layout, top → bottom:
///   1. Hero copy that adapts to the currently selected plan.
///   2. **Conditional** details panel:
///        • Weekly selected → animated 3-day trial timeline.
///        • Yearly selected → "starts immediately, no trial" card.
///      The two cross-fade as the user toggles between plans.
///   3. Two plan tiles with radio selection.
///        • Weekly: 3-day trial, then weekly billing.
///        • Yearly: direct annual purchase, no trial.
///      Tap = select (timeline + hero + CTA all react instantly).
///   4. One primary CTA whose wording adapts to the selection. The CTA
///      calls `Purchases.purchasePackage(...)`, which raises Apple's
///      native StoreKit confirmation sheet — that's where the trial /
///      pricing terms come from (driven by App Store Connect config).
///      On success we replace the route stack with /home.
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
  Package? _selected;
  bool _loadingOfferings = true;
  String? _purchasingId;
  bool _restoring = false;
  String? _errorMessage;

  bool _converted = false;
  bool _convertedViaTrial = false;
  // Set to true the instant we begin _exitOnSuccess, so the listener and
  // the sync return value can't both fire navigation. Independent from
  // _converted (which gates analytics + onboarding completion).
  bool _navigated = false;
  // Set to true the instant we emit the purchase-success analytics. Because
  // a single successful purchase can surface via *both* the synchronous
  // purchase() return value and the async entitlement listener, this guard
  // guarantees subscription_started / *_plan_purchased / funnel_step_purchase
  // fire exactly once per purchase.
  bool _purchaseSuccessTracked = false;
  // Set to true the instant we ask for notification permission off the back
  // of a trial start, so the prompt is requested at most once per purchase
  // whether the success surfaced synchronously or via the async listener.
  bool _trialNotificationRequested = false;
  // The package whose purchase returned PurchaseOutcome.pending — i.e. Apple
  // accepted it but the 'pro' entitlement hadn't propagated yet. Lets the
  // async entitlement listener attribute the delayed-success analytics to
  // the right plan when the entitlement finally lands.
  Package? _pendingPurchasePkg;
  final DateTime _shownAt = DateTime.now();

  // Scroll listener: emits at most one paywall_scrolled event per
  // direction-change so we don't flood the dashboard with one event per
  // pixel of drag.
  final ScrollController _scrollCtrl = ScrollController();
  double _lastScrollOffset = 0;
  String? _lastScrollDirection;

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
    AnalyticsService.instance.clearPlansViewed();
    _scrollCtrl.addListener(_onScroll);

    // Defensive: also navigate when PurchaseService flips to isPro via the
    // async customerInfo listener. Without this, a sandbox/TestFlight race
    // where Purchases.purchasePackage returns before the entitlement has
    // settled in CustomerInfo would leave the user stranded on the paywall
    // even though Apple completed the purchase.
    _service.addListener(_onPurchaseServiceChanged);

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
      // If a prior session / restore left us already entitled, navigate
      // immediately on the next frame. Only applies to mandatory
      // presentations — for settings, the user opened this screen
      // intentionally and should stay.
      if (_service.isPro && _isMandatory && !_navigated) {
        debugPrint(
            '[PaywallScreen] already isPro on mount — auto-exiting (source=${widget.source.name})');
        _converted = true;
        _convertedViaTrial = _service.isInTrial;
        unawaited(_exitOnSuccess());
        return;
      }
      _entry.forward();
      final loadMs =
          DateTime.now().difference(_shownAt).inMilliseconds;
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.paywallViewed,
        properties: {
          'source': widget.source.name,
          'screen_load_time_ms': loadMs,
        },
      ));
      unawaited(AnalyticsService.instance.funnelStep(
        FunnelSteps.paywall,
        event: AnalyticsEvents.funnelStepPaywall,
        status: 'viewed',
        extras: {'source': widget.source.name},
      ));
      // Slight delay so the timeline plays once the page has settled,
      // making the progression feel intentional rather than racing the
      // page transition.
      Future<void>.delayed(const Duration(milliseconds: 220), () {
        if (mounted) _timeline.forward();
      });
    });
  }

  void _onScroll() {
    final offset = _scrollCtrl.offset;
    final delta = offset - _lastScrollOffset;
    if (delta.abs() < 12) return; // ignore micro-jitter
    final dir = delta > 0 ? 'down' : 'up';
    _lastScrollOffset = offset;
    if (dir == _lastScrollDirection) return;
    _lastScrollDirection = dir;
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.paywallScrolled,
      properties: {'direction': dir, 'offset': offset.toInt()},
    ));
  }

  @override
  void dispose() {
    if (!_converted) {
      final seconds = DateTime.now().difference(_shownAt).inSeconds;
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.paywallClosedWithoutPurchase,
        properties: {
          'time_spent_on_paywall_seconds': seconds,
          'source': widget.source.name,
          'plans_viewed': AnalyticsService.instance.plansViewed,
        },
      ));
      unawaited(AnalyticsService.instance.funnelStep(
        FunnelSteps.purchase,
        event: AnalyticsEvents.funnelStepPurchase,
        status: 'abandoned',
        extras: {'source': widget.source.name},
      ));
    }
    _service.removeListener(_onPurchaseServiceChanged);
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _entry.dispose();
    _timeline.dispose();
    super.dispose();
  }

  /// Fires whenever PurchaseService notifies listeners (entitlement change,
  /// trial transition, offerings refresh, init complete). We only act on
  /// transitions to isPro and only once.
  void _onPurchaseServiceChanged() {
    if (!mounted || _navigated) return;
    if (_service.isPro) {
      debugPrint(
          '[PaywallScreen] async entitlement update — isPro=true, navigating');
      _converted = true;
      _convertedViaTrial = _service.isInTrial;
      // Delayed-success rescue: if this activation follows a purchase that
      // returned `pending`, emit the same success analytics the synchronous
      // path would have, attributed to the package that was bought. Restores
      // and pre-existing entitlements leave _pendingPurchasePkg null, so they
      // don't get mislabelled as a fresh purchase here. _trackPurchaseSuccess
      // is idempotent, so a sync success that also pinged the listener can't
      // double-count.
      final pendingPkg = _pendingPurchasePkg;
      if (pendingPkg != null) {
        debugPrint(
            '[PaywallScreen] delayed-success rescue — emitting purchase-success analytics');
        _trackPurchaseSuccess(pendingPkg);
        // Parity with the synchronous trial-success path: a delayed trial
        // start should also prompt for notifications so the Day-3 reminder
        // can fire. Gated to genuine delayed purchases (pendingPkg != null),
        // so restores / pre-existing entitlements never reach it.
        _maybeRequestTrialNotificationPermission();
      }
      unawaited(_exitOnSuccess());
    }
  }

  /// Requests notification permission so the Day-3 trial-ending reminder can
  /// be shown. Fires at most once per purchase and only when the user just
  /// started a *trial*. Called from both the synchronous trial-success path
  /// and the async delayed-success rescue; restores and pre-existing
  /// entitlements never run the purchase-success flow, so they can't trigger
  /// it.
  void _maybeRequestTrialNotificationPermission() {
    if (_trialNotificationRequested || !_convertedViaTrial) return;
    _trialNotificationRequested = true;
    unawaited(NotificationService.instance.requestPermission());
  }

  /// Emits the purchase-success analytics exactly once per purchase. Shared
  /// by the synchronous `purchased` path and the async entitlement-rescue
  /// listener; the [_purchaseSuccessTracked] guard makes a delayed success
  /// and a synchronous success mutually exclusive in the data.
  void _trackPurchaseSuccess(Package pkg) {
    if (_purchaseSuccessTracked) return;
    _purchaseSuccessTracked = true;

    final tier = _tierFor(pkg);
    final framedAsTrial = pkg.packageType == PackageType.weekly;
    final commonPurchaseProps = <String, Object>{
      'tier': tier,
      'framed_as_trial': framedAsTrial,
      'in_trial': _service.isInTrial,
      'purchase_price': pkg.storeProduct.price,
      'currency': pkg.storeProduct.currencyCode,
      'source': widget.source.name,
    };
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.subscriptionStarted,
      properties: commonPurchaseProps,
    ));
    unawaited(AnalyticsService.instance.track(
      framedAsTrial
          ? AnalyticsEvents.weeklyPlanPurchased
          : AnalyticsEvents.yearlyPlanPurchased,
      properties: commonPurchaseProps,
    ));
    unawaited(AnalyticsService.instance.funnelStep(
      FunnelSteps.purchase,
      event: AnalyticsEvents.funnelStepPurchase,
      status: 'completed',
      extras: {'plan_type': tier},
    ));
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
      _selected = fetched != null ? _defaultSelection(fetched) : null;
      _loadingOfferings = false;
      if (fetched == null ||
          (fetched.weekly == null && fetched.annual == null)) {
        _errorMessage = _describeOfferingProblem();
      }
    });
  }

  /// Weekly is the lead — surfacing the trial up-front maximises conversion
  /// and lets the user see the timeline by default. Falls back to yearly if
  /// weekly isn't configured.
  Package? _defaultSelection(Offering offering) {
    return offering.weekly ?? offering.annual;
  }

  /// Switch the focused plan. Updates the timeline / hero / CTA. When the
  /// user moves *back* to weekly we replay the timeline so the reveal feels
  /// intentional rather than showing a finished, frozen rail.
  void _selectPlan(Package pkg) {
    if (_selected?.identifier == pkg.identifier) return;
    HapticFeedback.selectionClick();
    final wasYearly = _selected?.packageType == PackageType.annual;
    setState(() => _selected = pkg);
    if (pkg.packageType == PackageType.weekly && wasYearly) {
      _timeline.forward(from: 0);
    }
    final isWeekly = pkg.packageType == PackageType.weekly;
    AnalyticsService.instance.notePlanViewed(isWeekly ? 'weekly' : 'yearly');
    unawaited(AnalyticsService.instance.track(
      isWeekly
          ? AnalyticsEvents.weeklyPlanTapped
          : AnalyticsEvents.yearlyPlanTapped,
    ));
  }

  bool get _isWeeklySelected =>
      _selected?.packageType == PackageType.weekly;

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
  // Triggered from the single primary CTA at the bottom of the sheet,
  // whichever plan is currently selected. RevenueCat raises Apple's
  // native StoreKit confirmation sheet — that sheet is what shows the
  // trial / pricing terms (driven by App Store Connect config).
  Future<void> _onSubscribePressed() async {
    final pkg = _selected;
    if (pkg == null) return;
    if (_purchasingId != null || _restoring) return;
    debugPrint(
        '[PaywallScreen] subscribe tapped pkg=${pkg.identifier} type=${pkg.packageType} source=${widget.source.name}');
    HapticFeedback.mediumImpact();
    setState(() {
      _purchasingId = pkg.identifier;
      _errorMessage = null;
    });

    final framedAsTrial = pkg.packageType == PackageType.weekly;
    final planType = framedAsTrial ? 'weekly' : 'yearly';

    // Capture the plan the user is actually proceeding to purchase with —
    // including the pre-selected default. weekly/yearly_plan_tapped only fire
    // on a selection *change*, so they miss users who buy the default; this
    // event makes the funnel reflect real purchase intent.
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.planSelectedAtPurchase,
      properties: {'plan_type': planType},
    ));

    // Apple's native StoreKit dialog appears as a result of the
    // `purchasePackage` call below. The dashboard distinguishes between
    // "tapped a plan tile" and "saw Apple's confirmation sheet" using
    // these dedicated events.
    unawaited(AnalyticsService.instance.track(
      framedAsTrial
          ? AnalyticsEvents.weeklyPlanAppleDialogShown
          : AnalyticsEvents.yearlyPlanAppleDialogShown,
      properties: {
        'currency_code': pkg.storeProduct.currencyCode,
      },
    ));

    try {
      final outcome = await _service.purchase(pkg);
      debugPrint(
          '[PaywallScreen] purchase() outcome=$outcome service.isPro=${_service.isPro}');
      if (!mounted) return;
      if (outcome == PurchaseOutcome.purchased) {
        _converted = true;
        _convertedViaTrial = _service.isInTrial;

        _trackPurchaseSuccess(pkg);
        HapticFeedback.heavyImpact();

        _maybeRequestTrialNotificationPermission();

        unawaited(_exitOnSuccess());
      } else if (outcome == PurchaseOutcome.cancelled) {
        // The user dismissed Apple's StoreKit sheet without paying. This is
        // now the *only* path that logs a cancellation.
        debugPrint('[PaywallScreen] purchase cancelled by user');
        unawaited(AnalyticsService.instance.track(
          AnalyticsEvents.purchaseCancelled,
          properties: {
            'plan_type': planType,
            'source': widget.source.name,
          },
        ));
        unawaited(AnalyticsService.instance.dropOff(
          lastCompletedStep: FunnelSteps.paywall,
          reason: FunnelDropOffReason.paymentCancelled,
          extras: {'plan_type': planType},
        ));
        setState(() => _purchasingId = null);
      } else {
        // PurchaseOutcome.pending: StoreKit returned but the 'pro'
        // entitlement hasn't propagated yet (common in sandbox/TestFlight).
        // This is NOT a cancellation — we log it distinctly so it can never
        // inflate purchase_cancelled. The async PurchaseService listener
        // (_onPurchaseServiceChanged) will navigate the instant the
        // entitlement settles; we re-enable the CTA without surfacing an
        // error because the purchase may still resolve to pro.
        debugPrint(
            '[PaywallScreen] purchase pending — entitlement not active yet, awaiting async update');
        // Remember which plan was bought so the async entitlement listener
        // can attribute the delayed-success analytics correctly when the
        // 'pro' entitlement finally activates.
        _pendingPurchasePkg = pkg;
        unawaited(AnalyticsService.instance.track(
          AnalyticsEvents.purchaseCompletedEntitlementPending,
          properties: {
            'plan_type': planType,
            'source': widget.source.name,
          },
        ));
        setState(() => _purchasingId = null);
      }
    } catch (e, st) {
      debugPrint('[PaywallScreen] purchase threw: $e\n$st');
      if (!mounted) return;
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.errorOccurred,
        properties: {
          'context': 'paywall_purchase',
          'plan_type': planType,
        },
      ));
      unawaited(AnalyticsService.instance.dropOff(
        lastCompletedStep: FunnelSteps.paywall,
        reason: FunnelDropOffReason.purchaseFailed,
        extras: {'plan_type': planType},
      ));
      setState(() {
        _purchasingId = null;
        _errorMessage = 'Purchase could not be completed. Please try again.';
      });
    }
  }

  /// Idempotent: guarded by [_navigated] so it can be safely invoked from
  /// both the sync return value of `_service.purchase(...)` and the async
  /// PurchaseService listener without producing a double-navigation.
  Future<void> _exitOnSuccess() async {
    if (_navigated) return;
    _navigated = true;
    debugPrint(
        '[PaywallScreen] _exitOnSuccess source=${widget.source.name} isPro=${_service.isPro}');

    if (widget.source == PaywallSource.settings) {
      if (!mounted) return;
      Navigator.of(context).pop(true);
      return;
    }
    // Onboarding/launch-gate purchases are the *last* step of the funnel.
    // At this point the user has cleared intro, both permission prompts,
    // and chosen a plan — that's the full definition of "onboarded".
    // We *await* the persistence write so a fast force-quit immediately
    // after Tapping confirm can't lose the completion flag.
    await PreferencesService.instance.setOnboardingComplete(true);
    debugPrint('[PaywallScreen] onboarding_complete persisted');

    if (!mounted) return;
    final plan = _selected != null ? _tierFor(_selected!) : 'unknown';
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.mainAppAccessedAfterPurchase,
      properties: {'plan_type': plan, 'source': widget.source.name},
    ));
    Navigator.of(context).pushReplacementNamed('/home');
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
      unawaited(_exitOnSuccess());
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
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
      physics: const BouncingScrollPhysics(),
      children: [
        const SizedBox(height: 8),
        _buildHero(),
        const SizedBox(height: 22),
        _buildConditionalDetails(),
        const SizedBox(height: 24),
        _buildPlans(),
        const SizedBox(height: 16),
        _buildErrorBanner(),
        _buildPrimaryCta(),
        const SizedBox(height: 14),
        _buildTrustRow(),
        const SizedBox(height: 14),
        _buildFinePrint(),
      ],
    );
  }

  /// Switches between the animated 3-day trial timeline (weekly) and the
  /// "starts immediately, no trial" card (yearly). Smooth crossfade so the
  /// shift feels intentional, not jarring.
  Widget _buildConditionalDetails() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SizeTransition(
            sizeFactor: animation,
            axisAlignment: -1,
            child: child,
          ),
        );
      },
      child: _isWeeklySelected
          ? _Timeline(
              key: const ValueKey('timeline'),
              controller: _timeline,
            )
          : const _YearlyStart(key: ValueKey('yearly-start')),
    );
  }

  // ─── Hero ───────────────────────────────────────────────────────────────
  // Title + subtitle adapt to the currently selected plan so the headline
  // always reflects what the user is considering. We use AnimatedSwitcher
  // for a calm crossfade so the swap reads as a smooth update rather than
  // a flicker.
  Widget _buildHero() {
    final isWeekly = _isWeeklySelected;
    final title = isWeekly
        ? 'Try FlickClean free\nfor 3 days'
        : 'Unlock FlickClean\nfor a full year';
    final subtitle = isWeekly
        ? "Here's how your trial works. Cancel anytime — no questions asked."
        : 'Full access from day one. No trial — your annual plan starts immediately.';

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
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (c, a) =>
              FadeTransition(opacity: a, child: c),
          child: Text(
            title,
            key: ValueKey(title),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w700,
              height: 1.15,
              letterSpacing: -0.4,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (c, a) =>
                FadeTransition(opacity: a, child: c),
            child: Text(
              subtitle,
              key: ValueKey(subtitle),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _muted,
                fontSize: 14,
                height: 1.45,
              ),
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
    final selectedId = _selected?.identifier;
    final busy = _purchasingId != null || _restoring;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (annual != null)
          _PlanTile(
            label: 'Yearly',
            priceTagline:
                '${annual.storeProduct.priceString} / year · billed upfront',
            secondaryTagline: _perWeekFromAnnual(annual) != null
                ? 'Just ${_perWeekFromAnnual(annual)} per week'
                : null,
            badge: savings != null
                ? 'BEST VALUE · SAVE $savings%'
                : 'BEST VALUE',
            highlight: true,
            selected: selectedId == annual.identifier,
            disabled: busy,
            onTap: () => _selectPlan(annual),
          ),
        if (weekly != null && annual != null) const SizedBox(height: 10),
        if (weekly != null)
          _PlanTile(
            label: 'Weekly',
            priceTagline:
                '3 days free, then ${weekly.storeProduct.priceString} / week',
            highlight: false,
            selected: selectedId == weekly.identifier,
            disabled: busy,
            onTap: () => _selectPlan(weekly),
          ),
      ],
    );
  }

  // ─── Primary CTA ────────────────────────────────────────────────────────
  // Single bottom button. Wording adapts to the selected plan so the user
  // always knows what tapping it does.
  Widget _buildPrimaryCta() {
    if (_loadingOfferings || _selected == null) {
      return const SizedBox.shrink();
    }
    final isWeekly = _isWeeklySelected;
    final label =
        isWeekly ? 'Start 3-Day Free Trial' : 'Subscribe Yearly';
    final busy = _purchasingId != null;
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: busy ? null : _onSubscribePressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: _accent,
          disabledBackgroundColor: _accent.withOpacity(0.4),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
        child: busy
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
    final pkg = _selected;
    final isWeekly = _isWeeklySelected;
    final priceLabel = pkg?.storeProduct.priceString ?? '';
    final summary = pkg == null
        ? 'Cancel anytime in your Apple account settings.'
        : isWeekly
            ? 'Free for 3 days, then $priceLabel/week renews automatically until cancelled. '
                'Cancel anytime in your Apple account settings.'
            : '$priceLabel billed upfront. Renews yearly until cancelled. '
                'No trial. Cancel anytime in your Apple account settings.';

    return Column(
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (c, a) =>
              FadeTransition(opacity: a, child: c),
          child: Text(
            summary,
            key: ValueKey(summary),
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: _muted, fontSize: 11.5, height: 1.45),
          ),
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
  const _Timeline({super.key, required this.controller});

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
// Selectable, not auto-purchase. Tap = "I'm considering this plan" so the
// hero + timeline + CTA update. The actual purchase fires from the
// centralised CTA below the tiles.
class _PlanTile extends StatelessWidget {
  final String label;
  final String priceTagline;
  final String? secondaryTagline;
  final String? badge;
  final bool highlight;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  const _PlanTile({
    required this.label,
    required this.priceTagline,
    required this.highlight,
    required this.selected,
    required this.disabled,
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
    final borderColor = selected
        ? _accent
        : highlight
            ? _accent.withOpacity(0.55)
            : const Color(0xFF26262C);
    final bg = selected
        ? _accent.withOpacity(0.16)
        : highlight
            ? _accent.withOpacity(0.08)
            : _surface;
    final borderWidth = selected ? 2.0 : 1.3;

    return Opacity(
      opacity: disabled ? 0.55 : 1.0,
      child: GestureDetector(
        onTap: disabled ? null : onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding: EdgeInsets.fromLTRB(
              14, badge != null ? 12 : 16, 16, 16),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: borderColor, width: borderWidth),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (badge != null) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 36),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 3),
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
                ),
                const SizedBox(height: 10),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _RadioDot(selected: selected),
                  const SizedBox(width: 12),
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
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RadioDot extends StatelessWidget {
  final bool selected;
  const _RadioDot({required this.selected});

  static const Color _accent = Color(0xFF6B4EFF);

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? _accent : Colors.transparent,
        border: Border.all(
          color: selected ? _accent : const Color(0xFF3A3A3C),
          width: 2,
        ),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: selected
            ? const Icon(Icons.check_rounded,
                key: ValueKey('on'), color: Colors.white, size: 15)
            : const SizedBox(key: ValueKey('off')),
      ),
    );
  }
}

// ─── Yearly "start immediately" card ──────────────────────────────────────
// Replaces the trial timeline when the user is considering the yearly
// plan. Keeps the visual block height roughly comparable to the timeline
// so the page doesn't feel like it collapses on the swap.
class _YearlyStart extends StatelessWidget {
  const _YearlyStart({super.key});

  static const Color _accent = Color(0xFF6B4EFF);
  static const Color _accentSoft = Color(0xFF8B7BFF);
  static const Color _surface = Color(0xFF15151A);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(18),
        border:
            Border.all(color: _accent.withOpacity(0.35), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _accent.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(Icons.rocket_launch_rounded,
                    color: _accentSoft, size: 20),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Start immediately with full access',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _YearlyPoint(
            icon: Icons.bolt_rounded,
            text: 'Premium unlocks the moment you confirm with Apple.',
          ),
          const SizedBox(height: 10),
          const _YearlyPoint(
            icon: Icons.event_busy_rounded,
            text:
                'No trial period — this is a direct annual purchase, billed upfront.',
          ),
          const SizedBox(height: 10),
          const _YearlyPoint(
            icon: Icons.savings_rounded,
            text: 'One predictable payment for a year of FlickClean.',
          ),
        ],
      ),
    );
  }
}

class _YearlyPoint extends StatelessWidget {
  final IconData icon;
  final String text;
  const _YearlyPoint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: const Color(0xFF8B7BFF), size: 16),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Color(0xFFB7B9BD),
              fontSize: 12.8,
              height: 1.45,
            ),
          ),
        ),
      ],
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
