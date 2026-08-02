// Shared "async body" states for screens that load remote data: a loading
// spinner, an error message with Retry, or an empty-state message. Screens
// swap between these instead of hand-rolling the same Icon/Column
// boilerplate, so loading/error/empty presentation stays consistent.
import 'package:flutter/material.dart';

import '../theme.dart';
import 'glass.dart';

enum _StatusViewKind { loading, error, empty }

class StatusView extends StatelessWidget {
  /// Centered spinner, optionally with a caption below it (e.g. "Connecting
  /// to $url...").
  const StatusView.loading({this.message, super.key})
    : _kind = _StatusViewKind.loading,
      icon = null,
      title = null,
      onRetry = null;

  /// Icon + title + message + Retry button, for a failed load.
  const StatusView.error({
    required this.title,
    required this.message,
    required this.onRetry,
    this.icon = Icons.error_outline,
    super.key,
  }) : _kind = _StatusViewKind.error;

  /// Icon + title + optional message, for a successful load with no items.
  const StatusView.empty({
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    super.key,
  }) : _kind = _StatusViewKind.empty,
       onRetry = null;

  final _StatusViewKind _kind;
  final IconData? icon;
  final String? title;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_kind == _StatusViewKind.loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The ring sits inside its own bloom so a bare spinner does not
            // read as unstyled Material against the aurora.
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: hermesGlow(hermesMagenta, alpha: 0.30, blur: 26),
              ),
              child: const SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 20),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      );
    }

    final isError = _kind == _StatusViewKind.error;
    final accent = isError ? hermesAlert : theme.colorScheme.onSurfaceVariant;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: 0.10),
                border: Border.all(color: accent.withValues(alpha: 0.28)),
                boxShadow: isError
                    ? hermesGlow(hermesAlert, alpha: 0.22, blur: 30)
                    : null,
              ),
              child: Icon(icon, size: 36, color: accent),
            ),
            const SizedBox(height: 20),
            Text(
              title!,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 24),
              GradientPillButton(
                label: 'Retry',
                icon: Icons.refresh,
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Inline success/error message card. Error uses the theme's error container
/// so it adapts to brightness automatically; success has no Material
/// colorScheme slot, so it derives from brightness instead (light background
/// + dark text in light mode).
class StatusMessageCard extends StatelessWidget {
  const StatusMessageCard.success({required this.message, super.key})
    : _isError = false;

  const StatusMessageCard.error({required this.message, super.key})
    : _isError = true;

  final bool _isError;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final Color background;
    final Color foreground;
    final Color accent;
    if (_isError) {
      background = theme.colorScheme.errorContainer;
      foreground = theme.colorScheme.onErrorContainer;
      accent = hermesAlert;
    } else {
      background = isDark ? const Color(0xFF0E3A33) : Colors.green.shade50;
      foreground = isDark ? Colors.white : Colors.green.shade900;
      accent = const Color(0xFF3DDC97);
    }
    return Card(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.tile),
        side: BorderSide(color: accent.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _isError ? Icons.error_outline : Icons.check_circle_outline,
              size: 18,
              color: accent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message, style: TextStyle(color: foreground)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows a SnackBar styled consistently for error vs. success/neutral
/// messages, replacing the scattered `backgroundColor: Colors.orange`
/// literals across screens.
void showAppSnackBar(
  BuildContext context,
  String message, {
  bool isError = false,
  Duration duration = const Duration(seconds: 4),
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 18,
            color: isError ? hermesAlert : hermesPlasma,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
      duration: duration,
    ),
  );
}
