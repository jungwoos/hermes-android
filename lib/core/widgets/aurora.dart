// The ambient backdrop every screen sits on: a near-black canvas with a
// magenta bloom pouring down from the top and a violet counter-glow in the
// lower corner. Painted with layered gradients (no blur passes) so it costs
// almost nothing to keep behind scrolling content.
import 'package:flutter/material.dart';

import '../theme.dart';

class AuroraBackground extends StatelessWidget {
  const AuroraBackground({
    this.bloomAlignment = const Alignment(0, -1.05),
    this.intensity = 1,
    super.key,
  });

  /// Where the primary bloom is centred. The default sits just above the top
  /// edge so only its lower half is visible, as in the reference design.
  final Alignment bloomAlignment;

  /// Multiplier on both blooms' opacity. Detail panes and dense list screens
  /// use a lower value so the content stays readable.
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Light mode keeps the same composition at a fraction of the strength —
    // a tinted paper rather than a glowing panel.
    final primaryAlpha = (isDark ? 0.55 : 0.22) * intensity;
    final midAlpha = (isDark ? 0.18 : 0.10) * intensity;
    final counterAlpha = (isDark ? 0.20 : 0.10) * intensity;

    return DecoratedBox(
      decoration: BoxDecoration(color: isDark ? hermesInk : hermesMist),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: bloomAlignment,
            radius: 1.05,
            colors: [
              hermesMagenta.withValues(alpha: primaryAlpha),
              hermesViolet.withValues(alpha: midAlpha),
              Colors.transparent,
            ],
            stops: const [0, 0.45, 1],
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.9, 1.1),
              radius: 0.9,
              colors: [
                hermesViolet.withValues(alpha: counterAlpha),
                Colors.transparent,
              ],
            ),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// A [Scaffold] painted over an [AuroraBackground].
///
/// The Scaffold itself is transparent, so the aurora shows through the app
/// bar and the area behind the FAB without any `extendBodyBehindAppBar`
/// gymnastics — the glow reads as one continuous field, as in the design.
class AuroraScaffold extends StatelessWidget {
  const AuroraScaffold({
    required this.body,
    this.appBar,
    this.drawer,
    this.floatingActionButton,
    this.bloomAlignment = const Alignment(0, -1.05),
    this.intensity = 1,
    super.key,
  });

  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? drawer;
  final Widget? floatingActionButton;
  final Alignment bloomAlignment;
  final double intensity;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: AuroraBackground(
              bloomAlignment: bloomAlignment,
              intensity: intensity,
            ),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: appBar,
          drawer: drawer,
          floatingActionButton: floatingActionButton,
          body: body,
        ),
      ],
    );
  }
}
