// Rapid-swipe stress tests for [SwipeCard].
//
// These drive the real swipe widget (where the Phase 2 gesture-lockout fix
// lives) with programmatic flings/drags, so we can deterministically verify:
//   • fast consecutive swipes each commit (no silent drops),
//   • a new drag interrupts an in-flight snap-back instead of being swallowed,
//   • input during the (now-short) fly-off is recorded as `swipe_input_ignored`
//     reason 'locked',
//   • the fly-off commits quickly (~160ms lockout, down from 280ms).
//
// The full app gates behind onboarding + a StoreKit purchase and photo_manager
// needs a real photo library, so the swipe screen can't be reached on a fresh
// simulator — driving the card widget directly is the meaningful way to
// stress-test the rapid-swipe path.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:photo_swiper/widgets/swipe_card.dart';

/// Mirrors the real screen: rebuilds the card with a fresh [ValueKey] on every
/// committed decision (the `_cardKey++` behaviour in SwipeScreen), so each
/// swipe lands on a brand-new card just like in production.
class _Harness extends StatefulWidget {
  final void Function(bool right) onCommit;
  final void Function(String reason) onIgnored;
  const _Harness({required this.onCommit, required this.onIgnored});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  int _key = 0;

  void _commit(bool right) {
    widget.onCommit(right);
    setState(() => _key++); // new card, fresh gesture state
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 520,
            child: SwipeCard(
              key: ValueKey(_key),
              onSwipeRight: () => _commit(true),
              onSwipeLeft: () => _commit(false),
              onInputIgnored: widget.onIgnored,
              child: Container(color: Colors.blue),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('20 rapid spaced flings each commit a swipe (none dropped)',
      (tester) async {
    int commits = 0;
    final ignored = <String>[];
    await tester.pumpWidget(
        _Harness(onCommit: (_) => commits++, onIgnored: ignored.add));

    for (int i = 0; i < 20; i++) {
      await tester.fling(
          find.byType(SwipeCard), const Offset(420, 0), 1400);
      await tester.pumpAndSettle();
    }

    expect(commits, 20, reason: 'every spaced swipe should commit');
    expect(ignored, isEmpty,
        reason: 'spaced swipes land on a ready card and are never dropped');
  });

  testWidgets('a drag during snap-back is honored, not dropped (Fix 3)',
      (tester) async {
    int commits = 0;
    final ignored = <String>[];
    await tester.pumpWidget(
        _Harness(onCommit: (_) => commits++, onIgnored: ignored.add));

    final finder = find.byType(SwipeCard);
    final center = tester.getCenter(finder);

    // Below-threshold drag (40px) released slowly -> low velocity -> snap-back.
    final g1 = await tester.startGesture(center);
    await g1.moveBy(const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await g1.moveBy(const Offset(20, 0)); // total 40px (< 80px threshold)
    await tester.pump(const Duration(milliseconds: 140)); // dwell -> velocity ~0
    await g1.up();

    // Snap-back is ~300ms; interrupt it partway through.
    await tester.pump(const Duration(milliseconds: 60));

    // New drag well past threshold should take over and commit.
    final g2 = await tester.startGesture(center);
    await g2.moveBy(const Offset(160, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await g2.up();
    await tester.pumpAndSettle();

    expect(commits, 1,
        reason: 'the interrupting drag should complete a swipe');
    expect(ignored, isNot(contains('locked')),
        reason: 'a snap-back drag must NOT be reported as dropped');
  });

  testWidgets('input during the fly-off is recorded as locked (Fix 4)',
      (tester) async {
    int commits = 0;
    final ignored = <String>[];
    await tester.pumpWidget(
        _Harness(onCommit: (_) => commits++, onIgnored: ignored.add));

    final center = tester.getCenter(find.byType(SwipeCard));

    // First swipe just past the 80px threshold -> fly-off begins; `_locked`
    // is set true synchronously. Kept small so the card is still under the
    // original centre when the second gesture lands.
    final g1 = await tester.startGesture(center);
    await g1.moveBy(const Offset(90, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await g1.up();
    await tester.pump(); // one frame: fly-off scheduled, card still ~centred

    // A second swipe lands while locked and the card is still under the
    // pointer -> should be recorded, not silently lost.
    final g2 = await tester.startGesture(center);
    await g2.moveBy(const Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await g2.up();
    await tester.pumpAndSettle();

    expect(ignored, contains('locked'),
        reason: 'a swipe during the fly-off lock must emit reason "locked"');
    expect(commits, 1, reason: 'only the first swipe commits');
  });

  testWidgets('fly-off commits within the shortened ~160ms lockout',
      (tester) async {
    int commits = 0;
    await tester.pumpWidget(
        _Harness(onCommit: (_) => commits++, onIgnored: (_) {}));

    await tester.fling(find.byType(SwipeCard), const Offset(420, 0), 1500);
    await tester.pump(); // kick off the fly-off animation
    await tester.pump(const Duration(milliseconds: 180)); // past 160ms duration
    await tester.pump(); // let the commit callback + rebuild run

    expect(commits, 1, reason: 'fly-off should commit within ~180ms');
  });
}
