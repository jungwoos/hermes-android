// Responsive layout helpers.
// Breakpoints: phone < 600dp, tablet >= 600dp.
import 'package:flutter/material.dart';

class Responsive {
  /// 600dp breakpoint — the Material Design standard for phone/tablet.
  static const double tabletBreakpoint = 600;

  /// 720dp — wide enough to keep a pinned side panel next to the chat pane
  /// (320dp panel + ≥400dp content). Covers most tablets even in portrait.
  static const double sidePanelBreakpoint = 720;

  /// Whether the current screen is wide enough for tablet layout.
  static bool isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= tabletBreakpoint;

  /// Whether the screen is wide enough to pin the side panel open.
  static bool canPinSidePanel(BuildContext context) =>
      MediaQuery.of(context).size.width >= sidePanelBreakpoint;

  /// Returns appropriate cross-axis count for grid layouts.
  static int gridColumns(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width >= 1200) return 4;
    if (width >= 900) return 3;
    if (width >= 600) return 2;
    return 1;
  }
}
