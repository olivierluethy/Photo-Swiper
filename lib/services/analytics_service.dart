import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

/// Thin wrapper around PostHog. All calls are swallowed on failure so a
/// broken analytics layer can never crash the app or interrupt the user.
///
/// PostHog is configured via Info.plist (iOS) and AndroidManifest.xml
/// (Android); this service does not pass an API key. The native SDK
/// auto-initializes on first use from those manifest keys.
///
/// On top of PostHog this service maintains:
///
///   • a per-process session id (rotated whenever the app comes back to
///     the foreground), registered as a super-property so every event
///     carries it without callers having to remember,
///   • device + screen metadata (model, iOS version, pixel dimensions,
///     pixel ratio, phone vs tablet) registered the same way,
///   • a `currentScreen` cursor and an "entered at" timestamp so the
///     session-end + dropoff events know what the user was looking at
///     when they backgrounded the app,
///   • a `plansViewed` set populated by the paywall so the
///     `user_closed_app_during_paywall` event can report which plans the
///     user actually tapped before bailing.
class AnalyticsService {
  AnalyticsService._();
  static final AnalyticsService instance = AnalyticsService._();

  final Posthog _posthog = Posthog();
  final DateTime _appOpenedAt = DateTime.now();

  // ─── Session ────────────────────────────────────────────────────────────
  String _sessionId = _newSessionId();
  DateTime _sessionStartedAt = DateTime.now();
  String get sessionId => _sessionId;

  // ─── Screen tracking (for session_ended / dropoff) ──────────────────────
  String? _currentScreen;
  DateTime? _currentScreenEnteredAt;
  String? get currentScreen => _currentScreen;
  int get secondsOnCurrentScreen {
    final t = _currentScreenEnteredAt;
    if (t == null) return 0;
    return DateTime.now().difference(t).inSeconds;
  }

  // ─── Paywall transient state ────────────────────────────────────────────
  // Used by `user_closed_app_during_paywall` so we can report which plans
  // the user actually tapped before backgrounding the app.
  final Set<String> _plansViewed = <String>{};
  void notePlanViewed(String plan) => _plansViewed.add(plan);
  void clearPlansViewed() => _plansViewed.clear();
  List<String> get plansViewed => _plansViewed.toList(growable: false);

  // ─── Init ───────────────────────────────────────────────────────────────
  Future<void> init() async {
    try {
      await _posthog.enable();
    } catch (_) {/* silent */}
    await _registerStaticSuperProperties();
    _registerSessionSuperProperties();
  }

  Future<void> _registerStaticSuperProperties() async {
    try {
      final info = await PackageInfo.fromPlatform();
      await _setProperty('app_version', info.version);
      await _setProperty('platform', Platform.isIOS ? 'ios' : 'android');
    } catch (_) {/* silent */}

    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isIOS) {
        final ios = await deviceInfo.iosInfo;
        // utsname.machine returns the hardware id (e.g. "iPhone15,3");
        // model returns a friendlier "iPhone" / "iPad". Combine for a
        // value that's both human-readable and SKU-specific.
        final hw = ios.utsname.machine;
        final model = ios.model;
        await _setProperty(
            'device_model', hw.isNotEmpty ? '$model ($hw)' : model);
        await _setProperty('ios_version', ios.systemVersion);
        await _setProperty('device_class',
            ios.model.toLowerCase().contains('ipad') ? 'tablet' : 'phone');
      } else if (Platform.isAndroid) {
        final a = await deviceInfo.androidInfo;
        await _setProperty('device_model', '${a.manufacturer} ${a.model}');
        await _setProperty('os_version', a.version.release);
        await _setProperty('device_class', 'phone');
      }
    } catch (_) {/* silent */}

    // Screen pixel size + density. Pulled from the platform dispatcher so
    // we don't need a BuildContext at init time. PostHog accepts strings,
    // ints, doubles — keep types simple.
    try {
      final view =
          WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
      if (view != null) {
        final size = view.physicalSize;
        final dpr = view.devicePixelRatio;
        await _setProperty(
            'screen_size_pixels', '${size.width.toInt()}x${size.height.toInt()}');
        await _setProperty('screen_width_pixels', size.width.toInt());
        await _setProperty('screen_height_pixels', size.height.toInt());
        await _setProperty('device_pixel_ratio',
            double.parse(dpr.toStringAsFixed(2)));
      }
    } catch (_) {/* silent */}
  }

  void _registerSessionSuperProperties() {
    _setProperty('session_id', _sessionId);
  }

  /// Rotate the session id (call when the app comes back to foreground)
  /// and re-register it so subsequent events carry the new id.
  void rotateSession() {
    _sessionId = _newSessionId();
    _sessionStartedAt = DateTime.now();
    _setProperty('session_id', _sessionId);
  }

  Future<void> _setProperty(String key, Object value) async {
    try {
      await _posthog.register(key, value);
    } catch (_) {/* silent */}
  }

  static String _newSessionId() {
    // Compact, URL-safe, time-sortable id. Not cryptographic — fine for
    // segmentation in PostHog dashboards.
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final rand = math.Random().nextInt(1 << 32).toRadixString(36);
    return 's_${ts}_$rand';
  }

  // ─── Event surface ──────────────────────────────────────────────────────
  Future<void> track(
    String event, {
    Map<String, Object>? properties,
  }) async {
    try {
      final merged = <String, Object>{
        'time_in_app_seconds':
            DateTime.now().difference(_appOpenedAt).inSeconds,
        if (_currentScreen != null) 'current_screen': _currentScreen!,
      };
      if (properties != null) merged.addAll(properties);
      await _posthog.capture(eventName: event, properties: merged);
      if (kDebugMode) {
        debugPrint('[analytics] $event ${merged.toString()}');
      }
    } catch (_) {/* silent */}
  }

  Future<void> screen(
    String screenName, {
    Map<String, Object>? properties,
  }) async {
    _currentScreen = screenName;
    _currentScreenEnteredAt = DateTime.now();
    try {
      await _posthog.screen(
          screenName: screenName, properties: properties);
    } catch (_) {/* silent */}
  }

  // ─── Convenience: funnel events ────────────────────────────────────────
  // Centralised so funnel queries can rely on a consistent property
  // schema (step + status, plus any per-step extras).
  Future<void> funnelStep(
    int step, {
    required String event,
    required String status,
    Map<String, Object>? extras,
  }) {
    final props = <String, Object>{
      'step': step,
      'status': status,
      if (extras != null) ...extras,
    };
    return track(event, properties: props);
  }

  Future<void> dropOff({
    required int lastCompletedStep,
    required String reason,
    Map<String, Object>? extras,
  }) {
    return track(
      AnalyticsEventsHook.funnelDropOff,
      properties: {
        'last_completed_step': lastCompletedStep,
        'reason': reason,
        if (extras != null) ...extras,
      },
    );
  }

  // ─── Session events ────────────────────────────────────────────────────
  Future<void> emitSessionStarted() {
    return track('session_started', properties: {
      'session_started_at': _sessionStartedAt.toIso8601String(),
    });
  }

  Future<void> emitSessionEnded({String? finalScreen}) {
    return track('session_ended', properties: {
      'total_duration_seconds':
          DateTime.now().difference(_sessionStartedAt).inSeconds,
      if (finalScreen != null) 'final_screen': finalScreen,
      if (_currentScreen != null && finalScreen == null)
        'final_screen': _currentScreen!,
    });
  }

  /// PostHog's `register` API takes one key/value pair at a time, so we
  /// iterate. Useful for ad-hoc super-property updates (e.g. user_id once
  /// the user is identified).
  Future<void> setUserProperties(Map<String, Object> properties) async {
    for (final entry in properties.entries) {
      await _setProperty(entry.key, entry.value);
    }
  }
}

/// Tiny indirection so [AnalyticsService] doesn't take a hard import on
/// the event-catalog file (which would create a cycle since the catalog
/// might one day reference the service).
class AnalyticsEventsHook {
  AnalyticsEventsHook._();
  static const String funnelDropOff = 'funnel_drop_off';
}
