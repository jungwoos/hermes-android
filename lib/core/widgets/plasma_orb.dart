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
    final bounds = Offset.zero & size;
    final center = Offset(size.width / 2, size.height / 2);

    // The orb has no edge. Its silhouette comes entirely from a radial
    // falloff, so nothing is ever drawn as a circle and the mark dissolves
    // into whatever is behind it.
    //
    // Note on radii: `RadialGradient.radius` is a fraction of the paint box's
    // shortest side, so the default 0.5 reaches zero alpha exactly at the
    // inscribed circle. Painting the gradient across the whole box — rather
    // than into a circle — is what keeps a hard rim from reappearing.
    final falloff = size.shortestSide / 2;
    final core = falloff * 0.78;
    final tau = math.pi * 2;

    // 1. Saturation bloom, well inside the falloff so it only deepens colour.
    canvas.drawCircle(
      center,
      core * 0.78,
      Paint()
        ..color = hermesMagenta.withValues(alpha: 0.42 * intensity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, core * 0.5),
    );

    // 2. Body — a pure gradient, fading to fully transparent at the falloff.
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = RadialGradient(
          colors: [
            hermesPlasma.withValues(alpha: 1),
            hermesMagenta.withValues(alpha: 0.95),
            hermesMagenta.withValues(alpha: 0.62),
            hermesViolet.withValues(alpha: 0),
          ],
          // Colour holds almost to 0.5 so the orb still reads as a body; the
          // outer half is the falloff that removes the edge.
          stops: const [0, 0.34, 0.58, 1],
        ).createShader(bounds),
    );

    // 3. Filaments, drawn into their own layer and then faded out radially.
    // Clipping them to a circle instead would reintroduce the hard edge the
    // body gradient is there to avoid.
    canvas.saveLayer(bounds, Paint());
    for (var i = 0; i < 3; i++) {
      final phase = t * tau + i * tau / 3;
      // The vertical squash oscillates so the filaments appear to rotate in
      // three dimensions rather than spin flat.
      final squash = 0.18 + 0.30 * (0.5 + 0.5 * math.sin(phase * 1.7));

      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(phase);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: core * 1.86,
          height: core * 2 * squash,
        ),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = core * 0.055
          ..color = Colors.white.withValues(alpha: 0.55)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, core * 0.035),
      );
      canvas.restore();
    }
    canvas.drawRect(
      bounds,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = RadialGradient(
          colors: [
            Colors.white,
            Colors.white,
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0, 0.45, 0.88],
        ).createShader(bounds),
    );
    canvas.restore();

    // 4. Specular highlight.
    canvas.drawCircle(
      center.translate(-core * 0.3, -core * 0.36),
      core * 0.3,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.26)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, core * 0.28),
    );
  }

  @override
  bool shouldRepaint(_PlasmaOrbPainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.intensity != intensity;
}
