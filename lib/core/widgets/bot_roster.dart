// Bot Mode roster, shared by the full-screen Bots destination and the session
// panel's Bots tab.
//
// The roster comes from the dashboard gateway socket, not REST: `profiles.list`
// returns each bot together with its canonical chat, already resolved by the
// gateway. That is one call instead of three, it needs no per-bot API key, and
// it means mobile opens the same conversation row the desktop does rather than
// re-deriving which one that is.
import 'package:flutter/material.dart';

import '../services/bot_gateway.dart';
import '../services/connection_manager.dart';
import '../theme.dart';
import 'glass.dart';
import 'status_view.dart';

/// Orders the roster so the most recently used bot is first.
///
/// Bots never talked to sink to the bottom and stay in name order there, so an
/// idle roster is predictable rather than arbitrary.
List<BotProfile> sortBotsByRecency(List<BotProfile> bots) {
  final sorted = [...bots];
  sorted.sort((a, b) {
    final aAt = a.lastActive;
    final bAt = b.lastActive;
    if (aAt == null && bAt == null) return a.label.compareTo(b.label);
    if (aAt == null) return 1;
    if (bAt == null) return -1;
    final byRecency = bAt.compareTo(aAt);
    return byRecency != 0 ? byRecency : a.label.compareTo(b.label);
  });
  return sorted;
}

/// Compact "when", matching the session list: clock time today, date before.
String formatBotLastActive(double epochSeconds, {DateTime? now}) {
  final at = DateTime.fromMillisecondsSinceEpoch((epochSeconds * 1000).toInt());
  final today = now ?? DateTime.now();
  if (at.year == today.year && at.month == today.month && at.day == today.day) {
    return '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
  }
  return '${at.day}/${at.month}';
}

class BotRosterView extends StatefulWidget {
  const BotRosterView({
    required this.connection,
    required this.onOpenChat,
    this.compact = false,
    super.key,
  });

  final SavedConnection connection;
  final ValueChanged<BotProfile> onOpenChat;

  /// Denser layout for the session panel.
  final bool compact;

  @override
  State<BotRosterView> createState() => BotRosterViewState();
}

class BotRosterViewState extends State<BotRosterView> {
  DashboardClient? _dashboard;
  BotGateway? _gateway;
  List<BotProfile> _bots = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    _gateway?.close();
    _dashboard?.close();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // A ticket is single-use, so each load opens its own socket rather than
    // holding one that may have gone stale in the background.
    await _gateway?.close();
    _dashboard?.close();
    final dashboard = DashboardClient(
      host: widget.connection.host,
      port: widget.connection.dashboardPort,
      pathPrefix: widget.connection.dashboardPrefix ?? '',
      proxied: widget.connection.dashboardProxied,
      useHttps: widget.connection.useHttps,
      username: widget.connection.dashboardUsername,
      password: widget.connection.dashboardPassword,
    );
    try {
      final gateway = await BotGateway.connect(dashboard);
      final bots = await gateway.listProfiles();
      if (!mounted) {
        await gateway.close();
        dashboard.close();
        return;
      }
      setState(() {
        _dashboard = dashboard;
        _gateway = gateway;
        _bots = sortBotsByRecency(bots);
        _loading = false;
      });
    } catch (e) {
      dashboard.close();
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const StatusView.loading();

    if (_error != null) {
      return StatusView.error(
        title: 'Failed to load bots',
        message: _error!,
        onRetry: load,
      );
    }

    if (_bots.isEmpty) {
      return const StatusView.empty(
        icon: Icons.smart_toy_outlined,
        title: 'No bots yet',
        message: 'Agent profiles created on the host appear here.',
      );
    }

    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: load,
      child: ListView.separated(
        padding: widget.compact
            ? const EdgeInsets.fromLTRB(10, 4, 10, 16)
            : const EdgeInsets.fromLTRB(16, 12, 16, 32),
        itemCount: _bots.length,
        separatorBuilder: (_, index) => const SizedBox(height: 10),
        itemBuilder: (context, index) => _buildCard(theme, _bots[index]),
      ),
    );
  }

  Widget _buildCard(ThemeData theme, BotProfile bot) {
    final lastActive = bot.lastActive;
    final subtitle = [
      if (lastActive != null) formatBotLastActive(lastActive),
      if (bot.model.isNotEmpty) bot.model,
      if (bot.messageCount > 0) '${bot.messageCount} msgs',
    ].join(' • ');
    // A bot with no canonical chat has never been opened on the desktop.
    final ready = bot.canonicalSessionId != null;

    return GlassCard(
      padding: widget.compact
          ? const EdgeInsets.all(12)
          : const EdgeInsets.all(16),
      onTap: () => widget.onOpenChat(bot),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: widget.compact ? 30 : 38,
                height: widget.compact ? 30 : 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: ready ? hermesAccentGradient : null,
                  color: ready ? null : HermesGlass.fill(theme.brightness),
                  border: ready
                      ? null
                      : Border.all(color: HermesGlass.stroke(theme.brightness)),
                  boxShadow: ready
                      ? hermesGlow(hermesMagenta, alpha: 0.32, blur: 14)
                      : null,
                ),
                child: Icon(
                  Icons.smart_toy,
                  size: widget.compact ? 15 : 18,
                  color: ready
                      ? Colors.white
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      bot.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!ready)
                _BotTag(
                  label: 'not started',
                  accent: theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ),
          if (!widget.compact && bot.canonicalPreview.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              bot.canonicalPreview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BotTag extends StatelessWidget {
  const _BotTag({required this.label, required this.accent});

  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(HermesRadius.pill),
        color: accent.withValues(alpha: 0.14),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, letterSpacing: 0.4, color: accent),
      ),
    );
  }
}
