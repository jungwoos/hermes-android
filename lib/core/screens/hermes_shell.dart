// The one screen the app runs in.
//
// Picking a gateway, a session, a bot or a dashboard destination is a selection
// inside this shell — never a route pushed on top of it. That is why the
// gateway roster lives beside the sessions and bots lists instead of in a
// parent screen: switching gateways keeps the same layout on screen and only
// swaps what the list column and the main pane show.
//
// Navigation lives in the list column itself — a Sessions/Bots tab switch over
// the list, with the dashboard destinations under it — rather than in a drawer
// or a separate rail. A drawer had to cover the content it navigated, and a
// rail cost a third column on a screen that only has room for two.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/connection_manager.dart';
import '../theme.dart';
import '../utils/responsive.dart';
import '../widgets/aurora.dart';
import '../widgets/bot_roster.dart';
import '../widgets/brand_hero.dart';
import '../widgets/connection_dialogs.dart';
import '../widgets/connection_list.dart';
import '../widgets/glass.dart';
import '../widgets/status_view.dart';
import '../services/bot_gateway.dart';
import 'bot_chat_screen.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';
import 'memory_screen.dart';
import 'cron_screen.dart';
import 'skills_screen.dart';

/// Which list the side panel shows. Gateways, sessions and bots are peers
/// there: switching between them never leaves the shell.
enum _PanelList { gateways, sessions, bots }

class HermesShell extends StatefulWidget {
  final ConnectionManager connManager;
  const HermesShell({required this.connManager, super.key});

  @override
  State<HermesShell> createState() => _HermesShellState();
}

class _HermesShellState extends State<HermesShell> {
  static const String _lastConnectionKey = 'last_connection_id';

  /// Every saved gateway, and the one the shell is currently showing. A null
  /// [_connection] is the first-run state: the panel and the main pane both
  /// show the roster.
  List<SavedConnection> _connections = const [];
  SavedConnection? _connection;

  /// Null when the active connection has no Gateway API Server. Sessions live
  /// on the gateway; everything else on this screen rides the dashboard, so the
  /// panel falls back to the bot roster instead of failing.
  ApiClient? _client;
  List<Session> _sessions = [];
  bool _loading = true;
  String? _error;
  bool _healthOk = false;
  bool _healthChecking = true;
  final Set<String> _deletingSessionIds = {};

  // Split layout (wide screens): the list column is pinned beside the main
  // pane, toggled by the hamburger button. Narrow screens show one column at a
  // time — the list until something is selected, then the selection — with the
  // rail always beside it.
  /// Width of the pinned list column on a tablet-width screen — the Fold's
  /// main screen (704dp) keeps ~500dp for the main pane.
  static const double _panelWidth = 205;

  /// Far narrower for a phone-width screen: on the Fold's cover screen (475dp)
  /// that leaves ~375dp of chat. The column is down to a colour dot, a name
  /// and one-letter tab labels at this width.
  static const double _panelWidthMinimal = 100;
  Session? _selectedSession;

  /// Nav destination shown in the detail pane instead of the chat
  /// ('bots' | 'memory' | 'cron' | 'skills' | 'settings'), or null for
  /// the chat.
  String? _selectedNavKey;

  /// The panel list the user last picked. Read through [_panelList], which
  /// pins the roster while no gateway is selected.
  _PanelList _panelListChoice = _PanelList.gateways;

  /// Set while the detail pane is showing a bot's chat rather than a session
  /// of this screen's own profile.
  BotProfile? _selectedBot;

  /// Wide screens pin the list column beside the main pane; narrow screens
  /// show one or the other.
  bool get _splitLayoutActive => Responsive.canPinSidePanel(context);

  /// True while the list column and the main pane are both on screen. Wide
  /// screens always show both: the column carries the navigation, so hiding it
  /// would leave nothing to navigate with.
  bool get _panelPinned => _splitLayoutActive;

  /// The pinned column is narrower where the screen is, matching the
  /// stripped-back layout [_buildListColumn] switches to there.
  double get _listColumnWidth =>
      Responsive.isTablet(context) ? _panelWidth : _panelWidthMinimal;

  /// True while the main pane is showing something other than a list.
  bool get _hasSelection =>
      _selectedNavKey != null ||
      _selectedBot != null ||
      _selectedSession != null;

  /// The active connection. Only read it where one is guaranteed.
  SavedConnection get _conn => _connection!;

  bool get _hasGateway => _connection?.hasGateway ?? false;

  bool get _panelShowsBots => _panelList == _PanelList.bots;

  /// With no gateway selected there is nothing else the panel could list.
  _PanelList get _panelList =>
      _connection == null ? _PanelList.gateways : _panelListChoice;

  @override
  void initState() {
    super.initState();
    _connections = widget.connManager.getConnections();
    final lastId = widget.connManager.prefs.getString(_lastConnectionKey);
    final last = _connections.where((c) => c.id == lastId).firstOrNull;
    if (last != null) {
      _bindConnection(last);
    } else {
      _idleWithoutConnection();
    }
    if (_client != null) _checkHealth();
  }

  /// Points the shell at [conn]: rebuilds the gateway client and clears
  /// whatever the previous gateway had loaded. Assigns fields directly, so
  /// callers wrap it in `setState` once the tree is mounted.
  void _bindConnection(SavedConnection conn) {
    _client?.close();
    _client = null;
    _connection = conn;
    _sessions = [];
    _error = null;
    _healthOk = false;
    _deletingSessionIds.clear();
    final gatewayBaseUrl = conn.gatewayBaseUrl;
    if (gatewayBaseUrl != null) {
      _client = ApiClient(
        baseUrl: gatewayBaseUrl,
        apiKey: conn.apiKey,
        pathPrefix: conn.gatewayPrefix ?? '',
      );
      _panelListChoice = _PanelList.sessions;
      _loading = true;
      _healthChecking = true;
    } else {
      // Nothing to load or health-check: open on the bot roster.
      _panelListChoice = _PanelList.bots;
      _loading = false;
      _healthChecking = false;
    }
  }

  /// Drops back to the roster — first run, or the active gateway was deleted.
  void _idleWithoutConnection() {
    _client?.close();
    _client = null;
    _connection = null;
    _sessions = [];
    _selectedSession = null;
    _selectedBot = null;
    _selectedNavKey = null;
    _panelListChoice = _PanelList.gateways;
    _loading = false;
    _healthChecking = false;
    _error = null;
    _healthOk = false;
    _deletingSessionIds.clear();
  }

  /// Shows [conn] in this same shell. Nothing is pushed: the panel switches
  /// back to its lists and the main pane re-renders for the new gateway.
  void _selectConnection(SavedConnection conn) {
    widget.connManager.prefs.setString(_lastConnectionKey, conn.id);
    if (_connection?.id == conn.id) {
      setState(
        () => _panelListChoice = conn.hasGateway
            ? _PanelList.sessions
            : _PanelList.bots,
      );
      return;
    }
    setState(() {
      _selectedSession = null;
      _selectedBot = null;
      _selectedNavKey = null;
      _bindConnection(conn);
    });
    if (_client != null) _checkHealth();
  }

  void _addConnection() {
    showConnectionDialog(
      context,
      connManager: widget.connManager,
      onSaved: () {
        final wasIdle = _connection == null;
        _connectionsChanged();
        // The dialog only saves a gateway it reached, and nothing else is on
        // screen, so show it rather than making the user pick it again.
        if (wasIdle && _connections.isNotEmpty) {
          _selectConnection(_connections.first);
        }
      },
    );
  }

  /// Re-reads the store after a connection was added, edited or deleted.
  void _connectionsChanged() {
    final connections = widget.connManager.getConnections();
    final active = _connection;
    final updated = active == null
        ? null
        : connections.where((c) => c.id == active.id).firstOrNull;
    var rebound = false;
    setState(() {
      _connections = connections;
      if (active == null) return;
      if (updated == null) {
        // The gateway on screen was deleted.
        _idleWithoutConnection();
        return;
      }
      // Comparing the stored form keeps an edit to some *other* gateway from
      // tearing down the one on screen.
      if (jsonEncode(updated.toMap()) != jsonEncode(active.toMap())) {
        _bindConnection(updated);
        rebound = true;
      }
    });
    if (rebound && _client != null) _checkHealth();
  }

  Future<void> _checkHealth() async {
    final client = _client;
    if (client == null) return;
    setState(() => _healthChecking = true);
    final ok = await client.healthCheck();
    if (!mounted) return;
    setState(() {
      _healthOk = ok;
      _healthChecking = false;
    });
    if (ok) _fetchSessions();
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  Future<void> _fetchSessions() async {
    final client = _client;
    if (client == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sessions = await client.getSessions();
      if (!mounted) return;
      final prefs = await SharedPreferences.getInstance();
      final key = 'excluded_session_sources_${_conn.id}';
      final excluded = prefs.getStringList(key) ?? [];
      final filtered = sessions
          .where((s) => !excluded.contains(s.source))
          .toList();
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
    final client = _client;
    if (client == null) return;
    if (_deletingSessionIds.contains(session.id)) return;
    setState(() => _deletingSessionIds.add(session.id));

    try {
      await client.deleteSession(session.id);
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
    setState(() {
      _selectedSession = session;
      _selectedNavKey = null;
      _selectedBot = null;
    });
  }

  /// Opens a bot's canonical chat. It runs on the dashboard gateway socket
  /// rather than this screen's connection, so it needs no per-bot credentials.
  void _openBotChat(BotProfile bot) {
    setState(() {
      _selectedBot = bot;
      _selectedSession = null;
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

  void _openNav(String key) {
    setState(() {
      _selectedNavKey = key;
      _selectedBot = null;
    });
  }

  /// Switches which list is on show. On a narrow screen the list and the
  /// selection share one column, so the selection has to give way — otherwise
  /// tapping the rail would look like nothing happened.
  void _openList(_PanelList list) {
    final collapseSelection = !_panelPinned;
    setState(() {
      _panelListChoice = list;
      _selectedNavKey = null;
      if (collapseSelection) {
        _selectedSession = null;
        _selectedBot = null;
      }
    });
  }

  Widget _navScreen(String key, {required bool embedded}) {
    switch (key) {
      case 'memory':
        return MemoryScreen(connection: _conn, embedded: embedded);
      case 'cron':
        return CronScreen(connection: _conn, embedded: embedded);
      case 'skills':
        return SkillsScreen(connection: _conn, embedded: embedded);
      default:
        return SettingsScreen(connection: _conn, embedded: embedded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasConnection = _connection != null;

    // Wide: the list column sits beside the main pane. Narrow: one column,
    // showing the list until something is picked. Keeping them one shape is
    // why selecting never pushes a route.
    final panelPinned = _panelPinned;

    // On one column the list and the selection share the pane, so system back
    // returns to the list instead of leaving the app.
    return PopScope(
      canPop: panelPinned || !_hasSelection,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          _selectedNavKey = null;
          _selectedSession = null;
          _selectedBot = null;
        });
      },
      child: AuroraScaffold(
        // The HERMES bar belongs to the entry screen. Once a gateway is open
        // every pane carries its own header — chat, Memory, Cron, Skills and
        // Settings all have one — so a second bar above them only cost height.
        appBar: hasConnection
            ? null
            : AppBar(
                title: Text(
                  'HERMES',
                  style: hermesBrandTextStyle(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 8,
                    fontSize: 19,
                  ),
                ),
                centerTitle: true,
              ),
        // The roster is the main pane while no gateway is selected, so that is
        // when adding one belongs on the FAB.
        floatingActionButton: hasConnection
            ? null
            : GradientOrbButton(
                icon: Icons.add,
                size: 58,
                tooltip: 'Add Connection',
                onPressed: _addConnection,
              ),
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (panelPinned) ...[
              SizedBox(
                width: _listColumnWidth,
                child: _buildListColumn(pinned: true),
              ),
              const VerticalDivider(width: 1, thickness: 1),
            ],
            Expanded(
              child: panelPinned || _hasSelection
                  ? _buildDetailPane()
                  : _buildListColumn(pinned: false),
            ),
          ],
        ),
      ),
    );
  }

  /// The list column: which gateway is on screen, and the list it is showing
  /// (gateways, sessions or bots).
  ///
  /// Pinned beside the main pane on wide screens, and the main pane itself on
  /// narrow ones — one tree either way, only denser when it is 256dp wide.
  Widget _buildListColumn({required bool pinned}) {
    final browsingGateways = _panelList == _PanelList.gateways;
    // A pinned column on a phone-width screen (the Fold's cover screen) has
    // ~205 of 475dp to work with, so it drops to labels only.
    final minimal = pinned && !Responsive.isTablet(context);
    return Material(
      // Translucent so the aurora keeps flowing behind the column.
      color: pinned
          ? HermesGlass.fill(Theme.of(context).brightness)
          : Colors.transparent,
      child: SafeArea(
        child: Column(
          children: [
            _buildGatewayHeader(minimal: minimal),
            const Divider(height: 1),
            if (browsingGateways)
              Expanded(
                child: ConnectionListView(
                  connManager: widget.connManager,
                  connections: _connections,
                  activeId: _connection?.id,
                  compact: pinned,
                  minimal: minimal,
                  onSelect: _selectConnection,
                  onChanged: _connectionsChanged,
                ),
              )
            else ...[
              _buildListTabs(),
              if (!_panelShowsBots && _hasGateway)
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
                        // Keyed by gateway so switching one reloads the roster.
                        key: ValueKey('bots-${_conn.id}'),
                        connection: _conn,
                        selectedBotName: _selectedBot?.name,
                        compact: pinned,
                        minimal: minimal,
                        onOpenChat: _openBotChat,
                      )
                    : _buildBody(inPanel: pinned, minimal: minimal),
              ),
            ],
            // The dashboard destinations sit under the list, in this same
            // column — there is no rail or drawer left to hold them.
            if (_connection != null) ...[
              const Divider(height: 1),
              ..._navTiles(),
            ],
          ],
        ),
      ),
    );
  }

  /// Bot / Ses switch over the list.
  ///
  /// Only the selected side spells its name out — `Bot | S` or `B | Ses`. Two
  /// full labels wrapped onto a second line even in the 205dp column, and the
  /// unselected one is the label that can afford to shrink.
  Widget _buildListTabs() {
    final showsBots = _panelShowsBots;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: SegmentedButton<bool>(
        segments: [
          ButtonSegment(
            value: true,
            label: Text(showsBots ? 'Bot' : 'B', maxLines: 1, softWrap: false),
          ),
          ButtonSegment(
            value: false,
            label: Text(showsBots ? 'S' : 'Ses', maxLines: 1, softWrap: false),
          ),
        ],
        selected: {_panelShowsBots},
        showSelectedIcon: false,
        onSelectionChanged: (selection) =>
            _openList(selection.first ? _PanelList.bots : _PanelList.sessions),
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
      ),
    );
  }

  /// Memory / Cron / Skills / Settings, dense so they take as little height
  /// from the list as possible.
  List<Widget> _navTiles() {
    final scheme = Theme.of(context).colorScheme;

    Widget tile(String key, IconData icon, String label) {
      final selected = _selectedNavKey == key;
      return ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        horizontalTitleGap: 10,
        minLeadingWidth: 0,
        leading: Icon(
          icon,
          size: 19,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        ),
        title: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        selected: selected,
        onTap: () => _openNav(key),
      );
    }

    return [
      tile('memory', Icons.memory, 'Memory'),
      tile('cron', Icons.schedule, 'Cron Jobs'),
      tile('skills', Icons.auto_awesome, 'Skills'),
      tile('settings', Icons.settings, 'Settings'),
    ];
  }

  /// Column header: the gateway the shell is on, and the way to swap it.
  ///
  /// Tapping it turns the column into the gateway roster in place — the picker
  /// is a mode of this column, not a screen above it.
  Widget _buildGatewayHeader({required bool minimal}) {
    final theme = Theme.of(context);
    final conn = _connection;

    if (_panelList == _PanelList.gateways) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
        child: Row(
          children: [
            if (conn != null)
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                tooltip: 'Back to ${conn.label}',
                onPressed: () => setState(
                  () => _panelListChoice = conn.hasGateway
                      ? _PanelList.sessions
                      : _PanelList.bots,
                ),
              )
            else
              const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Gateways',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // While no gateway is selected the FAB carries this, so the two
            // never both appear.
            if (conn != null)
              IconButton(
                icon: const Icon(Icons.add, size: 20),
                tooltip: 'Add Connection',
                onPressed: _addConnection,
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      );
    }

    return InkWell(
      onTap: () => setState(() => _panelListChoice = _PanelList.gateways),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: hermesAccentGradient,
                boxShadow: hermesGlow(hermesMagenta, alpha: 0.32, blur: 14),
              ),
              child: const Icon(Icons.router, color: Colors.white, size: 15),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _conn.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (!minimal) ...[
                    const SizedBox(height: 2),
                    Text(
                      connectionAddressLine(_conn),
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
            // The app bar used to carry this; the header is where an
            // unreachable gateway belongs anyway.
            if (_hasGateway && !_healthOk)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Tooltip(
                  message: 'Gateway API Server unreachable',
                  child: Icon(
                    Icons.warning_amber,
                    color: hermesAlert,
                    size: 17,
                  ),
                ),
              ),
            Icon(
              Icons.unfold_more,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// Main pane: the gateway roster while none is selected, otherwise a nav
  /// destination, the selected chat, or a placeholder.
  Widget _buildDetailPane() {
    if (_connection == null) {
      // The roster is in the column beside this pane, so the pane points at it
      // rather than listing the same gateways twice.
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: HermesHeader(
            orbSize: 140,
            subtitle: _connections.isEmpty
                ? 'Add a gateway with the + button'
                : 'Pick a gateway from the list',
          ),
        ),
      );
    }
    final navKey = _selectedNavKey;
    if (navKey != null) {
      // Keyed so switching destinations — or gateways — rebuilds the state.
      return KeyedSubtree(
        key: ValueKey('nav-$navKey-${_conn.id}'),
        child: _navScreen(navKey, embedded: true),
      );
    }
    final bot = _selectedBot;
    if (bot != null) {
      return BotChatScreen(
        key: ValueKey('bot-${_conn.id}-${bot.name}'),
        connection: _conn,
        bot: bot,
      );
    }
    final selected = _selectedSession;
    if (selected == null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: HermesHeader(
            orbSize: 140,
            subtitle: _hasGateway
                ? 'Pick a session from the list or start a new chat'
                : 'Pick a bot from the list to open its chat',
          ),
        ),
      );
    }
    // Keyed by gateway + session so switching either rebuilds the chat state.
    return ChatScreen(
      key: ValueKey('${_conn.id}-${selected.id}'),
      connection: _conn,
      session: selected,
      embedded: true,
    );
  }

  Widget _buildBody({bool inPanel = false, bool minimal = false}) {
    if (!_hasGateway) {
      return const StatusView.empty(
        icon: Icons.forum_outlined,
        title: 'No Gateway API Server',
        message:
            'Sessions come from the Gateway API Server (port 8642). Add its '
            'port and API key to this connection to see them — Bots and the '
            'dashboard screens work without it.',
      );
    }

    if (!_healthOk) {
      if (_healthChecking) {
        return StatusView.loading(
          message: 'Connecting to ${_conn.gatewayBaseUrl}...',
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
                          // The message count is the first thing to go where
                          // the column is 144dp wide: the model and the time
                          // are what tell two sessions apart.
                          minimal
                              ? '${session.model} \u2022 '
                                    '${_formatTime(session.startedAt)}'
                              : '${session.messageCount} msgs \u2022 '
                                    '${session.model} \u2022 '
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
