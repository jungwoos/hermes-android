// Design tokens for the Hermes "plasma" look: neon magenta/violet accents
// bloomed over near-black ink, translucent glass surfaces, and the brand
// wordmark. Everything colour- or shape-related lives here so a restyle is a
// single-file change rather than a sweep through every screen.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

/// Primary neon accent — the magenta bloom that dominates the design.
const Color hermesMagenta = Color(0xFFE05CFF);

/// Secondary accent; the far end of most brand gradients.
const Color hermesViolet = Color(0xFF9B4DFF);

/// Bright rim highlight — orb edges, focused borders, pressed states.
const Color hermesPlasma = Color(0xFFF7B8FF);

/// Cool counterpoint, used for two-tone gradients and "healthy" status.
const Color hermesCyan = Color(0xFF4DE8F5);

/// Deepest dark-mode background.
const Color hermesInk = Color(0xFF08070C);

/// Raised dark surface (cards, sheets, dialogs).
const Color hermesInkRaised = Color(0xFF15111C);

/// Light-mode canvas — a faint violet tint rather than flat white.
const Color hermesMist = Color(0xFFF6F2FB);

/// Muted body text on dark surfaces.
const Color hermesMuted = Color(0xFF9C93AC);

/// Error accent — a hot coral that stays in the neon family instead of
/// dropping a stock Material red into the design.
const Color hermesAlert = Color(0xFFFF5C8A);

// ---------------------------------------------------------------------------
// Gradients
// ---------------------------------------------------------------------------

/// The brand gradient: magenta into violet, top-left to bottom-right.
const LinearGradient hermesAccentGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [hermesMagenta, hermesViolet],
);

// ---------------------------------------------------------------------------
// Shape + elevation tokens
// ---------------------------------------------------------------------------

/// Corner radii. The design leans on large, soft corners; anything smaller
/// than [chip] reads as a different design language.
abstract final class HermesRadius {
  static const double chip = 12;
  static const double tile = 18;
  static const double card = 22;
  static const double sheet = 28;

  /// Effectively a stadium border for pills and circular buttons.
  static const double pill = 999;
}

/// Translucent surface colours. Glass is a fill + hairline stroke; the blur
/// itself is opt-in per widget because `BackdropFilter` is expensive inside
/// long lists.
abstract final class HermesGlass {
  static Color fill(Brightness brightness) => brightness == Brightness.dark
      ? Colors.white.withValues(alpha: 0.055)
      : Colors.white.withValues(alpha: 0.78);

  /// Slightly brighter fill for the selected/active item in a list.
  static Color activeFill(Brightness brightness) =>
      brightness == Brightness.dark
      ? hermesMagenta.withValues(alpha: 0.14)
      : hermesViolet.withValues(alpha: 0.10);

  static Color stroke(Brightness brightness) => brightness == Brightness.dark
      ? Colors.white.withValues(alpha: 0.10)
      : hermesViolet.withValues(alpha: 0.16);

  static Color activeStroke(Brightness brightness) =>
      brightness == Brightness.dark
      ? hermesMagenta.withValues(alpha: 0.45)
      : hermesViolet.withValues(alpha: 0.40);
}

/// Outer glow used behind accented controls. Returns a single soft shadow —
/// stack two calls with different blurs for a stronger bloom.
List<BoxShadow> hermesGlow(
  Color color, {
  double alpha = 0.40,
  double blur = 24,
  double spread = 0,
  Offset offset = Offset.zero,
}) {
  return [
    BoxShadow(
      color: color.withValues(alpha: alpha),
      blurRadius: blur,
      spreadRadius: spread,
      offset: offset,
    ),
  ];
}

// ---------------------------------------------------------------------------
// Typography
// ---------------------------------------------------------------------------

/// The "HERMES" wordmark style, shared by the home AppBar, the brand header
/// and the session drawer. Orbitron is the squared-off technical face that
/// carries the futuristic look.
TextStyle hermesBrandTextStyle({
  required double fontSize,
  required FontWeight fontWeight,
  required double letterSpacing,
  Color? color,
}) {
  return GoogleFonts.orbitron(
    fontSize: fontSize,
    fontWeight: fontWeight,
    letterSpacing: letterSpacing,
    color: color,
  );
}

// ---------------------------------------------------------------------------
// Themes
// ---------------------------------------------------------------------------

/// Builds the app theme for [brightness]. Both modes share the same accent
/// and shape language; only the canvas and glass values flip.
ThemeData hermesTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;

  final scheme =
      ColorScheme.fromSeed(
        seedColor: hermesMagenta,
        brightness: brightness,
      ).copyWith(
        primary: isDark ? hermesMagenta : hermesViolet,
        onPrimary: Colors.white,
        secondary: isDark ? hermesPlasma : hermesMagenta,
        surface: isDark ? hermesInkRaised : Colors.white,
        onSurface: isDark ? const Color(0xFFF1EAF7) : const Color(0xFF1B1524),
        onSurfaceVariant: isDark ? hermesMuted : const Color(0xFF625A70),
        surfaceContainerHighest: isDark
            ? const Color(0xFF241D31)
            : const Color(0xFFEDE4F8),
        outline: isDark
            ? Colors.white.withValues(alpha: 0.12)
            : hermesViolet.withValues(alpha: 0.20),
      );

  final base = ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    useMaterial3: true,
  );

  final textTheme = GoogleFonts.spaceGroteskTextTheme(base.textTheme).apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );

  return base.copyWith(
    textTheme: textTheme,
    // Screens paint their own aurora behind a transparent Scaffold; this is
    // the fallback for any surface that does not.
    scaffoldBackgroundColor: isDark ? hermesInk : hermesMist,
    canvasColor: isDark ? hermesInk : hermesMist,
    dividerTheme: DividerThemeData(
      color: HermesGlass.stroke(brightness),
      thickness: 1,
      space: 1,
    ),
    appBarTheme: AppBarThemeData(
      // Transparent so the aurora shows through the app bar as in the design.
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: HermesGlass.fill(brightness),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.card),
        side: BorderSide(color: HermesGlass.stroke(brightness)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? const Color(0xFF17131F) : Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.sheet),
        side: BorderSide(color: HermesGlass.stroke(brightness)),
      ),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: isDark ? const Color(0xFF0D0B12) : Colors.white,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(
          right: Radius.circular(HermesRadius.sheet),
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.tile),
      ),
      selectedColor: scheme.primary,
      selectedTileColor: HermesGlass.activeFill(brightness),
      iconColor: scheme.onSurfaceVariant,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: HermesGlass.fill(brightness),
      side: BorderSide(color: HermesGlass.stroke(brightness)),
      shape: const StadiumBorder(),
      labelStyle: textTheme.labelSmall,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: HermesGlass.fill(brightness),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HermesRadius.tile),
        borderSide: BorderSide(color: HermesGlass.stroke(brightness)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HermesRadius.tile),
        borderSide: BorderSide(color: HermesGlass.stroke(brightness)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HermesRadius.tile),
        borderSide: BorderSide(color: scheme.primary, width: 1.4),
      ),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        side: WidgetStatePropertyAll(
          BorderSide(color: HermesGlass.stroke(brightness)),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(HermesRadius.pill),
          ),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HermesRadius.pill),
        ),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HermesRadius.pill),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: scheme.primary),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.pill),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      // Snack bars float above the aurora in both modes, so they keep the
      // dark capsule look rather than flipping with the theme.
      backgroundColor: const Color(0xFF241D31),
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.chip),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    popupMenuTheme: PopupMenuThemeData(
      color: isDark ? const Color(0xFF17131F) : Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.tile),
        side: BorderSide(color: HermesGlass.stroke(brightness)),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Theme mode
// ---------------------------------------------------------------------------

/// App-wide theme mode, listenable so Settings can toggle it without an
/// ancestor-state lookup.
class HermesThemeMode {
  HermesThemeMode._();

  static final ValueNotifier<ThemeMode> notifier = ValueNotifier(
    ThemeMode.system,
  );

  static ThemeMode fromPrefsValue(String? stored) {
    switch (stored) {
      case 'dark':
        return ThemeMode.dark;
      case 'light':
        return ThemeMode.light;
      default:
        return ThemeMode.system;
    }
  }

  static String toPrefsValue(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.light:
        return 'light';
      case ThemeMode.system:
        return 'system';
    }
  }
}
