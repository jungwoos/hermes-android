import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/connection_manager.dart';
import '../theme.dart';
import '../utils/responsive.dart';
import '../widgets/aurora.dart';
import '../widgets/bot_roster.dart';
import '../widgets/brand_hero.dart';
import '../widgets/glass.dart';
import '../widgets/plasma_orb.dart';
import '../widgets/status_view.dart';
import 'bots_screen.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';
import 'memory_screen.dart';
import 'cron_screen.dart';
import 'skills_screen.dart';

class SessionListScreen extends StatefulWidget {
  final SavedConnection connection;
  const SessionListScreen({required this.connection, super.key});

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen> {
  late final ApiClient _client;
  List<Session> _sessions = [];
  bool _loading = true;
  String? _error;
  bool _healthOk = false;
  bool _healthChecking = true;
  final Set<String> _deletingSessionIds = {};

  // Split layout (wide screens): the session list + nav render as a fixed
  // left panel (toggled by the hamburger button instead of a modal drawer)
  // while the selected chat renders in the right pane.
  static const String _panelPrefKey = 'side_panel_open';
  static const double _panelWidth = 320;
  bool _panelOpen = true;
  Session? _selectedSession;

  /// Nav destination shown in the detail pane instead of the chat
  /// ('bots' | 'memory' | 'cron' | 'skills' | 'settings'), or null for
  /// the chat.
  String? _selectedNavKey;

  /// Which list the side panel shows. Bots are a peer of sessions there,
  /// not a nav destination, so switching between them keeps the detail pane.
  bool _panelShowsBots = false;

  /// Set while the detail pane is chatting with a bot rather than with the
  /// profile this screen's connection points at. Bots have their own API
  /// server and key, so the chat needs a different connection.
  SavedConnection? _botConnection;
  final _botRoster = GlobalKey<BotRosterViewState>();

  /// Wide screens use the split layout; narrow screens fall back to the
  /// modal drawer + pushed routes.
  bool get _splitLayoutActive => Responsive.canPinSidePanel(context);

  @override
  void initState() {
    super.initState();
    _client = ApiClient(
      baseUrl: widget.connection.baseUrl,
      apiKey: widget.connection.apiKey,
      pathPrefix: widget.connection.gatewayPrefix ?? '',
    );
    _loadPanelPref();
    _checkHealth();
  }

  Future<void> _loadPanelPref() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _panelOpen = prefs.getBool(_panelPrefKey) ?? true);
  }

  Future<void> _togglePanel() async {
    setState(() => _panelOpen = !_panelOpen);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_panelPrefKey, _panelOpen);
  }

  Future<void> _checkHealth() async {
    setState(() => _healthChecking = true);
    final ok = await _client.healthCheck();
    if (!mounted) return;
    setState(() {
      _healthOk = ok;
      _healthChecking = false;
    });
    if (ok) _fetchSessions();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _fetchSessions() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sessions = await _client.getSessions();
      if (!mounted) return;
      final prefs = await SharedPreferences.getInstance();
      final key = 'excluded_session_sources_${widget.connection.id}';
      final excluded = prefs.getStringList(key) ?? [];
      final filtered =
          sessions.where((s) => !excluded.contains(s.source)).toList();
      if (!mounted) return;
      setState(() {
        _sessions = filtered;
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

  Future<void> _confirmDeleteSession(Session session) async {
    final title = session.title.trim().isEmpty
        ? 'Untitled session'
        : session.title;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete session?'),
        content: Text(
          'Delete "$title" from the remote Hermes history? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _deleteSession(session);
    }
  }

  Future<void> _deleteSession(Session session) async {
    if (_deletingSessionIds.contains(session.id)) return;
    setState(() => _deletingSessionIds.add(session.id));

    try {
      await _client.deleteSession(session.id);
      if (!mounted) return;
      setState(() {
        _sessions.removeWhere((item) => item.id == session.id);
        _deletingSessionIds.remove(session.id);
        if (_selectedSession?.id == session.id) _selectedSession = null;
      });
      showAppSnackBar(context, 'Session deleted from remote Hermes.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _deletingSessionIds.remove(session.id));
      showAppSnackBar(context, 'Could not delete session: $e', isError: true);
    }
  }

  void _createNewSession() {
    final sessionId = GatewayChatClient.generateSessionId();
    final session = Session(
      id: sessionId,
      title: 'New Chat',
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
    );
    _openSession(session);
  }

  void _openSession(Session session) {
    if (_splitLayoutActive) {
      setState(() {
        _selectedSession = session;
        _selectedNavKey = null;
        _botConnection = null;
      });
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(connection: widget.connection, session: session),
      ),
    );
  }

  /// Opens a chat with [bot] in the detail pane, asking for that bot's
  /// credentials the first time it is used.
  Future<void> _openBotChat(String bot, {required bool fresh}) async {
    final connection = await resolveBotConnection(
      context: context,
      base: widget.connection,
      bot: bot,
      multiplex: _botRoster.currentState?.multiplex ?? false,
    );
    if (connection == null || !mounted) return;

    // Reopen the bot's last conversation so its history is there, unless the
    // user explicitly asked for a new one.
    final session =
        (fresh ? null : await latestBotSession(connection)) ??
        newBotSession(bot);
    if (!mounted) return;
    if (!_splitLayoutActive) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(connection: connection, session: session),
        ),
      );
      return;
    }
    setState(() {
      _botConnection = connection;
      _selectedSession = session;
      _selectedNavKey = null;
    });
  }

  String _formatTime(double ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).toInt());
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}/${dt.month}';
  }

  void _openNav(String key, {required bool fromDrawer}) {
    if (!fromDrawer && _splitLayoutActive) {
      // Split layout: show the destination in the detail pane.
      setState(() => _selectedNavKey = key);
      return;
    }
    if (fromDrawer) Navigator.pop(context); // close drawer
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _navScreen(key, embedded: false)),
    );
  }

  Widget _navScreen(String key, {required bool embedded}) {
    switch (key) {
      case 'bots':
        return BotsScreen(connection: widget.connection, embedded: embedded);
      case 'memory':
        return MemoryScreen(connection: widget.connection, embedded: embedded);
      case 'cron':
        return CronScreen(connection: widget.connection, embedded: embedded);
      case 'skills':
        return SkillsScreen(connection: widget.connection, embedded: embedded);
      default:
        return SettingsScreen(
          connection: widget.connection,
          embedded: embedded,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final split = _splitLayoutActive;

    final title = Text(
      'HERMES',
      style: hermesBrandTextStyle(
        fontWeight: FontWeight.w700,
        letterSpacing: 8,
        fontSize: 19,
      ),
    );
    final healthWarning = !_healthOk
        ? const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Icon(Icons.warning_amber, color: hermesAlert, size: 20),
          )
        : null;
    final refreshButton = FaintIconButton(
      icon: Icons.refresh,
      tooltip: 'Refresh sessions',
      onPressed: _loading ? null : _fetchSessions,
    );

    if (split) {
      // Wide screens: the hamburger toggles a fixed side panel instead of
      // opening a modal drawer; the selected chat renders in the right pane.
      return AuroraScaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.menu),
            tooltip: _panelOpen ? 'Hide session panel' : 'Show session panel',
            onPressed: _togglePanel,
          ),
          title: title,
          centerTitle: true,
          actions: [
            ?healthWarning,
            refreshButton,
            if (!_panelOpen)
              IconButton(
                icon: const Icon(Icons.add_comment_outlined),
                tooltip: 'New Chat',
                onPressed: _createNewSession,
              ),
          ],
        ),
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_panelOpen) ...[
              SizedBox(width: _panelWidth, child: _buildSidePanel()),
              const VerticalDivider(width: 1, thickness: 1),
            ],
            Expanded(child: _buildDetailPane()),
          ],
        ),
      );
    }

    return AuroraScaffold(
      appBar: AppBar(
        title: title,
        centerTitle: true,
        actions: [
          ?healthWarning,
          refreshButton,
        ],
      ),
      drawer: _buildDrawer(),
      floatingActionButton: GradientOrbButton(
        icon: Icons.add_comment_outlined,
        size: 58,
        tooltip: 'New Chat',
        onPressed: _createNewSession,
      ),
      body: _buildBody(),
    );
  }

  /// Nav destinations shared by the modal drawer and the fixed side panel.
  List<Widget> _navTiles({required bool fromDrawer}) {
    final scheme = Theme.of(context).colorScheme;

    Widget tile(String key, IconData icon, String label) {
      final selected =
          !fromDrawer && _splitLayoutActive && _selectedNavKey == key;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: ListTile(
          dense: true,
          leading: Icon(
            icon,
            size: 20,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
          title: Text(
            label,
            style: TextStyle(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          selected: selected,
          onTap: () => _openNav(key, fromDrawer: fromDrawer),
        ),
      );
    }

    return [
      tile('bots', Icons.smart_toy_outlined, 'Bots'),
      tile('memory', Icons.memory, 'Memory'),
      tile('cron', Icons.schedule, 'Cron Jobs'),
      tile('skills', Icons.auto_awesome, 'Skills'),
      const Divider(indent: 16, endIndent: 16),
      tile('settings', Icons.settings, 'Settings'),
    ];
  }

  Widget _buildDrawer() {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            // Brand header: the orb doubles as the drawer's masthead.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
              child: Row(
                children: [
                  const PlasmaOrb(size: 54, intensity: 0.6),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'HERMES',
                          style: hermesBrandTextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 5,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.connection.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(indent: 16, endIndent: 16),
            const SizedBox(height: 4),
            ..._navTiles(fromDrawer: true),
          ],
        ),
      ),
    );
  }

  /// Fixed left panel for the wide-screen split layout: new-chat button,
  /// session list, and the nav destinations at the bottom.
  Widget _buildSidePanel() {
    final brightness = Theme.of(context).brightness;
    return Material(
      // Translucent so the aurora keeps flowing behind the panel.
      color: HermesGlass.fill(brightness),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('Sessions'),
                    icon: Icon(Icons.forum_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('Bots'),
                    icon: Icon(Icons.smart_toy_outlined, size: 16),
                  ),
                ],
                selected: {_panelShowsBots},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    setState(() => _panelShowsBots = s.first),
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
            if (!_panelShowsBots)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: GradientPillButton(
                  label: 'New Chat',
                  icon: Icons.add,
                  expand: true,
                  onPressed: _createNewSession,
                ),
              ),
            Expanded(
              child: _panelShowsBots
                  ? BotRosterView(
                      key: _botRoster,
                      connection: widget.connection,
                      compact: true,
                      onOpenChat: _openBotChat,
                    )
                  : _buildBody(inPanel: true),
            ),
            const Divider(height: 1),
            const SizedBox(height: 4),
            ..._navTiles(fromDrawer: false),
          ],
        ),
      ),
    );
  }

  /// Right pane of the split layout: a nav destination, the selected chat,
  /// or a placeholder.
  Widget _buildDetailPane() {
    final navKey = _selectedNavKey;
    if (navKey != null) {
      // Keyed so switching destinations rebuilds the screen state.
      return KeyedSubtree(
        key: ValueKey('nav-$navKey'),
        child: _navScreen(navKey, embedded: true),
      );
    }
    final selected = _selectedSession;
    if (selected == null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: HermesHeader(
            orbSize: 140,
            subtitle: _panelOpen
                ? 'Pick a session from the panel or start a new chat'
                : 'Open the menu to pick a session or start a new chat',
          ),
        ),
      );
    }
    // Keyed by session id so switching sessions rebuilds the chat state.
    return ChatScreen(
      key: ValueKey(selected.id),
      connection: _botConnection ?? widget.connection,
      session: selected,
      embedded: true,
    );
  }

  Widget _buildBody({bool inPanel = false}) {
    if (!_healthOk) {
      if (_healthChecking) {
        return StatusView.loading(
          message: 'Connecting to ${widget.connection.baseUrl}...',
        );
      }
      return StatusView.error(
        icon: Icons.wifi_off,
        title: 'Connection failed',
        message:
            'Make sure the Gateway API Server is running\n(hermes gateway status)',
        onRetry: _checkHealth,
      );
    }

    if (_loading) return const StatusView.loading();

    if (_error != null) {
      return StatusView.error(
        title: 'Connection issue',
        message: _error!,
        onRetry: _fetchSessions,
      );
    }

    if (_sessions.isEmpty) {
      return const StatusView.empty(
        icon: Icons.chat_bubble_outline,
        title: 'No sessions yet',
        message: 'Tap the + button to start a new chat',
      );
    }

    final theme = Theme.of(context);

    return RefreshIndicator(
      onRefresh: _fetchSessions,
      child: ListView.separated(
        padding: inPanel
            ? const EdgeInsets.fromLTRB(10, 4, 10, 16)
            : const EdgeInsets.fromLTRB(16, 8, 16, 96),
        itemCount: _sessions.length,
        separatorBuilder: (_, index) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final session = _sessions[index];
          final isDeleting = _deletingSessionIds.contains(session.id);
          final isSelected = inPanel && _selectedSession?.id == session.id;

          return Opacity(
            opacity: isDeleting ? 0.5 : 1,
            child: GlassCard(
              active: isSelected,
              padding: const EdgeInsets.all(14),
              onTap: isDeleting ? null : () => _openSession(session),
              onLongPress: isDeleting
                  ? null
                  : () => _confirmDeleteSession(session),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Live sessions get a lit dot; dormant ones a hollow ring.
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(top: 6, right: 12),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: session.isActive ? hermesAccentGradient : null,
                      border: session.isActive
                          ? null
                          : Border.all(
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.5),
                              width: 1.5,
                            ),
                      boxShadow: session.isActive
                          ? hermesGlow(hermesMagenta, alpha: 0.6, blur: 10)
                          : null,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${session.messageCount} msgs \u2022 ${session.model} \u2022 '
                          '${_formatTime(session.startedAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 11.5,
                          ),
                        ),
                        if (session.preview.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            session.preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.75),
                              height: 1.4,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (isDeleting)
                    const Padding(
                      padding: EdgeInsets.only(left: 8, top: 2),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
