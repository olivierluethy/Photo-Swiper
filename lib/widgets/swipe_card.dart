import 'dart:async';
import 'package:flutter/material.dart';

/// Tinder-style swipe card with animated KEEP / DELETE overlays.
///
/// Motion-based guidance: after [_idleDelay] of no touch, the card plays a
/// gentle two-phase nudge (KEEP direction then DELETE direction) so users
/// feel which way to swipe without needing to read text. The nudge runs at
/// most once per card instance and stops permanently once [hintOpacity] == 0.
///
/// Provide a unique [ValueKey] tied to the current item index so Flutter
/// creates a fresh widget (and fresh gesture state) for every new card.
class SwipeCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onSwipeLeft;
  final VoidCallback onSwipeRight;
  /// When true stamp labels are flipped: right = DELETE, left = KEEP.
  final bool leftHandedMode;
  /// When true horizontal-drag recognizers are removed so InteractiveViewer
  /// can pan a zoomed image freely.
  final bool isZoomed;
  /// > 0  → idle-nudge guidance is active for this card.
  ///   0  → user has swiped enough; nudge never fires.
  final double hintOpacity;

  /// Called when a gesture is dropped because the card is mid fly-off
  /// (committing the previous decision). [reason] is currently always
  /// `'locked'`. Fire-and-forget instrumentation; never blocks the gesture.
  final void Function(String reason)? onInputIgnored;

  const SwipeCard({
    super.key,
    required this.child,
    required this.onSwipeLeft,
    required this.onSwipeRight,
    this.leftHandedMode = false,
    this.isZoomed = false,
    this.hintOpacity = 0.0,
    this.onInputIgnored,
  });

  @override
  State<SwipeCard> createState() => _SwipeCardState();
}

class _SwipeCardState extends State<SwipeCard> with TickerProviderStateMixin {
  late final AnimationController _ctrl;      // fly-off / snap-back
  late final AnimationController _nudgeCtrl; // idle nudge sequence

  double _offset = 0;
  bool _locked  = false; // true while fly-off or snap-back animates
  bool _snappingBack = false; // true only while a (cancelable) snap-back runs
  bool _nudging = false; // true while nudge sequence is running
  bool _nudgePlayed = false; // at most one nudge per card instance
  Timer? _idleTimer;

  static const double _swipeThresholdPx       = 80;
  static const double _swipeThresholdVelocity  = 600;
  static const double _nudgeDistance           = 30; // px
  static const Duration _idleDelay             = Duration(seconds: 3);

  // Fly-off commits a decision and must run to completion, so it briefly locks
  // input — kept short (was 280ms) so fast swipers rarely hit the window.
  static const Duration _flyOffDuration   = Duration(milliseconds: 160);
  // Snap-back is a cancelable "return to centre"; a new drag interrupts it
  // (see _onUpdate), so its duration only affects the resting animation feel.
  static const Duration _snapBackDuration = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    _ctrl      = AnimationController(vsync: this);
    _nudgeCtrl = AnimationController(vsync: this);
    // Wait for the first frame so layout dimensions are ready.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startIdleTimer());
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _ctrl.dispose();
    _nudgeCtrl.dispose();
    super.dispose();
  }

  // ─── Idle nudge ───────────────────────────────────────────────────────────────

  void _startIdleTimer() {
    _idleTimer?.cancel();
    if (widget.hintOpacity <= 0 || _nudgePlayed || _nudging || _locked) return;
    _idleTimer = Timer(_idleDelay, _performNudge);
  }

  /// Cancel any pending timer and interrupt an in-progress nudge.
  /// The card stays at its current offset so a user drag continues seamlessly.
  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_nudging) {
      // canceled: false → TickerFuture completes normally instead of throwing.
      _nudgeCtrl.stop(canceled: false);
      _nudging = false;
    }
  }

  Future<void> _performNudge() async {
    if (_locked || _nudging || _nudgePlayed || !mounted) return;
    if (widget.hintOpacity <= 0) return;

    _nudgePlayed = true;
    _nudging     = true;

    // Nudge KEEP direction first (the encouraging action), then DELETE.
    // Default:      KEEP = right (+1), DELETE = left (−1)
    // Left-handed:  KEEP = left  (−1), DELETE = right (+1)
    final keepSign = widget.leftHandedMode ? -1.0 : 1.0;

    // Phase 1 — drift toward KEEP, snap back
    await _animateNudge(keepSign * _nudgeDistance, 360, Curves.easeOut);
    if (!_nudging || !mounted) return;
    await Future.delayed(const Duration(milliseconds: 100));
    if (!_nudging || !mounted) return;
    await _animateNudge(0, 300, Curves.easeInOut);
    if (!_nudging || !mounted) return;

    await Future.delayed(const Duration(milliseconds: 220));
    if (!_nudging || !mounted) return;

    // Phase 2 — drift toward DELETE, snap back
    await _animateNudge(-keepSign * _nudgeDistance, 360, Curves.easeOut);
    if (!_nudging || !mounted) return;
    await Future.delayed(const Duration(milliseconds: 80));
    if (!_nudging || !mounted) return;
    await _animateNudge(0, 300, Curves.easeInOut);

    _nudging = false;
  }

  /// Animate `_offset` to [target] over [ms] milliseconds using [curve].
  /// Uses try/finally so a stop(canceled:false) always removes the listener.
  Future<void> _animateNudge(double target, int ms, Curve curve) async {
    if (!mounted) return;
    _nudgeCtrl.duration = Duration(milliseconds: ms);
    final anim = Tween<double>(begin: _offset, end: target)
        .animate(CurvedAnimation(parent: _nudgeCtrl, curve: curve));

    void listener() {
      if (mounted) setState(() => _offset = anim.value);
    }

    anim.addListener(listener);
    try {
      await _nudgeCtrl.forward(from: 0);
    } catch (_) {
      // TickerCanceled — nudge was interrupted; exit cleanly.
    } finally {
      anim.removeListener(listener);
      _nudgeCtrl.reset();
    }
  }

  // ─── Gesture handlers ────────────────────────────────────────────────────────

  void _onUpdate(DragUpdateDetails d) {
    if (_locked) {
      // A snap-back is cancelable: let a fresh drag take over from the current
      // offset instead of being silently dropped. A fly-off is a committed
      // decision and is never interrupted.
      if (_snappingBack) {
        _ctrl.stop(canceled: false);
        _snappingBack = false;
        _locked = false;
      } else {
        return; // fly-off in progress — committed, can't accept this drag.
      }
    }
    _cancelIdleTimer(); // any touch cancels the nudge immediately
    setState(() => _offset += d.delta.dx);
  }

  void _onEnd(DragEndDetails d) {
    if (_locked) {
      // Only fly-off reaches here (snap-back is interrupted in _onUpdate before
      // its end). Record the dropped gesture once, on release.
      if (!_snappingBack) widget.onInputIgnored?.call('locked');
      return;
    }
    _cancelIdleTimer(); // defensive: catch tap-release without prior _onUpdate
    final vx = d.velocity.pixelsPerSecond.dx;
    final shouldSwipe =
        _offset.abs() > _swipeThresholdPx || vx.abs() > _swipeThresholdVelocity;
    if (shouldSwipe) {
      _flyOff(_offset > 0 || (_offset.abs() < 10 && vx > 0));
    } else {
      _snapBack();
    }
  }

  // ─── Animations ──────────────────────────────────────────────────────────────

  Future<void> _flyOff(bool right) async {
    if (!mounted) return;
    _cancelIdleTimer(); // stop nudge if action-button triggered during nudge
    _locked = true;
    final screenW = MediaQuery.of(context).size.width;
    final target  = right ? screenW * 2.0 : -screenW * 2.0;

    _ctrl.duration = _flyOffDuration;
    final anim = Tween<double>(begin: _offset, end: target)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeIn));

    void listener() {
      if (mounted) setState(() => _offset = anim.value);
    }

    anim.addListener(listener);
    await _ctrl.forward(from: 0);
    anim.removeListener(listener);

    if (!mounted) return;
    _locked = false;
    if (right) {
      widget.onSwipeRight();
    } else {
      widget.onSwipeLeft();
    }
  }

  Future<void> _snapBack() async {
    _locked = true;
    _snappingBack = true;
    _ctrl.duration = _snapBackDuration;
    final anim = Tween<double>(begin: _offset, end: 0.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut));

    void listener() {
      // Stop driving _offset the moment a new drag interrupts us.
      if (mounted && _snappingBack) setState(() => _offset = anim.value);
    }

    anim.addListener(listener);
    await _ctrl.forward(from: 0);
    anim.removeListener(listener);

    // Interrupted by a fresh drag (_onUpdate cleared the flag and is now
    // driving _offset) — leave offset/lock untouched and bail.
    if (!_snappingBack) return;
    if (!mounted) return;
    setState(() {
      _offset = 0;
      _locked = false;
    });
    _snappingBack = false;
    _ctrl.reset();
    // User is still on this card after a failed swipe — restart the idle timer
    // so the nudge can still play if it hasn't yet.
    _startIdleTimer();
  }

  // ─── Programmatic swipe (action buttons) ─────────────────────────────────────

  void swipeLeft() {
    if (!_locked && !widget.isZoomed) {
      _cancelIdleTimer();
      _flyOff(false);
    }
  }

  void swipeRight() {
    if (!_locked && !widget.isZoomed) {
      _cancelIdleTimer();
      _flyOff(true);
    }
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final rotate  = (_offset / screenW * 0.28).clamp(-0.5, 0.5);
    // Stamp opacity is purely offset-driven — works for both manual drag and
    // the nudge animation (faint colour tint appears during the nudge as a
    // secondary signal, but motion is always the primary cue).
    final rightOp = (_offset / 180).clamp(0.0, 1.0);
    final leftOp  = (-_offset / 180).clamp(0.0, 1.0);

    final rightLabel = widget.leftHandedMode ? 'DELETE' : 'KEEP';
    final rightColor = widget.leftHandedMode
        ? const Color(0xFFFF453A)
        : const Color(0xFF30D158);

    final leftLabel = widget.leftHandedMode ? 'KEEP' : 'DELETE';
    final leftColor = widget.leftHandedMode
        ? const Color(0xFF30D158)
        : const Color(0xFFFF453A);

    // Setting callbacks to null when zoomed removes those recognizers from the
    // gesture arena, letting InteractiveViewer's pan recognizer win instead.
    return GestureDetector(
      onHorizontalDragUpdate: widget.isZoomed ? null : _onUpdate,
      onHorizontalDragEnd:   widget.isZoomed ? null : _onEnd,
      child: RepaintBoundary(
        child: Transform(
          transform: Matrix4.identity()
            ..translate(_offset)
            ..rotateZ(rotate),
          alignment: Alignment.bottomCenter,
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              // Stamp appears on the side the user is dragging FROM.
              // Also triggers at ~17 % opacity during the nudge, giving a
              // subtle colour hint that reinforces the motion direction.
              if (rightOp > 0.04)
                _StampOverlay(
                  label: rightLabel,
                  color: rightColor,
                  opacity: rightOp,
                  alignment: Alignment.topLeft,
                  angle: -0.25,
                ),
              if (leftOp > 0.04)
                _StampOverlay(
                  label: leftLabel,
                  color: leftColor,
                  opacity: leftOp,
                  alignment: Alignment.topRight,
                  angle: 0.25,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Stamp overlay (KEEP / DELETE label) ─────────────────────────────────────

class _StampOverlay extends StatelessWidget {
  final String label;
  final Color color;
  final double opacity;
  final AlignmentGeometry alignment;
  final double angle;

  const _StampOverlay({
    required this.label,
    required this.color,
    required this.opacity,
    required this.alignment,
    required this.angle,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          color: color.withOpacity(opacity * 0.15),
          child: Align(
            alignment: alignment,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Opacity(
                opacity: opacity.clamp(0.0, 1.0),
                child: Transform.rotate(
                  angle: angle,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      border: Border.all(color: color, width: 3.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        color: color,
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.5,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
