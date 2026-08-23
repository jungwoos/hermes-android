// Bot Mode roster — the agent profiles ("bots") this host runs.
//
// API: GET /api/profiles, GET|POST /api/profiles/active
//
// Two different notions of "selected" come back from the host and the screen
// keeps them apart, because conflating them is misleading: `active` is the
// sticky profile the next CLI run or gateway start picks up, while `current`
// is the profile the running gateway is already scoped to. Switching the
// active bot here does not move the session you are chatting in.
import 'package:flutter/material.dart';

import '../services/connection_manager.dart';
import '../theme.dart';
import '../widgets/aurora.dart';
import '../widgets/glass.dart';
import '../widgets/status_view.dart';

class BotsScreen extends StatefulWidget {
  final SavedConnection connection;

  /// When true the screen is rendered inside the split-view detail pane, so
  /// it must not show a back button.
  final bool embedded;

  const BotsScreen({required this.connection, this.embedded = false, super.key});

  @override
  State<BotsScreen> createState() => _BotsScreenState();
}

class _BotsScreenState extends State<BotsScreen> {
  late DashboardClient _client;
  List<Map<String, dynamic>> _bots = [];
  String? _active;
  String? _current;
  bool _loading = true;
  String? _error;
  String? _switching;

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
    _load();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bots = await _client.getProfiles();
      // The roster is the point of the screen; the active/current markers are
      // decoration, so a host that cannot report them still renders a list.
      Map<String, dynamic> active = const {};
      try {
        active = await _client.getActiveProfile();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _bots = bots;
        _active = active['active'] as String?;
        _current = active['current'] as String?;
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

  Future<void> _switchTo(String name) async {
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
        '$name is now the active bot. Restart the gateway for it to take '
        'over new chats.',
        duration: const Duration(seconds: 6),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _switching = null);
      showAppSnackBar(context, 'Could not switch bot: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuroraScaffold(
      intensity: 0.7,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Text('Bots (${_bots.length})'),
        actions: [
          FaintIconButton(
            icon: Icons.refresh,
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const StatusView.loading();

    if (_error != null) {
      return StatusView.error(
        title: 'Failed to load bots',
        message: _error!,
        onRetry: _load,
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
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        itemCount: _bots.length + 1,
        separatorBuilder: (_, index) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == 0) return _buildScopeNote(theme);
          return _buildBotCard(theme, _bots[index - 1]);
        },
      ),
    );
  }

  /// Says plainly what switching does and does not do, so nobody expects the
  /// open chat to change agent.
  Widget _buildScopeNote(ThemeData theme) {
    final current = _current;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 15, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              current == null
                  ? 'Switching sets the bot for new gateway runs. Chats '
                        'already open keep the bot they started on.'
                  : 'This gateway is running as “$current”. Switching sets '
                        'the bot for new gateway runs — chats already open '
                        'keep the bot they started on.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBotCard(ThemeData theme, Map<String, dynamic> bot) {
    final name = (bot['name'] as String?) ?? '';
    final description = (bot['description'] as String?) ?? '';
    final model = (bot['model'] as String?) ?? '';
    final provider = (bot['provider'] as String?) ?? '';
    final skillCount = (bot['skill_count'] as num?)?.toInt() ?? 0;
    final running = bot['gateway_running'] == true;
    final isActive = name == _active;
    final isCurrent = name == _current;
    final busy = _switching == name;

    final subtitle = [
      if (model.isNotEmpty) model,
      if (provider.isNotEmpty) provider,
      if (skillCount > 0) '$skillCount skills',
    ].join(' • ');

    return GlassCard(
      active: isActive,
      glow: isActive,
      onTap: busy ? null : () => _switchTo(name),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: isActive ? hermesAccentGradient : null,
                  color: isActive ? null : HermesGlass.fill(theme.brightness),
                  border: isActive
                      ? null
                      : Border.all(color: HermesGlass.stroke(theme.brightness)),
                  boxShadow: isActive
                      ? hermesGlow(hermesMagenta, alpha: 0.35, blur: 16)
                      : null,
                ),
                child: Icon(
                  Icons.smart_toy,
                  size: 18,
                  color: isActive
                      ? Colors.white
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (running) ...[
                          const SizedBox(width: 8),
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: hermesCyan,
                              boxShadow: hermesGlow(
                                hermesCyan,
                                alpha: 0.6,
                                blur: 8,
                              ),
                            ),
                          ),
                        ],
                      ],
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
              else if (isActive)
                _BotTag(label: 'active', accent: theme.colorScheme.primary)
              else if (isCurrent)
                _BotTag(label: 'running', accent: hermesCyan),
            ],
          ),
          if (description.isNotEmpty) ...[
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
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
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
