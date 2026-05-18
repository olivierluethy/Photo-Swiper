import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:purchases_flutter/purchases_flutter.dart';

import 'notification_service.dart';
import 'preferences_service.dart';

/// Wraps RevenueCat. Single source of truth for paywall state.
///
/// Listen to this notifier from the UI to react to entitlement changes —
/// the SDK pushes updates via [Purchases.addCustomerInfoUpdateListener] and
/// they are forwarded here so any widget watching `isPro` rebuilds the
/// instant a purchase, refund, or restore lands.
class PurchaseService extends ChangeNotifier {
  PurchaseService._();
  static final PurchaseService instance = PurchaseService._();

  // Replace with the API keys from your RevenueCat dashboard
  // (Project Settings → API keys → Public app-specific keys).
  // The keys are not secrets — they ship in the binary.
  static const String _iosApiKey = 'appl_QCUIPaEXiDiDwVkLdoLVOIbinUM';
  static const String _androidApiKey = 'goog_REPLACE_WITH_ANDROID_KEY';

  // Must match the entitlement identifier configured in RevenueCat.
  static const String entitlementId = 'pro';

  bool _initialized = false;
  bool _isPro = false;
  bool _isInTrial = false;
  Offerings? _offerings;
  String? _lastError;

  // Completes once the first [init] call finishes (success or failure). Lets
  // navigation gates await the SDK's readiness without racing the UI.
  final Completer<void> _initCompleter = Completer<void>();

  bool get isPro => _isPro;
  bool get isInTrial => _isInTrial;
  bool get isInitialized => _initialized;
  Offering? get currentOffering => _offerings?.current;
  String? get lastError => _lastError;
  bool get hasOfferingButNoPackages =>
      _offerings?.current != null &&
      _offerings!.current!.availablePackages.isEmpty;
  bool get hasNoCurrentOffering =>
      _offerings != null && _offerings!.current == null;

  /// Resolves once [init] has finished. UI gates use this so they can wait
  /// for the entitlement state to settle before routing the user.
  Future<void> waitForInit() => _initCompleter.future;

  /// Initializes the SDK. Safe to call multiple times — subsequent calls are
  /// no-ops. Failures are swallowed so a misconfigured key never crashes the
  /// app; the user simply stays on the free tier until config is fixed.
  Future<void> init() async {
    if (_initialized) return;
    if (!_supportedPlatform) {
      _finishInit();
      return;
    }
    final apiKey = Platform.isIOS ? _iosApiKey : _androidApiKey;
    if (apiKey.contains('REPLACE_WITH')) {
      _lastError = 'API key not configured for this platform.';
      debugPrint('[PurchaseService] $_lastError');
      _finishInit();
      return;
    }

    try {
      // Verbose logging on debug builds — surfaces the real reason a purchase
      // or fetch fails (key invalid, products not synced, etc.) in console.
      await Purchases.setLogLevel(
          kDebugMode ? LogLevel.debug : LogLevel.warn);
      await Purchases.configure(PurchasesConfiguration(apiKey));

      final info = await Purchases.getCustomerInfo();
      _applyCustomerInfo(info, notify: false);

      Purchases.addCustomerInfoUpdateListener(_onCustomerInfoUpdate);

      // Pre-fetch offerings so the paywall opens instantly.
      _offerings = await Purchases.getOfferings();
      _lastError = null;
    } on PlatformException catch (e) {
      _lastError = _describeError(e);
      debugPrint('[PurchaseService] init failed: $_lastError');
    } catch (e) {
      _lastError = e.toString();
      debugPrint('[PurchaseService] init failed: $_lastError');
    } finally {
      _finishInit();
    }
  }

  void _finishInit() {
    _initialized = true;
    if (!_initCompleter.isCompleted) _initCompleter.complete();
    notifyListeners();
  }

  String _describeError(PlatformException e) {
    final code = PurchasesErrorHelper.getErrorCode(e);
    final detail = e.message ?? code.toString();
    return '${code.name}: $detail';
  }

  /// Forces a fresh fetch of offerings from RevenueCat. Call from the paywall
  /// when offerings weren't pre-fetched (e.g. init ran offline).
  Future<Offering?> fetchOfferings() async {
    if (!_supportedPlatform) return null;
    try {
      _offerings = await Purchases.getOfferings();
      _lastError = null;
      notifyListeners();
      return _offerings?.current;
    } on PlatformException catch (e) {
      _lastError = _describeError(e);
      debugPrint('[PurchaseService] fetchOfferings failed: $_lastError');
      notifyListeners();
      return null;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('[PurchaseService] fetchOfferings failed: $_lastError');
      notifyListeners();
      return null;
    }
  }

  /// Attempts to purchase [package]. Returns true if the user is now pro.
  /// User-cancelled purchases return false without throwing.
  Future<bool> purchase(Package package) async {
    if (!_supportedPlatform) return false;
    debugPrint(
        '[PurchaseService] purchase() start id=${package.identifier} type=${package.packageType}');
    try {
      final result = await Purchases.purchasePackage(package);
      _applyCustomerInfo(result);
      debugPrint(
          '[PurchaseService] purchase() returned. isPro=$_isPro isInTrial=$_isInTrial');
      return _isPro;
    } on PlatformException catch (e) {
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code == PurchasesErrorCode.purchaseCancelledError) {
        debugPrint('[PurchaseService] purchase() cancelled by user');
        return false;
      }
      debugPrint('[PurchaseService] purchase() failed: $code — ${e.message}');
      rethrow;
    }
  }

  /// Restores previously-purchased entitlements. Returns true if a pro
  /// entitlement was found and applied.
  Future<bool> restore() async {
    if (!_supportedPlatform) return _isPro;
    debugPrint('[PurchaseService] restore() start');
    try {
      final info = await Purchases.restorePurchases();
      _applyCustomerInfo(info);
      debugPrint('[PurchaseService] restore() returned. isPro=$_isPro');
      return _isPro;
    } catch (e) {
      debugPrint('[PurchaseService] restore() failed: $e');
      return _isPro;
    }
  }

  void _onCustomerInfoUpdate(CustomerInfo info) {
    debugPrint('[PurchaseService] customerInfo listener fired');
    _applyCustomerInfo(info);
  }

  /// Pulls entitlement + trial state out of [info] and updates internal flags.
  /// Side-effect: when the entitlement transitions into an active trial we
  /// schedule the single Day-3 reminder (idempotent).
  void _applyCustomerInfo(CustomerInfo info, {bool notify = true}) {
    final activeKeys = info.entitlements.active.keys.toList();
    debugPrint(
        '[PurchaseService] applyCustomerInfo active=$activeKeys looking_for="$entitlementId"');

    final ent = info.entitlements.active[entitlementId];
    final isActive = ent != null && ent.isActive;
    final isTrial = isActive && ent.periodType == PeriodType.trial;

    final wasPro = _isPro;
    final wasTrial = _isInTrial;
    _isPro = isActive;
    _isInTrial = isTrial;

    if (wasPro != _isPro) {
      debugPrint(
          '[PurchaseService] isPro transition $wasPro → $_isPro (trial=$_isInTrial)');
    }

    // First time we see a trial activation → persist start + schedule the
    // single reminder. Subsequent updates while in-trial are no-ops because
    // the scheduling call is idempotent.
    if (isTrial && !wasTrial) {
      _onTrialActivated();
    }

    // Trial converted to a regular yearly billing (or any non-trial state) →
    // cancel any pending Day-3 reminder, it would be confusing now.
    if (wasTrial && !isTrial && isActive) {
      unawaited(NotificationService.instance.cancelTrialReminder());
    }

    final changed = wasPro != _isPro || wasTrial != _isInTrial;
    if (notify && changed) notifyListeners();
  }

  void _onTrialActivated() {
    final prefs = PreferencesService.instance;
    final existing = prefs.trialStartedAt;
    final start = existing ?? DateTime.now();
    if (existing == null) {
      unawaited(prefs.setTrialStartedAt(start));
    }
    unawaited(
      NotificationService.instance.scheduleTrialEndingReminder(
        trialStartedAt: start,
      ),
    );
  }

  bool get _supportedPlatform => Platform.isIOS || Platform.isAndroid;
}
