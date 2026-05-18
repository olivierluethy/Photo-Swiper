import 'package:shared_preferences/shared_preferences.dart';

/// Persists user preferences across app launches.
/// Call [init] once in main() before runApp.
class PreferencesService {
  PreferencesService._();
  static final PreferencesService instance = PreferencesService._();

  static const _keyLeftHanded = 'left_handed_mode';
  static const _keyOnboardingComplete = 'onboarding_complete';
  static const _keySwipeHintCount = 'swipe_hint_count';
  static const _keyTrialStartedAt = 'trial_started_at_ms';
  static const _keyTrialReminderScheduled = 'trial_reminder_scheduled';
  static const _keyCompletedMonths = 'completed_months';
  static const _keyShowCompletedMonths = 'show_completed_months';
  static const _keyMonthSortMode = 'month_sort_mode';
  static const _keyLastNewlyCompleted = 'last_newly_completed_month';

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

  // ─── Onboarding completion ────────────────────────────────────────────────
  //
  // The flag becomes true only after the user has finished the *entire*
  // onboarding funnel:
  //   1. Walked (or skipped) the three intro slides.
  //   2. Responded to the notification permission prompt.
  //   3. Responded to the photo-library permission prompt.
  //   4. Confirmed a weekly or yearly purchase via Apple's StoreKit sheet.
  //
  // Set from `PaywallScreen._exitOnSuccess` (the only point at which all
  // four conditions are jointly true). Users who quit before completing
  // step 4 will re-enter at /intro on the next launch — which is the
  // explicit product requirement, not an oversight.
  bool get isOnboardingComplete =>
      _prefs.getBool(_keyOnboardingComplete) ?? false;

  Future<void> setOnboardingComplete(bool value) =>
      _prefs.setBool(_keyOnboardingComplete, value);

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

  // ─── Month completion tracking ────────────────────────────────────────────
  // Keys are "YYYY-MM" so October 2024 (`2024-10`) is independent from
  // October 2023 (`2023-10`). Persisted as a SharedPreferences string list.
  static String monthKey(int year, int month) =>
      '$year-${month.toString().padLeft(2, '0')}';

  Set<String> get completedMonths {
    final list = _prefs.getStringList(_keyCompletedMonths) ?? const [];
    return list.toSet();
  }

  bool isMonthCompleted(int year, int month) =>
      completedMonths.contains(monthKey(year, month));

  /// Marks a year/month as completed. Idempotent. Also records the key so
  /// the home screen can play a one-shot animation on the corresponding
  /// card; the home screen consumes and clears that flag on read.
  Future<void> markMonthCompleted(int year, int month) async {
    final key = monthKey(year, month);
    final set = completedMonths;
    final wasNew = set.add(key);
    if (wasNew) {
      await _prefs.setStringList(_keyCompletedMonths, set.toList());
      await _prefs.setString(_keyLastNewlyCompleted, key);
    }
  }

  Future<void> unmarkMonthCompleted(int year, int month) async {
    final key = monthKey(year, month);
    final set = completedMonths;
    if (set.remove(key)) {
      await _prefs.setStringList(_keyCompletedMonths, set.toList());
    }
  }

  /// One-shot read: returns the most recently completed month key (or null)
  /// and clears the value so the animation only plays once.
  Future<String?> consumeLastNewlyCompleted() async {
    final key = _prefs.getString(_keyLastNewlyCompleted);
    if (key != null) {
      await _prefs.remove(_keyLastNewlyCompleted);
    }
    return key;
  }

  // ─── View preferences ─────────────────────────────────────────────────────
  bool get showCompletedMonths =>
      _prefs.getBool(_keyShowCompletedMonths) ?? true;
  Future<void> setShowCompletedMonths(bool value) =>
      _prefs.setBool(_keyShowCompletedMonths, value);

  /// Persisted sort/filter mode for the home month grid. Stored as the enum
  /// index so renames in code don't accidentally remap stored values — keep
  /// the [MonthSort] declaration order stable.
  MonthSort get monthSortMode {
    final i = _prefs.getInt(_keyMonthSortMode) ?? 0;
    if (i < 0 || i >= MonthSort.values.length) return MonthSort.defaultOrder;
    return MonthSort.values[i];
  }

  Future<void> setMonthSortMode(MonthSort mode) =>
      _prefs.setInt(_keyMonthSortMode, mode.index);
}

/// Ordering / filtering modes for the home-screen month grid.
///
/// Index is persisted to SharedPreferences — only append new modes at the
/// end; do not reorder or delete existing entries.
enum MonthSort {
  defaultOrder, // chronological (newest month → oldest, current display)
  largestFirst, // by total file bytes, descending
  smallestFirst, // by total file bytes, ascending
  completedOnly, // filter: only months marked complete
}
