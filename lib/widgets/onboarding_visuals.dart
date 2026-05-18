import 'package:flutter/material.dart';

/// Three animated visuals for the onboarding slides. Each visual:
///
///   • accepts an [isActive] flag and only runs its loop while active
///     (so the inactive PageView neighbours don't burn battery), and
///   • accepts a [reduceMotion] flag that short-circuits to a quiet,
///     non-moving render when the user has Reduce Motion turned on.
///
/// All three are sized at 220×280 by default so the IntroScreen layout
/// stays consistent across slides.

const Size _kVisualSize = Size(220, 280);

// ─── Slide 1: photo-stack sweep ───────────────────────────────────────────────
//
// A small stack of 5 colour-graded cards. Cards lift off one at a time,
// alternating left / right with a slight rotation, as if being swept
// away. When the deck is empty the stack reassembles and the loop
// restarts. Total cycle ~4.8s.
class Slide1Visual extends StatefulWidget {
  final bool isActive;
  final bool reduceMotion;
  const Slide1Visual({
    super.key,
    required this.isActive,
    required this.reduceMotion,
  });

  @override
  State<Slide1Visual> createState() => _Slide1VisualState();
}

class _Slide1VisualState extends State<Slide1Visual>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cycle;

  // Five distinct illustrated photo "kinds" so the stack reads as a real
  // photo library, not as five copies of the same image.
  static const List<_PhotoKind> _kinds = [
    _PhotoKind.sunsetMountain,
    _PhotoKind.beach,
    _PhotoKind.portrait,
    _PhotoKind.cityNight,
    _PhotoKind.forest,
  ];

  static const int _cardCount = 5;
  static const Duration _cycleDuration = Duration(milliseconds: 4800);

  @override
  void initState() {
    super.initState();
    _cycle = AnimationController(vsync: this, duration: _cycleDuration);
    _syncRunning();
  }

  @override
  void didUpdateWidget(covariant Slide1Visual oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRunning();
  }

  @override
  void dispose() {
    _cycle.dispose();
    super.dispose();
  }

  void _syncRunning() {
    final shouldRun = widget.isActive && !widget.reduceMotion;
    if (shouldRun) {
      if (!_cycle.isAnimating) _cycle.repeat();
    } else {
      _cycle.stop();
      _cycle.value = 0;
    }
  }

  /// Per-card sweep window inside the cycle. Cards sweep one after the
  /// other in `_cardCount - 1` slots; the final slot is the reassemble.
  ({double start, double end}) _sweepWindow(int reverseIndex) {
    // Reverse so the TOP card (index = _cardCount - 1) goes first.
    final ordinal = _cardCount - 1 - reverseIndex;
    const window = 0.13; // each card's sweep length
    const stride = 0.14; // gap between successive sweeps
    final start = 0.05 + stride * ordinal;
    return (start: start, end: start + window);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _kVisualSize.width,
      height: _kVisualSize.height,
      child: AnimatedBuilder(
        animation: _cycle,
        builder: (_, __) {
          final t = widget.reduceMotion ? 0.0 : _cycle.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              for (int i = 0; i < _cardCount; i++)
                _buildCard(index: i, t: t),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCard({required int index, required double t}) {
    // Stack order: index 0 = bottom card. Top card sweeps first.
    final stackOffset = (_cardCount - 1 - index) * 6.0; // pixels
    final baseRotation =
        ((_cardCount - 1 - index) - (_cardCount - 1) / 2) * 0.04;

    final win = _sweepWindow(index);
    final reassembleStart = 0.85;
    final reassembleEnd = 0.98;

    double sweepProgress;
    if (t < win.start) {
      sweepProgress = 0;
    } else if (t < win.end) {
      sweepProgress = Curves.easeIn
          .transform(((t - win.start) / (win.end - win.start)).clamp(0.0, 1.0));
    } else {
      sweepProgress = 1.0;
    }

    // Reassemble: cards fade back from 0 → 1 right at the end of the cycle.
    double reassemble;
    if (t < reassembleStart) {
      reassemble = 0;
    } else {
      reassemble = Curves.easeOutCubic.transform(
          ((t - reassembleStart) / (reassembleEnd - reassembleStart))
              .clamp(0.0, 1.0));
    }

    // While the card is "gone" we set both opacity floors to 0.
    final goneState = sweepProgress >= 1.0 && reassemble < 1.0;

    // Alternate sweep direction by card index — keeps the visual lively.
    final goesRight = index.isEven;
    final dirSign = goesRight ? 1.0 : -1.0;

    final translateX = sweepProgress * 280.0 * dirSign;
    final translateY = -stackOffset + (reassemble == 0 ? 0 : 0);
    final rotation = baseRotation +
        sweepProgress * 0.45 * dirSign +
        (1 - reassemble) * (goneState ? 0 : 0);

    // Opacity = card-is-visible (not yet swept) OR reassembled.
    final opacity = goneState
        ? reassemble
        : (1.0 - 0.12 * sweepProgress); // gentle fade as it leaves

    return Transform.translate(
      offset: Offset(translateX, translateY),
      child: Transform.rotate(
        angle: rotation,
        child: Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: _PhotoCard(kind: _kinds[index % _kinds.length]),
        ),
      ),
    );
  }
}

/// Photo-shaped card that renders an illustrated scene. The illustrations
/// are deliberately recognisable at thumbnail size — sky-and-horizon
/// compositions, a portrait silhouette, a city skyline, etc. — so the
/// user reads the stack as "photos" without any text.
class _PhotoCard extends StatelessWidget {
  final _PhotoKind kind;
  const _PhotoCard({required this.kind});

  static const double _width = 138;
  static const double _height = 184;
  static const double _radius = 18;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _width,
      height: _height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.40),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(painter: _IllustratedPhotoPainter(kind)),
            // 1px inset glaze suggests glossy photo paper.
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_radius),
                border: Border.all(
                  color: Colors.white.withOpacity(0.06),
                  width: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Each "photograph" the user sees in the onboarding stacks. Keep these
/// kinds visually distinct so the deck reads as a varied library.
enum _PhotoKind {
  sunsetMountain,
  beach,
  portrait,
  cityNight,
  forest,
  coffee,
}

/// Hand-painted scene per kind. None of these claim to be photo-realistic
/// — they're stylised, immediately readable as "the kind of photo you'd
/// have on your phone": a sunset, a beach, a headshot, a skyline.
class _IllustratedPhotoPainter extends CustomPainter {
  final _PhotoKind kind;
  _IllustratedPhotoPainter(this.kind);

  @override
  void paint(Canvas canvas, Size size) {
    switch (kind) {
      case _PhotoKind.sunsetMountain:
        _paintSunsetMountain(canvas, size);
      case _PhotoKind.beach:
        _paintBeach(canvas, size);
      case _PhotoKind.portrait:
        _paintPortrait(canvas, size);
      case _PhotoKind.cityNight:
        _paintCityNight(canvas, size);
      case _PhotoKind.forest:
        _paintForest(canvas, size);
      case _PhotoKind.coffee:
        _paintCoffee(canvas, size);
    }
  }

  @override
  bool shouldRepaint(covariant _IllustratedPhotoPainter oldDelegate) =>
      oldDelegate.kind != kind;

  // ─── Scenes ──────────────────────────────────────────────────────────────

  void _paintSunsetMountain(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;

    // Sky: warm peach → coral.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFC288), Color(0xFFFF7E66)],
        ).createShader(rect),
    );

    // Sun.
    canvas.drawCircle(
      Offset(w * 0.66, h * 0.36),
      w * 0.11,
      Paint()..color = const Color(0xFFFFE9A8),
    );

    // Distant mountain range (lighter, behind).
    final back = Path()
      ..moveTo(0, h * 0.72)
      ..lineTo(w * 0.22, h * 0.55)
      ..lineTo(w * 0.40, h * 0.66)
      ..lineTo(w * 0.62, h * 0.50)
      ..lineTo(w * 0.82, h * 0.62)
      ..lineTo(w, h * 0.58)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(
      back,
      Paint()..color = const Color(0xFF5A4566),
    );

    // Foreground mountains (darker, sharper).
    final front = Path()
      ..moveTo(0, h * 0.85)
      ..lineTo(w * 0.18, h * 0.70)
      ..lineTo(w * 0.36, h * 0.82)
      ..lineTo(w * 0.55, h * 0.68)
      ..lineTo(w * 0.78, h * 0.80)
      ..lineTo(w, h * 0.74)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(
      front,
      Paint()..color = const Color(0xFF2C2538),
    );
  }

  void _paintBeach(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;

    // Sky.
    canvas.drawRect(
      Rect.fromLTRB(0, 0, w, h * 0.62),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [Color(0xFFFFD79E), Color(0xFFFFB088)],
        ).createShader(rect),
    );
    // Sun on horizon (half visible).
    canvas.drawCircle(
      Offset(w * 0.50, h * 0.60),
      w * 0.16,
      Paint()..color = const Color(0xFFFFF1B8),
    );
    // Water.
    canvas.drawRect(
      Rect.fromLTRB(0, h * 0.62, w, h),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF5293C9), Color(0xFF2A4F84)],
        ).createShader(Rect.fromLTRB(0, h * 0.62, w, h)),
    );
    // Reflective highlights.
    final shimmer = Paint()
      ..color = Colors.white.withOpacity(0.30)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (final f in const [0.66, 0.72, 0.78, 0.84, 0.90]) {
      canvas.drawLine(
        Offset(w * 0.38, h * f),
        Offset(w * 0.62, h * f),
        shimmer,
      );
    }
  }

  void _paintPortrait(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;

    // Warm studio background.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0, -0.2),
          radius: 1.1,
          colors: [Color(0xFFE6B392), Color(0xFF6E4838)],
        ).createShader(rect),
    );

    // Soft backlight halo behind the head.
    canvas.drawCircle(
      Offset(w * 0.50, h * 0.45),
      w * 0.34,
      Paint()..color = const Color(0xFFFFD7AA).withOpacity(0.35),
    );

    // Shoulders (rounded rectangle).
    final shoulders = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.08, h * 0.70, w * 0.84, h * 0.30),
      Radius.circular(w * 0.30),
    );
    canvas.drawRRect(
      shoulders,
      Paint()..color = const Color(0xFF1E1620),
    );
    // Neck.
    canvas.drawRect(
      Rect.fromLTRB(w * 0.40, h * 0.55, w * 0.60, h * 0.74),
      Paint()..color = const Color(0xFF1E1620),
    );
    // Head.
    canvas.drawCircle(
      Offset(w * 0.50, h * 0.46),
      w * 0.20,
      Paint()..color = const Color(0xFF1E1620),
    );
  }

  void _paintCityNight(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;

    // Night sky.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF14172B), Color(0xFF2A3354)],
        ).createShader(rect),
    );
    // Moon.
    canvas.drawCircle(
      Offset(w * 0.78, h * 0.20),
      w * 0.07,
      Paint()..color = const Color(0xFFE8E1C7),
    );

    // Building blocks (back row — lighter / further).
    final backPaint = Paint()..color = const Color(0xFF1B2336);
    final blocksBack = [
      Rect.fromLTWH(w * 0.05, h * 0.50, w * 0.16, h * 0.50),
      Rect.fromLTWH(w * 0.22, h * 0.42, w * 0.14, h * 0.58),
      Rect.fromLTWH(w * 0.62, h * 0.45, w * 0.18, h * 0.55),
      Rect.fromLTWH(w * 0.82, h * 0.52, w * 0.14, h * 0.48),
    ];
    for (final r in blocksBack) {
      canvas.drawRect(r, backPaint);
    }
    // Building blocks (front — darker / nearer, taller).
    final frontPaint = Paint()..color = const Color(0xFF0A0F1C);
    final blocksFront = [
      Rect.fromLTWH(w * 0.36, h * 0.38, w * 0.14, h * 0.62),
      Rect.fromLTWH(w * 0.50, h * 0.32, w * 0.14, h * 0.68),
    ];
    for (final r in blocksFront) {
      canvas.drawRect(r, frontPaint);
    }
    // Window lights — tiny warm squares scattered across the silhouettes.
    final windowPaint = Paint()..color = const Color(0xFFF6CB6E);
    for (final blocks in [blocksBack, blocksFront]) {
      for (final b in blocks) {
        for (double y = b.top + 6; y < b.bottom - 4; y += 9) {
          for (double x = b.left + 4; x < b.right - 3; x += 7) {
            // Sparse: skip ~60 % of cells.
            if (((x.toInt() + y.toInt()) % 5) >= 2) continue;
            canvas.drawRect(
              Rect.fromLTWH(x, y, 2.4, 2.4),
              windowPaint,
            );
          }
        }
      }
    }
  }

  void _paintForest(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;

    // Sky → forest floor gradient.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF94C7B6), Color(0xFF1E2A1B)],
        ).createShader(rect),
    );

    // Distant trees (lighter).
    final back = Paint()..color = const Color(0xFF3B5444);
    _drawTree(canvas, Offset(w * 0.12, h * 0.62), w * 0.20, back);
    _drawTree(canvas, Offset(w * 0.34, h * 0.58), w * 0.22, back);
    _drawTree(canvas, Offset(w * 0.60, h * 0.60), w * 0.21, back);
    _drawTree(canvas, Offset(w * 0.82, h * 0.62), w * 0.20, back);

    // Near trees (darker, taller).
    final front = Paint()..color = const Color(0xFF111A12);
    _drawTree(canvas, Offset(w * 0.22, h * 0.80), w * 0.30, front);
    _drawTree(canvas, Offset(w * 0.52, h * 0.85), w * 0.32, front);
    _drawTree(canvas, Offset(w * 0.80, h * 0.82), w * 0.30, front);

    // Forest floor.
    canvas.drawRect(
      Rect.fromLTRB(0, h * 0.94, w, h),
      Paint()..color = const Color(0xFF0E1410),
    );
  }

  void _drawTree(Canvas canvas, Offset base, double height, Paint paint) {
    // Stylised fir: two stacked triangles tapering toward the tip.
    final p = Path();
    final halfWidth = height * 0.30;
    p.moveTo(base.dx, base.dy - height);
    p.lineTo(base.dx - halfWidth, base.dy - height * 0.35);
    p.lineTo(base.dx - halfWidth * 0.55, base.dy - height * 0.35);
    p.lineTo(base.dx - halfWidth * 0.85, base.dy);
    p.lineTo(base.dx + halfWidth * 0.85, base.dy);
    p.lineTo(base.dx + halfWidth * 0.55, base.dy - height * 0.35);
    p.lineTo(base.dx + halfWidth, base.dy - height * 0.35);
    p.close();
    canvas.drawPath(p, paint);
  }

  void _paintCoffee(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;

    // Warm wood-table background.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment.center,
          radius: 1.0,
          colors: [Color(0xFF7A5236), Color(0xFF2C1B11)],
        ).createShader(rect),
    );

    // Saucer (slightly oversized circle).
    final centre = Offset(w * 0.50, h * 0.55);
    canvas.drawCircle(
      centre,
      w * 0.40,
      Paint()..color = const Color(0xFF1E140C),
    );
    canvas.drawCircle(
      centre,
      w * 0.38,
      Paint()..color = const Color(0xFFE9DCC6),
    );

    // Cup (smaller centred circle on saucer).
    canvas.drawCircle(
      centre,
      w * 0.28,
      Paint()..color = const Color(0xFF1E140C),
    );
    canvas.drawCircle(
      centre,
      w * 0.26,
      Paint()..color = const Color(0xFFF5ECDB),
    );

    // Coffee surface.
    canvas.drawCircle(
      centre,
      w * 0.22,
      Paint()..color = const Color(0xFF3A1F11),
    );
    // Latte-art ring highlight.
    canvas.drawCircle(
      centre,
      w * 0.18,
      Paint()
        ..color = const Color(0xFFD7B58E)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }
}

// ─── Slide 2: live swipe demo ─────────────────────────────────────────────────
//
// HIGH-PRIORITY slide. Top card swipes off (alternating right=Keep,
// left=Delete) with an inline label, the middle card eases into the
// front spot, the back card eases up, and a fresh card materialises at
// the back so the deck never empties. ~3s per swipe.
class Slide2Visual extends StatefulWidget {
  final bool isActive;
  final bool reduceMotion;
  const Slide2Visual({
    super.key,
    required this.isActive,
    required this.reduceMotion,
  });

  @override
  State<Slide2Visual> createState() => _Slide2VisualState();
}

class _Slide2VisualState extends State<Slide2Visual>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cycle;
  int _topIndex = 0;

  // Six illustrated photo kinds — the deck cycles through them so the
  // user sees variety ("works for any photo") across each swipe.
  static const List<_PhotoKind> _kinds = [
    _PhotoKind.sunsetMountain,
    _PhotoKind.beach,
    _PhotoKind.portrait,
    _PhotoKind.cityNight,
    _PhotoKind.forest,
    _PhotoKind.coffee,
  ];

  static const Duration _cycleDuration = Duration(milliseconds: 3000);

  @override
  void initState() {
    super.initState();
    _cycle = AnimationController(vsync: this, duration: _cycleDuration);
    _cycle.addStatusListener(_onStatus);
    _syncRunning();
  }

  @override
  void didUpdateWidget(covariant Slide2Visual oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRunning();
  }

  @override
  void dispose() {
    _cycle.removeStatusListener(_onStatus);
    _cycle.dispose();
    super.dispose();
  }

  void _syncRunning() {
    final shouldRun = widget.isActive && !widget.reduceMotion;
    if (shouldRun) {
      if (!_cycle.isAnimating) _cycle.forward(from: 0);
    } else {
      _cycle.stop();
      _cycle.value = 0;
    }
  }

  void _onStatus(AnimationStatus status) {
    // Hand-rolled repeat so we can bump _topIndex at cycle boundary
    // (status events only fire from forward(), not repeat()).
    if (status == AnimationStatus.completed) {
      if (!mounted || !widget.isActive || widget.reduceMotion) return;
      setState(() => _topIndex++);
      _cycle.forward(from: 0);
    }
  }

  bool _isKeep(int index) => index.isEven;

  _PhotoKind _kindFor(int virtualIndex) =>
      _kinds[virtualIndex.abs() % _kinds.length];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _kVisualSize.width,
      height: _kVisualSize.height,
      child: AnimatedBuilder(
        animation: _cycle,
        builder: (_, __) {
          final t = widget.reduceMotion ? 0.0 : _cycle.value;
          return Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              const Positioned(
                left: -4,
                child: _DirectionalHint(
                    icon: Icons.favorite_rounded,
                    color: Color(0xFF30D158)),
              ),
              const Positioned(
                right: -4,
                child: _DirectionalHint(
                    icon: Icons.close_rounded,
                    color: Color(0xFFFF453A)),
              ),
              _buildCard(deckPosition: 2, t: t),
              _buildCard(deckPosition: 1, t: t),
              _buildCard(deckPosition: 0, t: t),
              _buildDecisionLabel(t: t),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCard({required int deckPosition, required double t}) {
    final virtualIndex = _topIndex + deckPosition;
    final kind = _kindFor(virtualIndex);

    // Slot animation: as the top card swipes off, the middle eases into
    // the centre and the back eases up to the middle slot.
    final slotProgress =
        Curves.easeOutCubic.transform(((t - 0.10) / 0.55).clamp(0.0, 1.0));

    double translateX = 0;
    double translateY = 0;
    double rotation = 0;
    double scale = 1.0;
    double opacity = 1.0;

    if (deckPosition == 0) {
      // Top card: idle, then swipe off in the alternating direction.
      final sweepRaw = ((t - 0.10) / 0.55).clamp(0.0, 1.0);
      final eased = Curves.easeIn.transform(sweepRaw);
      final dirSign = _isKeep(_topIndex) ? 1.0 : -1.0;
      translateX = eased * 300 * dirSign;
      rotation = eased * 0.30 * dirSign;
      // Fade out toward the end of the sweep so the swap is calm.
      opacity = 1.0 - ((sweepRaw - 0.65).clamp(0.0, 0.35) / 0.35) * 0.7;
    } else if (deckPosition == 1) {
      // Middle: from -8 / 0.95 to 0 / 1.0 as the top card leaves.
      translateY = -8 + slotProgress * 8;
      scale = 0.95 + slotProgress * 0.05;
    } else {
      // Back: from -16 / 0.90 to -8 / 0.95. Fades in over first 20% of
      // cycle so a fresh card never pops.
      translateY = -16 + slotProgress * 8;
      scale = 0.90 + slotProgress * 0.05;
      opacity = (t / 0.20).clamp(0.0, 1.0);
    }

    return Transform.translate(
      offset: Offset(translateX, translateY),
      child: Transform.rotate(
        angle: rotation,
        child: Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: _PhotoCard(kind: kind),
          ),
        ),
      ),
    );
  }

  // Keep / Delete pill that rides along with the swipe direction.
  Widget _buildDecisionLabel({required double t}) {
    // Visible window: 0.18 → 0.55 with fade in 0.18→0.28 and out 0.45→0.55.
    if (t < 0.18 || t > 0.58) return const SizedBox.shrink();
    double opacity;
    if (t < 0.28) {
      opacity = (t - 0.18) / 0.10;
    } else if (t < 0.45) {
      opacity = 1.0;
    } else {
      opacity = 1.0 - (t - 0.45) / 0.13;
    }
    opacity = opacity.clamp(0.0, 1.0);
    if (opacity <= 0) return const SizedBox.shrink();

    final isKeep = _isKeep(_topIndex);
    final dirSign = isKeep ? 1.0 : -1.0;
    final eased = Curves.easeIn.transform(((t - 0.10) / 0.55).clamp(0.0, 1.0));
    final translateX = eased * 220 * dirSign - 30 * dirSign;
    final translateY = -90.0 + eased * 12;
    final rotation = (isKeep ? -0.22 : 0.22);

    final color = isKeep ? const Color(0xFF30D158) : const Color(0xFFFF453A);

    return Transform.translate(
      offset: Offset(translateX, translateY),
      child: Transform.rotate(
        angle: rotation,
        child: Opacity(
          opacity: opacity,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.65),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color, width: 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(isKeep ? Icons.favorite_rounded : Icons.close_rounded,
                    color: color, size: 16),
                const SizedBox(width: 6),
                Text(
                  isKeep ? 'KEEP' : 'DELETE',
                  style: TextStyle(
                    color: color,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DirectionalHint extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _DirectionalHint({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.35,
      child: Icon(icon, color: color, size: 22),
    );
  }
}

// ─── Slide 3: phone with pulsing shield + badge shimmer ───────────────────────
//
// Stylised iPhone outline with a 2×2 grid of photo thumbnails inside.
// A concentric "shield" pulses outward from behind the device every 2s
// (three rings on phase offsets so something is always pulsing). The
// "100% on-device" pill below has a slow light-sweep shimmer.
class Slide3Visual extends StatefulWidget {
  final bool isActive;
  final bool reduceMotion;
  const Slide3Visual({
    super.key,
    required this.isActive,
    required this.reduceMotion,
  });

  @override
  State<Slide3Visual> createState() => _Slide3VisualState();
}

class _Slide3VisualState extends State<Slide3Visual>
    with TickerProviderStateMixin {
  late final AnimationController _pulse;
  late final AnimationController _shimmer;
  late final AnimationController _breath;

  static const Color _privacy = Color(0xFF0A84FF);

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4500),
    );
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    _syncRunning();
  }

  @override
  void didUpdateWidget(covariant Slide3Visual oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRunning();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _shimmer.dispose();
    _breath.dispose();
    super.dispose();
  }

  void _syncRunning() {
    final shouldRun = widget.isActive && !widget.reduceMotion;
    if (shouldRun) {
      if (!_pulse.isAnimating) _pulse.repeat();
      if (!_shimmer.isAnimating) _shimmer.repeat();
      if (!_breath.isAnimating) {
        _breath.repeat(reverse: true);
      }
    } else {
      _pulse.stop();
      _shimmer.stop();
      _breath.stop();
      _pulse.value = 0;
      _shimmer.value = 0;
      _breath.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _kVisualSize.width,
      height: _kVisualSize.height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, __) {
              return CustomPaint(
                size: const Size(220, 280),
                painter: _ShieldPulsePainter(
                  progress: widget.reduceMotion ? 0 : _pulse.value,
                  color: _privacy,
                ),
              );
            },
          ),
          AnimatedBuilder(
            animation: _breath,
            builder: (_, child) {
              final scale = widget.reduceMotion
                  ? 1.0
                  : 1.0 + (Curves.easeInOut.transform(_breath.value)) * 0.035;
              return Transform.scale(scale: scale, child: child);
            },
            child: const _PhoneWithPhotos(),
          ),
          Positioned(
            bottom: 6,
            child: AnimatedBuilder(
              animation: _shimmer,
              builder: (_, __) => _OnDeviceBadge(
                shimmerProgress:
                    widget.reduceMotion ? null : _shimmer.value,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShieldPulsePainter extends CustomPainter {
  final double progress; // 0 → 1, looping
  final Color color;
  _ShieldPulsePainter({required this.progress, required this.color});

  static const double _minRadius = 78;
  static const double _maxRadius = 130;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2 - 18);

    // Three rings phase-offset so there's always something pulsing.
    for (int i = 0; i < 3; i++) {
      final ringProgress = (progress + i / 3.0) % 1.0;
      // Ease out for organic feel.
      final eased = Curves.easeOut.transform(ringProgress);
      final radius = _minRadius + (_maxRadius - _minRadius) * eased;
      final opacity = (1.0 - ringProgress).clamp(0.0, 1.0) * 0.55;
      final paint = Paint()
        ..color = color.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      canvas.drawCircle(centre, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ShieldPulsePainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _PhoneWithPhotos extends StatelessWidget {
  const _PhoneWithPhotos();

  static const Color _frame = Color(0xFF2C2C2E);
  static const Color _screen = Color(0xFF0F0F12);
  static const Color _privacy = Color(0xFF0A84FF);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 116,
      height: 200,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _frame,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          color: _screen,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Stack(
          children: [
            // Notch.
            Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.only(top: 6),
                width: 38,
                height: 8,
                decoration: BoxDecoration(
                  color: _frame,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            // 2×2 thumbnail grid + a central lock.
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 22, 8, 8),
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      children: const [
                        Expanded(child: _Thumb(color: Color(0xFF5B4DD1))),
                        SizedBox(width: 6),
                        Expanded(child: _Thumb(color: Color(0xFF30D158))),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Row(
                      children: const [
                        Expanded(child: _Thumb(color: Color(0xFFFFD60A))),
                        SizedBox(width: 6),
                        Expanded(child: _Thumb(color: Color(0xFFFF453A))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Centered lock chip.
            Align(
              alignment: Alignment.center,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: _privacy.withOpacity(0.6), width: 1.2),
                ),
                child: const Icon(Icons.lock_rounded,
                    color: _privacy, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  final Color color;
  const _Thumb({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withOpacity(0.7), color.withOpacity(0.35)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }
}

/// "100% on-device" pill with a slow light-sweep shimmer. When
/// [shimmerProgress] is null we render the static badge (reduce-motion
/// case).
class _OnDeviceBadge extends StatelessWidget {
  final double? shimmerProgress;
  const _OnDeviceBadge({required this.shimmerProgress});

  static const Color _privacy = Color(0xFF0A84FF);

  @override
  Widget build(BuildContext context) {
    final base = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _privacy.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _privacy.withOpacity(0.35), width: 1),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shield_rounded, color: _privacy, size: 13),
          SizedBox(width: 6),
          Text(
            '100% on-device',
            style: TextStyle(
              color: _privacy,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
    if (shimmerProgress == null) return base;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Stack(
        children: [
          base,
          IgnorePointer(
            child: Align(
              alignment: Alignment(-1 + shimmerProgress! * 2.5, 0),
              child: SizedBox(
                width: 70,
                height: 28,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Colors.white.withOpacity(0),
                        Colors.white.withOpacity(0.18),
                        Colors.white.withOpacity(0),
                      ],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

