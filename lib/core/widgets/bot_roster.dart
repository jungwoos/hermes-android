// Bot Mode roster, shared by the full-screen Bots destination and the list
// column's Bots list.
//
// Bots can be hidden by long-pressing them. That is a per-connection local
// preference, not a server-side change: the gateway reports every profile on
// the machine and some of them are never talked to from a phone. Hidden ones
// stay one tap away behind the footer, so this can never lose a bot.
//
// The roster comes from the dashboard gateway socket, not REST: `profiles.list`
// returns each bot together with its canonical chat, already resolved by the
// gateway. That is one call instead of three, it needs no per-bot API key, and
// it means mobile opens the same conversation row the desktop does rather than
// re-deriving which one that is.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// The roster minus the names the user hid. Pass [includeHidden] to list them
/// too — the footer does that so a hidden bot can be restored.
List<BotProfile> visibleBots(
  List<BotProfile> bots,
  Set<String> hidden, {
  bool includeHidden = false,
}) {
  if (includeHidden || hidden.isEmpty) return bots;
  return bots.where((bot) => !hidden.contains(bot.name)).toList();
}

/// A long bot name squeezed to fit a narrow column: the first two letters
/// stay, later vowels are dropped. `webresearch` reads as `webrsrch` — still
/// recognisable, where an ellipsis would cut the distinguishing tail off.
/// Names already short enough are left alone.
String compactBotLabel(String label, {int maxChars = 9}) {
  if (label.length <= maxChars) return label;
  const vowels = 'aeiouAEIOU';
  final head = label.substring(0, 2);
  final tail = label
      .substring(2)
      .split('')
      .where((char) => !vowels.contains(char))
      .join();
  return '$head$tail';
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
    this.selectedBotName,
    this.compact = false,
    this.minimal = false,
    super.key,
  });

  final SavedConnection connection;
  final ValueChanged<BotProfile> onOpenChat;

  /// The bot whose chat the main pane is showing, highlighted in the list the
  /// way a selected session is.
  final String? selectedBotName;

  /// Denser layout for the session panel.
  final bool compact;

  /// Stripped-back layout for a narrow column on a narrow screen: no subtext,
  /// and long names squeezed by [compactBotLabel].
  final bool minimal;

  @override
  State<BotRosterView> createState() => BotRosterViewState();
}

class BotRosterViewState extends State<BotRosterView> {
  DashboardClient? _dashboard;
  BotGateway? _gateway;
  List<BotProfile> _bots = const [];
  bool _loading = true;
  String? _error;

  /// Names the user long-pressed away, per connection.
  Set<String> _hidden = {};

  /// While set, hidden bots are listed too (dimmed) so one can be restored.
  bool _showHidden = false;

  String get _hiddenPrefKey => 'hidden_bots_${widget.connection.id}';

  @override
  void initState() {
    super.initState();
    _loadHidden();
    load();
  }

  Future<void> _loadHidden() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(
      () => _hidden = (prefs.getStringList(_hiddenPrefKey) ?? []).toSet(),
    );
  }

  /// Hides [bot], or restores it when it is already hidden. Reversible from
  /// the snack bar as well as by long-pressing again.
  Future<void> _toggleHidden(BotProfile bot) async {
    final hide = !_hidden.contains(bot.name);
    setState(() {
      if (hide) {
        _hidden.add(bot.name);
      } else {
        _hidden.remove(bot.name);
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenPrefKey, _hidden.toList());
    if (!mounted) return;
    showAppSnackBar(
      context,
      hide ? '${bot.label} hidden.' : '${bot.label} restored.',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => _toggleHidden(bot),
      ),
    );
  }

  /// The roster minus what is hidden, unless the footer opened it up.
  List<BotProfile> get _visibleBots =>
      visibleBots(_bots, _hidden, includeHidden: _showHidden);

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

    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(child: _buildList(theme)),
        // Outside the list so it stays reachable even when everything is
        // hidden — otherwise a hidden bot could not be brought back.
        if (_hidden.isNotEmpty) _buildHiddenFooter(theme),
      ],
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_bots.isEmpty) {
      return const StatusView.empty(
        icon: Icons.smart_toy_outlined,
        title: 'No bots yet',
        message: 'Agent profiles created on the host appear here.',
      );
    }

    final bots = _visibleBots;
    if (bots.isEmpty) {
      return const StatusView.empty(
        icon: Icons.visibility_off_outlined,
        title: 'Every bot is hidden',
        message: 'Use Show below to bring one back.',
      );
    }

    return RefreshIndicator(
      onRefresh: load,
      child: ListView.separated(
        padding: widget.compact
            ? const EdgeInsets.fromLTRB(10, 4, 10, 16)
            : const EdgeInsets.fromLTRB(16, 12, 16, 32),
        itemCount: bots.length,
        separatorBuilder: (_, index) => const SizedBox(height: 10),
        itemBuilder: (context, index) => _buildCard(theme, bots[index]),
      ),
    );
  }

  Widget _buildHiddenFooter(ThemeData theme) {
    return Column(
      children: [
        const Divider(height: 1),
        Padding(
          padding: EdgeInsets.fromLTRB(widget.compact ? 12 : 18, 0, 6, 0),
          child: Row(
            children: [
              Icon(
                Icons.visibility_off_outlined,
                size: 15,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '${_hidden.length} hidden',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _showHidden = !_showHidden),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Text(_showHidden ? 'Done' : 'Show'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCard(ThemeData theme, BotProfile bot) {
    // No date: the roster is already ordered by recency, and the model is what
    // the column has room to say.
    final subtitle = [
      if (bot.model.isNotEmpty) bot.model,
      if (bot.messageCount > 0) '${bot.messageCount} msgs',
    ].join(' • ');
    // A bot with no canonical chat has never been opened on the desktop.
    final ready = bot.canonicalSessionId != null;
    final hidden = _hidden.contains(bot.name);
    final selected = bot.name == widget.selectedBotName;

    return Opacity(
      opacity: hidden ? 0.45 : 1,
      child: GlassCard(
        active: selected,
        // A bot with a conversation wears its own colour; one never opened
        // stays neutral glass, which is the marker the dot used to be.
        tint: ready ? hermesBotAccent(bot.name) : null,
        padding: widget.compact
            ? const EdgeInsets.all(12)
            : const EdgeInsets.all(16),
        onTap: () => widget.onOpenChat(bot),
        onLongPress: () => _toggleHidden(bot),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.minimal ? compactBotLabel(bot.label) : bot.label,
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
                // The hollow ring dot carries this where there is no room
                // for a fixed-width chip beside the name.
                if (!ready && !widget.minimal)
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
