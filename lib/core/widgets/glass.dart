// Glass building blocks: translucent panels with hairline strokes, circular
// icon buttons, and gradient pills. These replace Material's stock Card /
// IconButton / FilledButton wherever the design calls for the frosted look.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A translucent surface with a hairline stroke and large corner radius.
///
/// [blur] is opt-in: `BackdropFilter` is a full-screen-ish GPU pass, so list
/// items leave it off and only chrome that floats over content (composer,
/// side panel) turns it on.
class GlassCard extends StatelessWidget {
  const GlassCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.radius = HermesRadius.card,
    this.onTap,
    this.onLongPress,
    this.active = false,
    this.blur = false,
    this.glow = false,
    this.tint,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Selected / running state — brightens the fill and the stroke.
  final bool active;
  final bool blur;

  /// Adds an accent bloom behind the card.
  final bool glow;

  /// Fills the surface with a gradient in this colour instead of the neutral
  /// glass. The bot roster passes each bot's own accent, so a row is
  /// identifiable by colour without spending width on a marker.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final borderRadius = BorderRadius.circular(radius);

    final tint = this.tint;
    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: tint != null
            ? null
            : active
            ? HermesGlass.activeFill(brightness)
            : HermesGlass.fill(brightness),
        // Left-to-right fade, so a row of tinted cards reads as one list
        // rather than a stack of solid blocks.
        gradient: tint == null
            ? null
            : LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  tint.withValues(alpha: active ? 0.42 : 0.26),
                  tint.withValues(alpha: active ? 0.16 : 0.05),
                ],
              ),
        borderRadius: borderRadius,
        border: Border.all(
          color: tint != null
              ? tint.withValues(alpha: active ? 0.80 : 0.45)
              : active
              ? HermesGlass.activeStroke(brightness)
              : HermesGlass.stroke(brightness),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: borderRadius,
          splashColor: hermesMagenta.withValues(alpha: 0.10),
          highlightColor: hermesMagenta.withValues(alpha: 0.06),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );

    if (blur) {
      surface = ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: surface,
        ),
      );
    }

    if (glow) {
      surface = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: hermesGlow(hermesMagenta, alpha: 0.16, blur: 28),
        ),
        child: surface,
      );
    }

    return Padding(padding: margin, child: surface);
  }
}

/// Circular glass icon button — the back / history / speaker controls in the
/// reference design.
class NeonIconButton extends StatelessWidget {
  const NeonIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 44,
    this.active = false,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  /// Highlighted state (e.g. mic while listening).
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final enabled = onPressed != null;

    final button = Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active
              ? HermesGlass.activeFill(brightness)
              : HermesGlass.fill(brightness),
          border: Border.all(
            color: active
                ? HermesGlass.activeStroke(brightness)
                : HermesGlass.stroke(brightness),
          ),
          boxShadow: active
              ? hermesGlow(hermesMagenta, alpha: 0.35, blur: 16)
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: Icon(
              icon,
              size: size * 0.44,
              color: active ? theme.colorScheme.primary : null,
            ),
          ),
        ),
      ),
    );

    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// Solid gradient pill with a bloom behind it — the primary call to action.
class GradientPillButton extends StatelessWidget {
  const GradientPillButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// Stretch to the available width (used inside the side panel).
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(HermesRadius.pill),
          gradient: hermesAccentGradient,
          boxShadow: enabled
              ? hermesGlow(hermesMagenta, alpha: 0.38, blur: 22)
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(HermesRadius.pill),
            child: Padding(
              // Stretched inside a narrow column there is no room for the
              // wider inset, and the label has to be allowed to shrink.
              padding: EdgeInsets.symmetric(
                horizontal: expand ? 14 : 22,
                vertical: 14,
              ),
              child: Row(
                mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18, color: Colors.white),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Circular gradient action button with a halo — the send / mic control.
class GradientOrbButton extends StatelessWidget {
  const GradientOrbButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 48,
    this.halo = false,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  /// Draws the concentric rings from the reference's "listening" state.
  final bool halo;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;

    Widget core = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: hermesAccentGradient,
        boxShadow: enabled
            ? hermesGlow(hermesMagenta, alpha: 0.5, blur: 20)
            : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Icon(icon, size: size * 0.42, color: Colors.white),
        ),
      ),
    );

    if (halo) {
      core = Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: hermesMagenta.withValues(alpha: 0.16),
          border: Border.all(color: hermesMagenta.withValues(alpha: 0.30)),
        ),
        child: core,
      );
    }

    final button = Opacity(opacity: enabled ? 1 : 0.45, child: core);
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// Small stadium-shaped label — the "NeoAI 1.0 / Beta" chip in the reference.
/// Used for the connection name and status badges.
class BrandPill extends StatelessWidget {
  const BrandPill({
    required this.label,
    this.trailingLabel,
    this.icon,
    this.onTap,
    super.key,
  });

  final String label;

  /// Rendered as a nested, brighter capsule at the right (the "Beta" tag).
  final String? trailingLabel;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HermesRadius.pill),
        child: Container(
          padding: EdgeInsets.fromLTRB(icon != null ? 10 : 14, 6, 6, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(HermesRadius.pill),
            color: HermesGlass.fill(brightness),
            border: Border.all(color: HermesGlass.stroke(brightness)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (trailingLabel != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(HermesRadius.pill),
                    gradient: hermesAccentGradient,
                  ),
                  child: Text(
                    trailingLabel!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ] else
                const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// A deliberately low-contrast icon button for secondary app-bar actions such
/// as refresh: reachable, but recessed enough that it never competes with the
/// title or the accent chrome.
class FaintIconButton extends StatelessWidget {
  const FaintIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.onSurfaceVariant;
    return IconButton(
      icon: Icon(icon, size: 20),
      color: base.withValues(alpha: 0.28),
      disabledColor: base.withValues(alpha: 0.12),
      onPressed: onPressed,
      tooltip: tooltip,
    );
  }
}

/// Section label for settings-style lists: small, uppercase, accent-tinted.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 1.6,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
