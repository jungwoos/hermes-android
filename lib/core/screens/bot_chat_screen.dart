// A bot's canonical conversation, over the dashboard gateway socket.
//
// Separate from ChatScreen because the transport is different: that screen
// talks REST + SSE to one profile's API server with that profile's key, while
// a bot is reached through the dashboard's JSON-RPC socket, where a single
// dashboard session covers every profile. The conversation itself is the same
// row the desktop opens, so both clients write one history.
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
  const BotChatScreen({
    required this.connection,
    required this.bot,
    this.embedded = false,
    super.key,
  });

  final SavedConnection connection;
  final BotProfile bot;

  /// Rendered inside the split-view detail pane, so no back button.
  final bool embedded;

  @override
  State<BotChatScreen> createState() => _BotChatScreenState();
}

class _BotChatScreenState extends State<BotChatScreen> {
  BotGateway? _gateway;
  DashboardClient? _dashboard;
  final _messages = <BotMessage>[];
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  String? _sessionId;
  bool _loading = true;
  String? _error;
  bool _sending = false;

  /// Tokens for the in-flight reply. Bound to a single bubble so a streaming
  /// turn does not rebuild the whole transcript per token.
  StreamingBuffer? _streaming;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
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
      final chat = await gateway.openCanonicalChat(widget.bot);
      if (!mounted) {
        await gateway.close();
        dashboard.close();
        return;
      }
      gateway.events.listen(_onEvent);
      setState(() {
        _dashboard = dashboard;
        _gateway = gateway;
        _sessionId = chat?.sessionId;
        _messages
          ..clear()
          ..addAll(chat?.messages ?? const []);
        _loading = false;
      });
      _scrollToBottom();
    } catch (e) {
      dashboard.close();
      if (!mounted) return;
      setState(() {
        _error = describeBotFailure(e);
        _loading = false;
      });
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

  void _finishTurn(String? finalText) {
    final buffer = _streaming;
    if (buffer == null) return;
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
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    final gateway = _gateway;
    final sessionId = _sessionId;
    if (text.isEmpty || gateway == null || sessionId == null || _sending) {
      return;
    }
    _textController.clear();
    final buffer = StreamingBuffer();
    setState(() {
      _sending = true;
      _streaming = buffer;
      _messages.add(BotMessage(role: 'user', text: text));
    });
    _scrollToBottom();
    try {
      await gateway.submit(sessionId, text);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _streaming = null;
        _messages.removeLast();
      });
      buffer.dispose();
      showAppSnackBar(context, 'Send failed: $e', isError: true);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AuroraScaffold(
      intensity: 0.65,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: BrandPill(label: widget.bot.label, icon: Icons.smart_toy),
        actions: [
          FaintIconButton(
            icon: Icons.refresh,
            tooltip: 'Reload conversation',
            onPressed: _loading ? null : _open,
          ),
        ],
      ),
      body: Center(
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

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: count,
      itemBuilder: (context, index) {
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
