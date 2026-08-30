# Remember the selected year after cleaning a month

**Date:** 2026-08-30
**Status:** Approved

## Problem

After finishing a cleanup session the result screen offers two buttons,
`Back to Home` and `Clean another month`. They are duplicates — both call
`Navigator.pushNamedAndRemoveUntil(context, '/home', (r) => false)`
(`lib/screens/result_screen.dart:67` and `:202`).

Worse, `HomeScreen._init()` hard-codes the current year on every load
(`lib/screens/home_screen.dart:96`), so a user who has just cleaned
March 2019 is dropped back onto 2026 and has to re-select 2019 by hand.
Reported by an older user working through an old photo library year by
year: the app silently throws away the year he was working in.

## Goal

`Clean another month` returns to the home screen with the year he was
working in still selected, so he can pick the next month himself.

## Non-goals

- Auto-advancing into the next month's swipe session. Considered and
  rejected: it removes his control over which month comes next.
- Crossing into the next year automatically when a year is exhausted.
  Same reason.
- Threading `month`/`year` from `SwipeScreen` through `ReviewScreen` into
  `ResultScreen`. Unnecessary — see below.

## Design

The year is persisted at the moment the user *selects* it on the home
screen, not when a session ends. This is what makes the change small:
`ResultScreen` keeps doing a plain `pushNamedAndRemoveUntil('/home')` and
knows nothing about months or years, while `HomeScreen` restores the
remembered year on load. The back button out of a month and a full app
relaunch get the same behavior for free, from the same one rule.

### 1. `PreferencesService` — store the year

New key `last_selected_year` (int), alongside the existing
`_keyMonthSortMode` / `_keyCompletedMonths` declarations:

```dart
static const _keyLastSelectedYear = 'last_selected_year';

int? get lastSelectedYear => _prefs.getInt(_keyLastSelectedYear);

Future<void> setLastSelectedYear(int year) =>
    _prefs.setInt(_keyLastSelectedYear, year);
```

Nullable getter, not a defaulted one: "never chosen a year" and "chose
the current year" are different states, and only the first should defer
to the current-year default.

### 2. `resolveInitialYear` — the fallback chain, as a pure function

`HomeScreen._init()` currently needs `MediaService` and
`SharedPreferences` to run, so its year choice cannot be unit-tested. The
choice is extracted into a top-level pure function in
`lib/screens/home_screen.dart`:

```dart
/// Picks which year the home screen opens on. Visible for testing.
int resolveInitialYear({
  required List<int> availableYears,
  required int? rememberedYear,
  required int currentYear,
}) {
  if (rememberedYear != null && availableYears.contains(rememberedYear)) {
    return rememberedYear;
  }
  if (availableYears.contains(currentYear)) return currentYear;
  return availableYears.first;
}
```

Precedence: remembered year → current year → earliest available. Steps 2
and 3 are today's behavior unchanged, so a first-run user, and a user
whose remembered year no longer appears in `getAvailableYears()` because
he deleted every photo in it, both see exactly what they see today.

The caller must not invoke it with an empty `availableYears` —
`_init()` is only reached with a non-empty list (see Open questions).

### 3. `HomeScreen` — restore and record

`_init()` replaces its hard-coded assignment with a call to
`resolveInitialYear`, passing `PreferencesService.instance.lastSelectedYear`.

`_selectYear(int year)` gains an unawaited
`PreferencesService.instance.setLastSelectedYear(year)` next to the
existing `setMonthSortMode` pattern in `_setSortMode`. Fire-and-forget is
correct here: a dropped write costs one wrong year on next launch, and
blocking the tap on disk IO would be worse.

`_init()` does not write the resolved year back to prefs. Only an
explicit tap records a year, so a fallback never overwrites a year the
user picked deliberately.

### 4. `ResultScreen` — one button

- Delete the grey `Clean another month` `TextButton` (`:201–209`) and the
  `SizedBox(height: 16)` that precedes it.
- Relabel the primary `ElevatedButton` from `Back to Home` to
  `Clean another month`. It keeps calling `_goHome()` unchanged.

Result: one full-width button, one behavior, no duplicate. The bigger
tap target also suits the reporting user.

## Testing

`test/home_year_test.dart`, unit tests over `resolveInitialYear` — no
mocks needed:

1. Remembered year present in `availableYears` → returned.
2. Remembered year absent (photos all deleted) → current year.
3. Remembered year absent *and* current year absent → `years.first`.
4. `rememberedYear` null (first run) → current year.
5. `rememberedYear` null and current year absent → `years.first`.

The `ResultScreen` change is a label edit and a widget deletion, with no
logic to cover.

### Pre-existing broken test

`flutter test` is red on this branch before any of this work:
`test/widget_test.dart` is the unmodified Flutter counter template and
references a `MyApp` class that does not exist in this app, so it fails
to compile. `test/swipe_card_rapid_test.dart` passes, 4/4.

The implementation deletes `test/widget_test.dart`. It tests a counter
app this project never had, it cannot be made to pass without being
rewritten from scratch, and leaving it red makes "the tests pass" a
meaningless claim for this change. This is the one deliberate scope
addition in the plan.

## Files touched

- `lib/services/preferences_service.dart` — new key, getter, setter.
- `lib/screens/home_screen.dart` — `resolveInitialYear`, `_init`, `_selectYear`.
- `lib/screens/result_screen.dart` — remove secondary button, relabel primary.
- `test/home_year_test.dart` — new.
- `test/widget_test.dart` — deleted (stock template, does not compile).

## Open questions

None blocking. One pre-existing sharp edge is inherited rather than
introduced: `_init()` calls `years.first` on the result of
`getAvailableYears()` without an empty check, which would throw for a
user with a granted photo permission and zero photos. This design keeps
that behavior identical and does not fix it — out of scope, worth a
separate issue.
