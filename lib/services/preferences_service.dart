import 'package:shared_preferences/shared_preferences.dart';

/// Persists user preferences across app launches.
/// Call [init] once in main() before runApp.
class PreferencesService {
  PreferencesService._();
  static final PreferencesService instance = PreferencesService._();

  static const _keyLeftHanded = 'left_handed_mode';
  // ignore: unused_field
  // Kept so reverting the dev override below is a one-line edit.
  static const _keyOnboarding = 'has_seen_onboarding';
  static const _keySwipeHintCount = 'swipe_hint_count';
  static const _keyTrialStartedAt = 'trial_started_at_ms';
  static const _keyTrialReminderScheduled = 'trial_reminder_scheduled';

  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ─── Left-handed mode ─────────────────────────────────────────────────────
  // false (default): swipe right = keep,   swipe left = delete
  // true:            swipe right = delete, swipe left = keep
  bool get isLeftHanded => _prefs.getBool(_keyLeftHanded) ?? false;
  Future<void> setLeftHanded(bool value) =>
      _prefs.setBool(_keyLeftHanded, value);

  // ─── Onboarding ───────────────────────────────────────────────────────────
  //
  // ⚠️ DEV OVERRIDE — onboarding is forced to run on every cold launch so
  // the intro + paywall flow can be verified visually after each build.
  // No reinstall, no flag wipe, no clear-cache required.
  //
  // To restore production behaviour, replace these two members with their
  // original implementations (preserved below as comments):
  //
  //   bool get hasSeenOnboarding => _prefs.getBool(_keyOnboarding) ?? false;
  //   Future<void> setHasSeenOnboarding(bool value) =>
  //       _prefs.setBool(_keyOnboarding, value);
  bool get hasSeenOnboarding => false;
  Future<void> setHasSeenOnboarding(bool value) async {
    // No-op while the dev override is active so the persisted flag never
    // gets written; ignores any value already in SharedPreferences.
  }

  // ─── Swipe hint fade-out ──────────────────────────────────────────────────
  // Counts completed swipes; used to progressively fade the edge direction
  // hints. Capped at 20 — once hints are invisible there's no point tracking.
  int get swipeHintCount => _prefs.getInt(_keySwipeHintCount) ?? 0;
  Future<void> incrementSwipeHintCount() async {
    final n = swipeHintCount;
    if (n < 20) await _prefs.setInt(_keySwipeHintCount, n + 1);
  }

  // ─── Trial tracking ───────────────────────────────────────────────────────
  // Set when the user purchases the weekly product with an active intro trial.
  // Used to schedule the single Day-3 ending reminder.
  DateTime? get trialStartedAt {
    final ms = _prefs.getInt(_keyTrialStartedAt);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setTrialStartedAt(DateTime when) =>
      _prefs.setInt(_keyTrialStartedAt, when.millisecondsSinceEpoch);

  bool get trialReminderScheduled =>
      _prefs.getBool(_keyTrialReminderScheduled) ?? false;

  Future<void> setTrialReminderScheduled(bool value) =>
      _prefs.setBool(_keyTrialReminderScheduled, value);
}
