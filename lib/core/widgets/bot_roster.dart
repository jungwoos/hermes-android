// Bot Mode roster, shared by the full-screen Bots destination and the
// session panel's Bots tab.
//
// Tapping a bot opens a chat with it. That needs more than a name: the
// gateway scopes API keys per profile, so the default connection's key is
// rejected on another bot's routes. The first open asks for that bot's
// credentials and remembers them.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/connection_manager.dart';
import '../theme.dart';
import 'glass.dart';
import 'status_view.dart';

/// Resolves a connection that talks to [bot], asking for its credentials the
/// first time. Returns null if the user cancels.
Future<SavedConnection?> resolveBotConnection({
  required BuildContext context,
  required SavedConnection base,
  required String bot,
  required bool multiplex,
  bool forcePrompt = false,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final manager = ConnectionManager(prefs);
  final stored = manager.getBotTarget(base.id, bot);

  var target = forcePrompt ? null : stored;
  if (target == null) {
    if (!context.mounted) return null;
    target = await _promptBotTarget(
      context,
      base: base,
      bot: bot,
      multiplex: multiplex,
      existing: stored,
    );
    if (target == null) return null;
    await manager.saveBotTarget(base.id, bot, target);
  }
  return SavedConnection.forBot(base, bot, target);
}

Future<BotTarget?> _promptBotTarget(
  BuildContext context, {
  required SavedConnection base,
  required String bot,
  required bool multiplex,
  BotTarget? existing,
}) {
  // Under a multiplexing gateway every bot shares the default port behind a
  // `/p/<name>` prefix; otherwise each bot runs its own API server on a port
  // only the operator knows.
  final portCtrl = TextEditingController(
    text: '${existing?.port ?? base.port}',
  );
  final prefixCtrl = TextEditingController(
    text: existing?.prefix ?? (multiplex ? '/p/$bot' : ''),
  );
  final keyCtrl = TextEditingController(text: existing?.apiKey ?? '');
  String? error;

  return showDialog<BotTarget>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: Text('Connect to $bot'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  multiplex
                      ? 'This gateway multiplexes profiles, so $bot is reachable '
                            'on the same port behind its own path prefix. It '
                            'still needs its own API_SERVER_KEY.'
                      : 'Each profile runs its own API server. Enter the port '
                            'from $bot\'s .env (API_SERVER_PORT) and its own '
                            'API_SERVER_KEY — the default profile\'s key is '
                            'rejected here.',
                  style: TextStyle(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    error!,
                    style: const TextStyle(color: hermesAlert, fontSize: 13),
                  ),
                ),
              TextField(
                controller: portCtrl,
                decoration: const InputDecoration(labelText: 'Port'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: prefixCtrl,
                decoration: const InputDecoration(
                  labelText: 'Gateway path prefix (optional)',
                  hintText: 'e.g. /p/coder',
                ),
                autocorrect: false,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: keyCtrl,
                decoration: const InputDecoration(labelText: 'API key'),
                obscureText: true,
                autocorrect: false,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final port = int.tryParse(portCtrl.text.trim());
              final key = keyCtrl.text.trim();
              if (port == null || port <= 0) {
                setDialogState(() => error = 'Enter a valid port number.');
                return;
              }
              if (key.isEmpty) {
                setDialogState(() => error = 'The bot\'s API key is required.');
                return;
              }
              Navigator.pop(
                ctx,
                BotTarget(
                  port: port,
                  prefix: prefixCtrl.text.trim(),
                  apiKey: key,
                ),
              );
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    ),
  ).whenComplete(() {
    portCtrl.dispose();
    prefixCtrl.dispose();
    keyCtrl.dispose();
  });
}

/// A fresh session to open against a bot. Chats are created client-side and
/// only exist on the host once the first message is sent, exactly as the
/// session list's New Chat does.
Session newBotSession(String bot) {
  return Session(
    id: GatewayChatClient.generateSessionId(),
    title: bot,
    model: 'hermes-agent',
    source: 'mobile',
    messageCount: 0,
    isActive: true,
    preview: '',
    startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
  );
}

/// The title the desktop uses as a bot's forever-chat identity.
const String kBotChatTitle = 'Bot Chat';

/// The bot's canonical conversation — the same row the desktop opens.
///
/// Desktop pins a bot to one forever-chat identified by
/// (profile, session titled exactly "Bot Chat"), deliberately by name rather
/// than by a stored session id. Matching on that title is what makes both
/// clients land on one conversation instead of each keeping its own.
///
/// Asked of the bot's own gateway rather than the dashboard's cross-profile
/// aggregate: it answers in the shape the app already parses and is
/// authoritative for the profile being opened. The window is widened because
/// cron runs can push the bot chat well down a profile's recent list.
///
/// Falls back to the profile's newest session when there is no canonical row
/// yet — a bot the desktop has never opened has none. A failure resolves to
/// null so the caller opens a fresh chat and the chat screen surfaces the
/// real error when it loads messages.
Future<Session?> canonicalBotSession(SavedConnection botConnection) async {
  final client = ApiClient(
    baseUrl: botConnection.baseUrl,
    apiKey: botConnection.apiKey,
    pathPrefix: botConnection.gatewayPrefix ?? '',
  );
  try {
    final sessions = await client.getSessions(limit: 200);
    return pickCanonicalSession(sessions);
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// Picks the bot's forever-chat out of [sessions], or the newest session when
/// the bot has none yet.
Session? pickCanonicalSession(List<Session> sessions) {
  if (sessions.isEmpty) return null;
  for (final session in sessions) {
    if (session.title == kBotChatTitle) return session;
  }
  return sessions.reduce((a, b) => b.startedAt > a.startedAt ? b : a);
}

/// Orders the roster so the most recently used bot is first.
///
/// Bots that have never been talked to sink to the bottom and stay in name
/// order there, so an idle roster is still predictable rather than arbitrary.
List<Map<String, dynamic>> sortBotsByRecency(
  List<Map<String, dynamic>> bots,
  Map<String, double> lastActive,
) {
  final sorted = [...bots];
  sorted.sort((a, b) {
    final aName = (a['name'] as String?) ?? '';
    final bName = (b['name'] as String?) ?? '';
    final aAt = lastActive[aName];
    final bAt = lastActive[bName];
    if (aAt == null && bAt == null) return aName.compareTo(bName);
    if (aAt == null) return 1;
    if (bAt == null) return -1;
    final byRecency = bAt.compareTo(aAt);
    return byRecency != 0 ? byRecency : aName.compareTo(bName);
  });
  return sorted;
}

/// Compact "when", matching the session list: clock time today, date before.
String formatBotLastActive(double epochSeconds, {DateTime? now}) {
  final at = DateTime.fromMillisecondsSinceEpoch(
    (epochSeconds * 1000).toInt(),
  );
  final today = now ?? DateTime.now();
  if (at.year == today.year && at.month == today.month && at.day == today.day) {
    return '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
  }
  return '${at.day}/${at.month}';
}

/// The roster itself: loads profiles, shows which is active, and hands the
/// selected bot back to the caller.
class BotRosterView extends StatefulWidget {
  const BotRosterView({
    required this.connection,
    required this.onOpenChat,
    this.compact = false,
    super.key,
  });

  final SavedConnection connection;

  /// Called with the bot's name once the user picks one. [fresh] skips
  /// resuming the bot's last conversation and starts an empty one.
  final void Function(String bot, {required bool fresh}) onOpenChat;

  /// Denser layout for the session panel.
  final bool compact;

  @override
  State<BotRosterView> createState() => BotRosterViewState();
}

class BotRosterViewState extends State<BotRosterView> {
  late DashboardClient _client;
  List<Map<String, dynamic>> _bots = [];
  String? _active;
  String? _current;
  bool _multiplex = false;
  Map<String, double> _lastActive = const {};
  bool _loading = true;
  String? _error;
  String? _switching;

  /// Whether the host fronts every profile from one gateway. The chat-opening
  /// flow needs this to prefill the right address for a bot.
  bool get multiplex => _multiplex;

  @override
  void initState() {
    super.initState();
    _client = DashboardClient(
      host: widget.connection.host,
      port: widget.connection.dashboardPort,
      pathPrefix: widget.connection.dashboardPrefix ?? "",
      proxied: widget.connection.dashboardProxied,
      useHttps: widget.connection.useHttps,
      username: widget.connection.dashboardUsername,
      password: widget.connection.dashboardPassword,
    );
    load();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bots = await _client.getProfiles();
      // The roster is the point; the active markers and topology are
      // decoration, so a host that will not report them still renders a list.
      Map<String, dynamic> active = const {};
      try {
        active = await _client.getActiveProfile();
      } catch (_) {}
      final multiplex = await _client.isMultiplexEnabled();
      // Recency is a nicety: a host that cannot aggregate sessions still
      // renders the roster, just in the order the API returned it.
      Map<String, double> lastActive = const {};
      try {
        lastActive = await _client.getProfileLastActive();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _bots = sortBotsByRecency(bots, lastActive);
        _lastActive = lastActive;
        _active = active['active'] as String?;
        _current = active['current'] as String?;
        _multiplex = multiplex;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _setActive(String name) async {
    if (_switching != null || name == _active) return;
    setState(() => _switching = name);
    try {
      final res = await _client.setActiveProfile(name);
      if (!mounted) return;
      setState(() {
        _active = (res['active'] as String?) ?? name;
        _switching = null;
      });
      showAppSnackBar(
        context,
        '$name is now the active bot for new gateway runs.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _switching = null);
      showAppSnackBar(context, 'Could not switch bot: $e', isError: true);
    }
  }

  Future<void> _forgetCredentials(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('bot_target_${widget.connection.id}_$name');
    if (!mounted) return;
    showAppSnackBar(context, 'Saved credentials for $name cleared.');
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
    final pad = widget.compact
        ? const EdgeInsets.fromLTRB(10, 4, 10, 16)
        : const EdgeInsets.fromLTRB(16, 12, 16, 32);

    return RefreshIndicator(
      onRefresh: load,
      child: ListView.separated(
        padding: pad,
        itemCount: _bots.length,
        separatorBuilder: (_, index) => const SizedBox(height: 10),
        itemBuilder: (context, index) => _buildCard(theme, _bots[index]),
      ),
    );
  }

  Widget _buildCard(ThemeData theme, Map<String, dynamic> bot) {
    final name = (bot['name'] as String?) ?? '';
    final description = (bot['description'] as String?) ?? '';
    final model = (bot['model'] as String?) ?? '';
    final skillCount = (bot['skill_count'] as num?)?.toInt() ?? 0;
    final running = bot['gateway_running'] == true;
    final isActive = name == _active;
    final isCurrent = name == _current;
    final busy = _switching == name;

    final lastActive = _lastActive[name];
    final subtitle = [
      if (lastActive != null) formatBotLastActive(lastActive),
      if (model.isNotEmpty) model,
      if (skillCount > 0) '$skillCount skills',
    ].join(' • ');

    return GlassCard(
      padding: widget.compact
          ? const EdgeInsets.all(12)
          : const EdgeInsets.all(16),
      onTap: busy ? null : () => widget.onOpenChat(name, fresh: false),
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
                  gradient: running ? hermesAccentGradient : null,
                  color: running ? null : HermesGlass.fill(theme.brightness),
                  border: running
                      ? null
                      : Border.all(color: HermesGlass.stroke(theme.brightness)),
                  boxShadow: running
                      ? hermesGlow(hermesMagenta, alpha: 0.32, blur: 14)
                      : null,
                ),
                child: Icon(
                  Icons.smart_toy,
                  size: widget.compact ? 15 : 18,
                  color: running
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
                      name,
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
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else ...[
                if (isActive)
                  _BotTag(label: 'active', accent: theme.colorScheme.primary)
                else if (isCurrent)
                  _BotTag(label: 'running', accent: hermesCyan),
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  padding: EdgeInsets.zero,
                  onSelected: (action) {
                    if (action == 'new') widget.onOpenChat(name, fresh: true);
                    if (action == 'active') _setActive(name);
                    if (action == 'forget') _forgetCredentials(name);
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'new',
                      child: Text('New chat'),
                    ),
                    if (!isActive)
                      const PopupMenuItem(
                        value: 'active',
                        child: Text('Set as active'),
                      ),
                    const PopupMenuItem(
                      value: 'forget',
                      child: Text('Forget saved credentials'),
                    ),
                  ],
                ),
              ],
            ],
          ),
          if (!widget.compact && description.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              description,
              maxLines: 3,
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
        color: accent.withValues(alpha: 0.16),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, letterSpacing: 0.5, color: accent),
      ),
    );
  }
}
