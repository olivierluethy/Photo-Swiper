import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'preferences_service.dart';

/// Local-notification surface for FlickClean. Used for exactly one event:
/// a single, polite reminder on Day 3 of the user's free trial. No campaigns,
/// no marketing pushes, no re-engagement loops.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const int _trialReminderId = 1001;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Idempotent. Sets up the timezone database and platform plugins.
  /// Safe to call from main() before runApp.
  Future<void> init() async {
    if (_initialized) return;
    try {
      tzdata.initializeTimeZones();
      const iosInit = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const androidInit =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const settings = InitializationSettings(
        iOS: iosInit,
        macOS: iosInit,
        android: androidInit,
      );
      await _plugin.initialize(settings);
      _initialized = true;
    } catch (e) {
      debugPrint('[NotificationService] init failed: $e');
    }
  }

  /// Requests notification authorization. Returns true if granted. Silent
  /// failures default to false — we never block the purchase flow on this.
  Future<bool> requestPermission() async {
    if (!_initialized) await init();
    try {
      if (Platform.isIOS || Platform.isMacOS) {
        final ios = _plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
        final granted = await ios?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            false;
        return granted;
      }
      if (Platform.isAndroid) {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        final granted = await android?.requestNotificationsPermission() ?? true;
        return granted;
      }
      return false;
    } catch (e) {
      debugPrint('[NotificationService] requestPermission failed: $e');
      return false;
    }
  }

  /// Schedules the single Day-3 trial-ending reminder. Idempotent — if a
  /// reminder has already been scheduled for the current trial, this is a
  /// no-op. The notification is auto-cancelled if the user subscribes early
  /// via [cancelTrialReminder].
  Future<void> scheduleTrialEndingReminder({
    required DateTime trialStartedAt,
  }) async {
    if (!_initialized) await init();
    if (PreferencesService.instance.trialReminderScheduled) return;

    // The trial is 3 days long. Fire the notification right at the end so the
    // user has the full window before being prompted. If for any reason the
    // trial start was already 3+ days ago (e.g. restored on a new device),
    // skip the schedule — sending an instantly-overdue notice would feel
    // off-tempo and slightly spammy.
    final fireAt = trialStartedAt.add(const Duration(days: 3));
    if (fireAt.isBefore(DateTime.now().add(const Duration(minutes: 5)))) {
      return;
    }

    final tzFireAt = tz.TZDateTime.from(fireAt, tz.local);

    const details = NotificationDetails(
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
      android: AndroidNotificationDetails(
        'flickclean_trial',
        'Trial reminders',
        channelDescription: 'A single reminder when your free trial is ending.',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );

    try {
      await _plugin.zonedSchedule(
        _trialReminderId,
        'Your FlickClean trial ends today',
        'Continue anytime to keep organizing your photo library.',
        tzFireAt,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      await PreferencesService.instance.setTrialReminderScheduled(true);
    } catch (e) {
      debugPrint('[NotificationService] schedule failed: $e');
    }
  }

  /// Cancels the pending reminder (e.g. the user upgraded mid-trial or
  /// switched plans). Cheap to call defensively.
  Future<void> cancelTrialReminder() async {
    if (!_initialized) await init();
    try {
      await _plugin.cancel(_trialReminderId);
    } catch (_) {/* silent */}
  }
}
