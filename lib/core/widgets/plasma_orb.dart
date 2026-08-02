// The hero mark: a glowing plasma sphere with filaments drifting across it.
// Used as the empty-state centrepiece on the home, chat and session screens.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

class PlasmaOrb extends StatefulWidget {
  const PlasmaOrb({this.size = 160, this.intensity = 1, super.key});

  final double size;

  /// Scales the outer glow. Dense screens use a lower value so the orb does
  /// not wash out nearby text.
  final double intensity;

  @override
  State<PlasmaOrb> createState() => _PlasmaOrbState();
}

class _PlasmaOrbState extends State<PlasmaOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Honour the platform's "reduce motion" setting: the orb still renders,
    // it just holds a single frame instead of drifting forever.
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) {
      if (_controller.isAnimating) _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            size: Size.square(widget.size),
            painter: _PlasmaOrbPainter(
              t: _controller.value,
              intensity: widget.intensity,
            ),
          );
        },
      ),
    );
  }
}

class _PlasmaOrbPainter extends CustomPainter {
  _PlasmaOrbPainter({required this.t, required this.intensity});

  /// Animation phase in [0, 1).
  final double t;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide / 2 * 0.78;
    final tau = math.pi * 2;

    // 1. Outer bloom.
    canvas.drawCircle(
      center,
      r * 1.02,
      Paint()
        ..color = hermesMagenta.withValues(alpha: 0.38 * intensity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.42),
    );

    // 2. Sphere body — lit from the upper left.
    final bodyRect = Rect.fromCircle(center: center, radius: r);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.4),
          radius: 1.05,
          colors: [
            hermesPlasma.withValues(alpha: 0.85),
            hermesMagenta.withValues(alpha: 0.72),
            hermesViolet.withValues(alpha: 0.85),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(bodyRect),
    );

    // 3. Filaments: flattened ellipses sweeping around the sphere. Clipped to
    // the body so they read as internal structure, not orbiting rings.
    canvas.save();
    canvas.clipPath(Path()..addOval(bodyRect));
    for (var i = 0; i < 3; i++) {
      final phase = t * tau + i * tau / 3;
      // The vertical squash oscillates so the filaments appear to rotate in
      // three dimensions rather than spin flat.
      final squash = 0.18 + 0.30 * (0.5 + 0.5 * math.sin(phase * 1.7));

      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(phase);
      final oval = Rect.fromCenter(
        center: Offset.zero,
        width: r * 1.86,
        height: r * 2 * squash,
      );
      canvas.drawOval(
        oval,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.055
          ..color = Colors.white.withValues(alpha: 0.55)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.035),
      );
      canvas.restore();
    }
    canvas.restore();

    // 4. Specular highlight.
    canvas.drawCircle(
      center.translate(-r * 0.3, -r * 0.36),
      r * 0.3,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.28)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.28),
    );

    // 5. Rim light. Blurred and pulled just inside the body so it reads as a
    // soft edge glow; drawn crisply on the exact radius it looks like a
    // hairline outline around the sphere.
    canvas.drawCircle(
      center,
      r * 0.97,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.06
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.05)
        ..shader = SweepGradient(
          transform: GradientRotation(t * tau),
          colors: [
            Colors.white.withValues(alpha: 0.30),
            hermesPlasma.withValues(alpha: 0.16),
            Colors.white.withValues(alpha: 0.34),
            hermesPlasma.withValues(alpha: 0.16),
            Colors.white.withValues(alpha: 0.30),
          ],
        ).createShader(bodyRect),
    );
  }

  @override
  bool shouldRepaint(_PlasmaOrbPainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.intensity != intensity;
}
