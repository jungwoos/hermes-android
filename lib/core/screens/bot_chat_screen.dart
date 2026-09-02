// A bot's canonical conversation, over the dashboard gateway socket.
//
// Separate from ChatScreen because the transport is different: that screen
// talks REST + SSE to one profile's API server with that profile's key, while
// a bot is reached through the dashboard's JSON-RPC socket, where a single
// dashboard session covers every profile. The conversation itself is the same
// row the desktop opens, so both clients write one history.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../services/bot_gateway.dart';
import '../services/connection_manager.dart';
import '../services/rpc_client.dart';
import '../theme.dart';
import '../utils/agent_notice.dart';
import '../utils/responsive.dart';
import '../utils/streaming_buffer.dart';
import '../widgets/aurora.dart';
import '../widgets/glass.dart';
import '../widgets/status_view.dart';

class BotChatScreen extends StatefulWidget {
  const BotChatScreen({required this.connection, required this.bot, super.key});

  final SavedConnection connection;
  final BotProfile bot;

  @override
  State<BotChatScreen> createState() => _BotChatScreenState();
}

class _BotChatScreenState extends State<BotChatScreen>
    with WidgetsBindingObserver {
  BotGateway? _gateway;
  DashboardClient? _dashboard;
  Timer? _poll;

  /// Last size the host reported, so a desktop turn is noticed without
  /// re-reading the whole transcript every few seconds.
  int? _knownMessageCount;

  /// How often the transcript is checked for changes made elsewhere. The
  /// gateway delivers turn events to one client only — whoever submitted —
  /// so a conversation the desktop is driving has to be polled for.
  static const _pollInterval = Duration(seconds: 6);

  /// How long a submitted turn may stay silent before the composer stops
  /// waiting on it. Events can be delivered to another client, or the socket
  /// can go quiet, and an in-flight turn that never lands leaves the spinner
  /// running for good — which reads as the app hanging.
  static const _turnTimeout = Duration(seconds: 120);
  Timer? _turnWatchdog;
  final _messages = <BotMessage>[];
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  String? _sessionId;

  /// The id the gateway accepted for turns, which can be the compression tip
  /// rather than the row the transcript was read from.
  String? _attachedSessionId;

  /// What the last failed resume tried, and what the host said it has — the
  /// detail that turns "session not found" into something diagnosable.
  List<String> _resumeAttempts = const [];
  List<_HostSession> _hostRows = const [];
  bool _loading = true;
  String? _error;
  bool _sending = false;

  /// Tokens for the in-flight reply. Bound to a single bubble so a streaming
  /// turn does not rebuild the whole transcript per token.
  StreamingBuffer? _streaming;

  /// How far from the end still counts as "reading the latest turn".
  static const double _atBottomSlack = 200;

  /// Keyboard height at the last dependency change, so [didChangeDependencies]
  /// can tell an opening IME from a closing one.
  double _keyboardInset = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app is the moment a stale transcript is most
    // obvious, and polling is suspended while backgrounded.
    if (state == AppLifecycleState.resumed) _refreshIfChanged();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _turnWatchdog?.cancel();
    _streaming?.dispose();
    _textController.dispose();
    _scrollController.dispose();
    _gateway?.close();
    _dashboard?.close();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final sessionId = widget.bot.canonicalSessionId;
    if (sessionId == null) {
      setState(() => _loading = false);
      return;
    }
    final dashboard = _dashboard ?? _newDashboard();
    try {
      // Read-only: viewing a bot must not attach its session, or a turn the
      // user is running on the desktop would have its events diverted here.
      final rows = await dashboard.getBotSessionMessages(
        sessionId,
        widget.bot.name,
      );
      final meta = await dashboard.getBotSessionMeta(
        sessionId,
        widget.bot.name,
      );
      if (!mounted) return;
      setState(() {
        _dashboard = dashboard;
        _sessionId = sessionId;
        _knownMessageCount = (meta['message_count'] as num?)?.toInt();
        _messages
          ..clear()
          ..addAll(
            rows
                .whereType<Map<String, dynamic>>()
                .map(BotMessage.fromRest)
                .where((m) => m.text.trim().isNotEmpty),
          );
        _loading = false;
      });
      _scrollToBottom();
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeBotFailure(e);
        _loading = false;
      });
    }
  }

  DashboardClient _newDashboard() => DashboardClient(
    host: widget.connection.host,
    port: widget.connection.dashboardPort,
    pathPrefix: widget.connection.dashboardPrefix ?? '',
    proxied: widget.connection.dashboardProxied,
    useHttps: widget.connection.useHttps,
    username: widget.connection.dashboardUsername,
    password: widget.connection.dashboardPassword,
  );

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(_pollInterval, (_) => _refreshIfChanged());
  }

  /// Reloads the transcript when the host says it grew. Skipped while our own
  /// turn is streaming — those tokens are already arriving live, and swapping
  /// the list underneath them would drop the partial reply.
  Future<void> _refreshIfChanged() async {
    final dashboard = _dashboard;
    final sessionId = _sessionId;
    if (dashboard == null || sessionId == null || _loading) return;
    // Tokens arriving live are the better copy — swapping the list underneath
    // them would drop the partial reply. A turn that is in flight but silent
    // is polled for, though: its events may have gone to another client, and
    // the host's transcript is then the only place the reply exists.
    if (_streaming?.text.isNotEmpty ?? false) return;
    try {
      final meta = await dashboard.getBotSessionMeta(
        sessionId,
        widget.bot.name,
      );
      final count = (meta['message_count'] as num?)?.toInt();
      if (count == null || count == _knownMessageCount) return;
      final rows = await dashboard.getBotSessionMessages(
        sessionId,
        widget.bot.name,
      );
      if (!mounted) return;
      setState(() {
        _knownMessageCount = count;
        _messages
          ..clear()
          ..addAll(
            rows
                .whereType<Map<String, dynamic>>()
                .map(BotMessage.fromRest)
                .where((m) => m.text.trim().isNotEmpty),
          );
        // The host recorded the turn while we were still waiting on events
        // that never came: the transcript is the answer, so stop waiting.
        if (_sending) _endWait();
      });
      _scrollToBottom();
    } catch (_) {
      // A failed poll is not worth interrupting a readable transcript for.
    }
  }

  void _onEvent(RpcEvent event) {
    if (!mounted) return;
    switch (event.method) {
      case 'message.delta':
        final text = event.params['text'];
        if (text is String) _streaming?.append(text);
      case 'message.complete':
      case 'turn.end':
        _finishTurn(event.params['text'] as String?);
      case 'turn.error':
        _finishTurn(null);
        showAppSnackBar(
          context,
          'Turn failed: ${event.params['message'] ?? 'unknown error'}',
          isError: true,
        );
    }
  }

  /// Clears the in-flight turn state. Callers are inside `setState`.
  void _endWait() {
    _turnWatchdog?.cancel();
    _turnWatchdog = null;
    _streaming?.dispose();
    _streaming = null;
    _sending = false;
  }

  void _finishTurn(String? finalText) {
    final buffer = _streaming;
    if (buffer == null) return;
    _turnWatchdog?.cancel();
    _turnWatchdog = null;
    final text = (finalText?.trim().isNotEmpty ?? false)
        ? finalText!
        : buffer.text;
    setState(() {
      _streaming = null;
      _sending = false;
      if (text.trim().isNotEmpty) {
        _messages.add(BotMessage(role: 'assistant', text: text));
      }
    });
    buffer.dispose();
    _scrollToBottom();
    // The host has now persisted the turn, including any tool rows the
    // stream did not carry; take that as the record.
    _refreshIfChanged();
  }

  /// Connects and opens the session, the first time the user sends.
  Future<BotGateway> _ensureAttached(String sessionId) async {
    final existing = _gateway;
    if (existing != null) return existing;
    final dashboard = _dashboard ?? _newDashboard();
    final gateway = await BotGateway.connect(dashboard);
    final attached = await _resume(gateway, sessionId);
    // This chat only — the socket also carries turns the host runs for other
    // bots — but under every id that can name it, so our own reply is never
    // the thing that gets filtered out.
    gateway
        .eventsForAny({
          sessionId,
          attached,
          ?widget.bot.canonicalSessionId,
          ?widget.bot.resolvedSessionId,
        })
        .listen(_onEvent);
    if (!mounted) {
      await gateway.close();
      throw StateError('screen closed');
    }
    setState(() {
      _dashboard = dashboard;
      _gateway = gateway;
      _attachedSessionId = attached;
    });
    return gateway;
  }

  /// Resumes the bot's chat, working through the ids that can name it.
  ///
  /// The roster carries the row the desktop pinned and the tip of its
  /// compression lineage; either can be the one the gateway will take, and a
  /// stale pointer takes neither. When both are refused, the host is asked
  /// over REST which sessions the profile actually has — that read works even
  /// while the socket cannot resume — and only rows titled like a bot chat are
  /// tried, so a turn can never land in an unrelated conversation.
  Future<String> _resume(BotGateway gateway, String sessionId) async {
    final tried = <String>[];
    Object? failure;

    Future<String?> attempt(String? id) async {
      if (id == null || id.isEmpty || tried.contains(id)) return null;
      tried.add(id);
      try {
        // The gateway answers with the row it opened, which is what a turn has
        // to be submitted against.
        return await gateway.attach(id, widget.bot.name);
      } catch (e) {
        failure = e;
        if (!_isMissingSession(e)) rethrow;
        return null;
      }
    }

    final pinned = await attempt(sessionId);
    if (pinned != null) return pinned;
    final tip = await attempt(widget.bot.resolvedSessionId);
    if (tip != null) return tip;

    for (final row in await _hostBotChatRows()) {
      final found = await attempt(row.id);
      if (found != null) return found;
    }

    _resumeAttempts = tried;
    throw failure ?? StateError('session not found');
  }

  static bool _isMissingSession(Object error) =>
      error.toString().contains('session not found');

  /// Rows the host lists for this profile that look like its bot chat, newest
  /// first. Never returns other conversations: guessing one would submit the
  /// user's turn into it.
  Future<List<_HostSession>> _hostBotChatRows() async {
    final dashboard = _dashboard;
    if (dashboard == null) return const [];
    try {
      final rows = await dashboard.getProfileSessions(widget.bot.name);
      _hostRows = [
        for (final row in rows)
          _HostSession(
            id: (row['id'] ?? row['session_id'] ?? '').toString(),
            title: (row['title'] ?? '').toString(),
          ),
      ].where((row) => row.id.isNotEmpty).toList();
      return _hostRows
          .where((row) => row.title.toLowerCase().contains('bot chat'))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    final sessionId = _sessionId;
    if (text.isEmpty || sessionId == null || _sending) return;
    _textController.clear();
    final buffer = StreamingBuffer();
    setState(() {
      _sending = true;
      _streaming = buffer;
      _messages.add(BotMessage(role: 'user', text: text));
    });
    _scrollToBottom();
    try {
      final gateway = await _ensureAttached(sessionId);
      await gateway.submit(_attachedSessionId ?? sessionId, text);
      _turnWatchdog?.cancel();
      _turnWatchdog = Timer(_turnTimeout, _abandonTurn);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _turnWatchdog?.cancel();
        _turnWatchdog = null;
        _sending = false;
        _streaming = null;
        _messages.removeLast();
      });
      buffer.dispose();
      final detail = await _diagnoseSendFailure(e);
      if (!mounted) return;
      // A snack bar clips a multi-line explanation, and the raw error is the
      // part that identifies an unfamiliar failure — so it gets a way out.
      showAppSnackBar(
        context,
        detail.split('\n').first,
        isError: true,
        action: SnackBarAction(
          label: 'Details',
          onPressed: () => _showFailureDetail(detail),
        ),
      );
    }
  }

  /// Explains a failed turn, asking the host why when the answer is one only
  /// it can give.
  ///
  /// A transcript is read straight from a profile's store, but a *turn* has to
  /// run inside the gateway process — which only fronts every profile when
  /// multiplexing is on. Without it, the gateway can only resume sessions
  /// belonging to the profile it is currently scoped to, and every other bot
  /// answers "session not found".
  Future<String> _diagnoseSendFailure(Object error) async {
    final raw = error.toString();
    final dashboard = _dashboard;
    if (dashboard == null || !raw.contains('session not found')) {
      return describeBotFailure(error);
    }
    final facts = <String>[];
    try {
      final multiplex = await dashboard.isMultiplexEnabled();
      final profiles = await dashboard.getActiveProfile();
      final current = (profiles['current'] ?? profiles['active'])?.toString();
      facts.add('multiplex: $multiplex');
      facts.add('gateway profile: ${current ?? 'unknown'}');
      if (!multiplex && current != null && current != widget.bot.name) {
        return "The host's gateway is scoped to the '$current' profile and is "
            "not multiplexed, so a turn for '${widget.bot.name}' cannot run "
            'from here — reading its history still works. Enable '
            'gateway.multiplex_profiles on the host, or open this bot on the '
            'desktop.\n\n$raw';
      }
    } catch (_) {
      facts.add(
        'the host would not answer /api/config or /api/profiles/active',
      );
    }
    // Neither the roster's ids nor anything the host lists could be resumed.
    // Name them: it is the difference between a stale pointer and a session
    // the host really has lost.
    final rows = _hostRows.isEmpty
        ? (_resumeAttempts.isEmpty ? 'not queried' : 'none listed')
        : _hostRows.take(6).map((row) => '${row.id} (${row.title})').join(', ');
    return '${describeBotFailure(error)}\n\n'
        'profile: ${widget.bot.name}\n'
        'resume tried: ${_resumeAttempts.isEmpty ? '-' : _resumeAttempts.join(', ')}\n'
        'host sessions: $rows\n'
        '${facts.join('\n')}';
  }

  void _showFailureDetail(String detail) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Could not send'),
        content: SingleChildScrollView(
          child: SelectableText(detail, style: const TextStyle(fontSize: 13)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Stops waiting on a turn that never reported back, and looks for it in the
  /// host's transcript instead.
  void _abandonTurn() {
    if (!mounted || !_sending) return;
    if (_streaming?.text.isNotEmpty ?? false) return; // still streaming
    setState(_endWait);
    showAppSnackBar(
      context,
      'No reply reached this device. Checking the host for it…',
      isError: true,
    );
    _refreshIfChanged();
  }

  /// Brings the newest turn back into view. The list is reversed, so that is
  /// offset zero — and a jump, never an animation.
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.minScrollExtent);
    });
  }

  /// True while the newest turn is on screen. Reversed geometry: the newest
  /// row sits at offset zero, and a list with no viewport yet counts as there.
  bool get _isAtBottom =>
      !_scrollController.hasClients ||
      _scrollController.position.pixels <=
          _scrollController.position.minScrollExtent + _atBottomSlack;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The keyboard shrinks the viewport under the transcript. The composer
    // rises with it (Scaffold handles that), but the list keeps its offset, so
    // the turn the user was reading would slide out of sight behind the
    // composer. Follow the end instead, on every metrics step of the IME
    // animation.
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final opening = inset > _keyboardInset;
    // Read before the new metrics are laid out, so this is where the user was.
    final followEnd = _isAtBottom;
    _keyboardInset = inset;
    if (opening && followEnd) _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    return AuroraScaffold(
      intensity: 0.65,
      // No bar: the list column beside this pane already names the bot and
      // highlights it, and the transcript polls itself so there is nothing to
      // reload by hand.
      body: SafeArea(
        // With no bar of its own the transcript is what sits under the status
        // bar; the composer carries the bottom inset already.
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: Responsive.isTablet(context) ? 800 : double.infinity,
            ),
            child: Column(
              children: [
                Expanded(child: _buildBody()),
                if (_error == null && !_loading) _buildComposer(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return StatusView.loading(message: 'Opening ${widget.bot.label}…');
    }
    if (_error != null) {
      return StatusView.error(
        title: 'Could not open this bot',
        message: _error!,
        onRetry: _open,
      );
    }
    if (_sessionId == null) {
      // The desktop mints a bot's forever-chat and pins its identity by name;
      // starting one here would fork it instead of joining it.
      return StatusView.empty(
        icon: Icons.smart_toy_outlined,
        title: 'No conversation yet',
        message:
            'Open ${widget.bot.label} on the desktop once to start its chat. '
            'It will appear here afterwards.',
      );
    }

    final streaming = _streaming;
    final count = _messages.length + (streaming == null ? 0 : 1);

    // Reversed, so the viewport's zero offset *is* the newest row: the
    // transcript opens on the last turn with no scroll to perform, where
    // jumping after the first frame showed a visible snap down the list.
    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: count,
      itemBuilder: (context, reversedIndex) {
        final index = count - 1 - reversedIndex;
        if (index == _messages.length && streaming != null) {
          return AnimatedBuilder(
            animation: streaming,
            builder: (context, _) => streaming.text.isEmpty
                ? const SizedBox.shrink()
                : _BotBubble(
                    message: BotMessage(
                      role: 'assistant',
                      text: streaming.text,
                    ),
                  ),
          );
        }
        return _BotBubble(message: _messages[index]);
      },
    );
  }

  Widget _buildComposer() {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(HermesRadius.pill),
            color: HermesGlass.fill(theme.brightness),
            border: Border.all(color: HermesGlass.stroke(theme.brightness)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 16, right: 10),
                  child: TextField(
                    controller: _textController,
                    decoration: const InputDecoration(
                      hintText: 'Ask anything…',
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                      isDense: true,
                    ),
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.send,
                    enabled: !_sending,
                    onSubmitted: (_) => _send(),
                  ),
                ),
              ),
              if (_sending)
                const SizedBox(
                  width: 44,
                  height: 44,
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                GradientOrbButton(
                  icon: Icons.arrow_upward_rounded,
                  size: 44,
                  tooltip: 'Send',
                  onPressed: _send,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BotBubble extends StatelessWidget {
  const _BotBubble({required this.message});

  final BotMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == 'user';

    // Bot Mode: a delivery from another agent rides the user role without a
    // human typing it, so it must not render as the user's own bubble.
    if (isUser) {
      final notice = parseAgentNotice(message.text);
      if (notice != null) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(
            '🤖 ${notice.headline}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
      }
    }

    if (message.role == 'tool') {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: HermesGlass.fill(theme.brightness),
            borderRadius: BorderRadius.circular(HermesRadius.pill),
            border: Border.all(color: HermesGlass.stroke(theme.brightness)),
          ),
          child: Text(
            '🔧 ${message.text}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    final bubble = Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        gradient: isUser ? hermesAccentGradient : null,
        color: isUser ? null : HermesGlass.fill(theme.brightness),
        border: isUser
            ? null
            : Border.all(color: HermesGlass.stroke(theme.brightness)),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(HermesRadius.card),
          topRight: const Radius.circular(HermesRadius.card),
          bottomLeft: Radius.circular(isUser ? HermesRadius.card : 6),
          bottomRight: Radius.circular(isUser ? 6 : HermesRadius.card),
        ),
        boxShadow: isUser
            ? hermesGlow(hermesMagenta, alpha: 0.28, blur: 22)
            : null,
      ),
      child: MarkdownBody(
        data: message.text,
        styleSheet: MarkdownStyleSheet(
          p: theme.textTheme.bodyMedium?.copyWith(
            color: isUser ? Colors.white : theme.colorScheme.onSurface,
          ),
          code: TextStyle(
            fontFamily: 'monospace',
            backgroundColor: (isUser ? Colors.white : Colors.black).withValues(
              alpha: 0.12,
            ),
            color: isUser ? Colors.white : null,
          ),
          a: TextStyle(
            color: isUser ? Colors.white70 : theme.colorScheme.primary,
          ),
        ),
      ),
    );

    return Row(
      mainAxisAlignment: isUser
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isUser) const SizedBox(width: 48),
        Flexible(child: bubble),
        if (!isUser) const SizedBox(width: 48),
      ],
    );
  }
}

/// One session as the host lists it, for the resume fallback and the failure
/// detail.
class _HostSession {
  const _HostSession({required this.id, required this.title});

  final String id;
  final String title;
}
