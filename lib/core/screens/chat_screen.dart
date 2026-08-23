// Chat screen with real-time streaming via REST API.
// Uses REST endpoints: POST /api/sessions/{id}/chat and
// GET /api/sessions/{id}/messages.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/connection_manager.dart';
import '../theme.dart';
import '../utils/agent_notice.dart';
import '../utils/message_content.dart';
import '../utils/responsive.dart';
import '../utils/streaming_buffer.dart';
import '../widgets/aurora.dart';
import '../widgets/glass.dart';
import '../widgets/plasma_orb.dart';
import '../widgets/status_view.dart';

class ChatScreen extends StatefulWidget {
  final SavedConnection connection;
  final Session session;

  /// When true the screen is rendered inside a split-view detail pane
  /// (pinned side panel layout) rather than pushed as its own route, so it
  /// must not show a back button.
  final bool embedded;

  const ChatScreen({
    required this.connection,
    required this.session,
    this.embedded = false,
    super.key,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  List<Map<String, dynamic>> _messages = [];
  final List<Map<String, dynamic>> _toolMessages = [];
  bool _loading = true;
  String? _error;
  late final ApiClient _client;
  late final GatewayChatClient _gateway;

  // Chat sending state
  final _textController = TextEditingController();
  bool _sending = false;
  bool _streaming = false;
  // Holds the in-flight assistant reply while streaming. Tokens are
  // appended here (not via setState) so only the bubble bound to this
  // buffer rebuilds, instead of the whole message list.
  StreamingBuffer? _streamingBuffer;

  // Voice input / spoken replies
  final SpeechToText _speechToText = SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();
  bool _speechAvailable = false;
  bool _listening = false;
  // Replies are spoken whenever the message was dictated. There is no longer
  // a mute control in the composer, so this is no longer user-configurable.
  bool _awaitingVoiceReply = false;
  String? _voiceStatus;
  String? _sttLocaleId;

  // Verbose mode
  bool _verboseMode = false;

  // Scroll management
  final _scrollController = ScrollController();
  bool _showScrollToBottom = false;
  double _lastPixels = 0;
  static final Map<String, double> _savedPositions = {};

  @override
  void initState() {
    super.initState();
    _client = ApiClient(
      baseUrl: widget.connection.baseUrl,
      apiKey: widget.connection.apiKey,
      pathPrefix: widget.connection.gatewayPrefix ?? '',
    );
    _gateway = GatewayChatClient(_client);
    _fetchMessages();
    _loadVerboseMode();
    _initVoice();
    _scrollController.addListener(_onScroll);
  }

  Future<void> _loadVerboseMode() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _verboseMode = prefs.getBool('verbose_mode') ?? false);
  }

  @override
  void dispose() {
    _savedPositions[widget.session.id] = _lastPixels;
    _speechToText.cancel();
    _flutterTts.stop();
    _client.close();
    _textController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _streamingBuffer?.dispose();
    super.dispose();
  }

  Future<void> _initVoice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final voiceName = prefs.getString('voice_name');
      final voiceLocale = prefs.getString('voice_locale');

      if (voiceName != null && voiceName.isNotEmpty) {
        if (voiceName == voiceLocale) {
          await _flutterTts.setLanguage(voiceName);
        } else {
          await _flutterTts.setVoice({
            'name': voiceName,
            'locale': voiceLocale ?? '',
          });
        }
        _sttLocaleId = voiceLocale?.replaceAll('-', '_');
      } else {
        _sttLocaleId = null;
      }
      await _flutterTts.setSpeechRate(0.48);
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);

      final available = await _speechToText.initialize(
        onStatus: _handleSpeechStatus,
        onError: _handleSpeechError,
      );
      if (!mounted) return;
      setState(() {
        _speechAvailable = available;
        _voiceStatus = available ? null : 'Speech recognition is unavailable';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _speechAvailable = false;
        _voiceStatus = 'Voice setup failed: $e';
      });
    }
  }

  void _handleSpeechStatus(String status) {
    if (!mounted) return;
    final listening = status == 'listening';
    setState(() {
      _listening = listening;
      if (!listening && status == 'done') {
        _voiceStatus = null;
      }
    });
  }

  void _handleSpeechError(SpeechRecognitionError error) {
    if (!mounted) return;
    setState(() {
      _listening = false;
      _voiceStatus = error.errorMsg;
    });
  }

  Future<void> _toggleVoiceInput() async {
    if (_streaming || _sending || _loading) return;
    if (_listening) {
      await _speechToText.stop();
      if (!mounted) return;
      setState(() => _listening = false);
      return;
    }

    if (!_speechAvailable) {
      await _initVoice();
      if (!_speechAvailable) {
        if (mounted) {
          showAppSnackBar(
            context,
            _voiceStatus ?? 'Speech recognition is unavailable',
          );
        }
        return;
      }
    }

    await _flutterTts.stop();
    if (!mounted) return;
    setState(() => _voiceStatus = 'Listening…');
    await _speechToText.listen(
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
        localeId: _sttLocaleId,
      ),
      onResult: _handleSpeechResult,
    );
  }

  void _handleSpeechResult(SpeechRecognitionResult result) {
    final recognised = result.recognizedWords.trim();
    if (recognised.isEmpty || !mounted) return;
    setState(() {
      _textController.text = recognised;
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
    });
    if (result.finalResult) {
      _sendMessage(speakResponse: true);
    }
  }

  Future<void> _speakAssistantText(String text) async {
    final spokenText = text.trim();
    if (spokenText.isEmpty) return;
    await _flutterTts.stop();
    await _flutterTts.speak(spokenText);
  }

  void _onScroll() {
    if (_scrollController.hasClients) {
      _lastPixels = _scrollController.position.pixels;
    }
    final atBottom =
        _scrollController.hasClients &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200;
    if (atBottom != !_showScrollToBottom && _streaming) {
      setState(() => _showScrollToBottom = !atBottom);
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _fetchMessages() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final messages = await _client.getMessages(widget.session.id);
      if (!mounted) return;
      _extractToolMessages(messages);
      setState(() {
        _messages = messages;
        _loading = false;
      });
      final saved = _savedPositions[widget.session.id];
      if (saved != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              saved.clamp(0.0, _scrollController.position.maxScrollExtent),
            );
          }
        });
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      final errStr = e.toString();
      if (errStr.contains('404') || errStr.contains('not found')) {
        setState(() {
          _messages = [];
          _loading = false;
        });
        return;
      }
      setState(() {
        _error = errStr;
        _loading = false;
      });
    }
  }

  void _extractToolMessages(List<Map<String, dynamic>> messages) {
    _toolMessages.clear();
    for (final msg in messages) {
      if (!isToolResultMessage(msg)) continue;

      final name =
          (msg['name'] as String?) ??
          (msg['tool_name'] as String?) ??
          (msg['toolCallName'] as String?) ??
          '';
      final toolCallId = (msg['tool_call_id'] as String?) ?? '';
      final content = messageContentToText(msg['content']);

      String toolName = name.isNotEmpty ? name : '';
      if (toolName.isEmpty && content.isNotEmpty) {
        final match = RegExp(r'source="([^"]+)"').firstMatch(content);
        if (match != null) toolName = match.group(1)!;
      }
      if (toolName.isEmpty) toolName = 'tool';

      final emoji = _toolEmoji(toolName);
      _toolMessages.add({
        'role': 'tool_progress',
        'content': '$emoji $toolName — done',
        'toolCallId': toolCallId,
        'status': 'completed',
        'tool': toolName,
      });
    }
  }

  String _toolEmoji(String toolName) {
    switch (toolName) {
      case 'browser_navigate':
      case 'browser_console':
      case 'browser':
        return '🌐';
      case 'read_file':
      case 'read':
        return '📄';
      case 'write_file':
      case 'write':
        return '✏️';
      case 'search':
      case 'google_search':
        return '🔍';
      case 'execute':
      case 'shell':
        return '💻';
      case 'think':
      case 'reasoning':
        return '🧠';
      default:
        return '🔧';
    }
  }

  /// Send message via SSE streaming (Gateway API Server).
  Future<void> _sendMessage({bool speakResponse = false}) async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    if (_sending || _streaming) return;

    _textController.text = '';
    _awaitingVoiceReply = speakResponse;

    // Build conversation history for SSE request
    final history = <Map<String, dynamic>>[];
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      history.add({'role': m['role'] ?? 'user', 'content': m['content'] ?? ''});
    }

    final streamingBuffer = StreamingBuffer();
    setState(() {
      _sending = true;
      _streaming = true;
      _showScrollToBottom = false;
      _streamingBuffer = streamingBuffer;
      _messages.add({'role': 'user', 'content': text});
      // Insert a placeholder streaming message
      _messages.add({'role': 'assistant', 'content': ''});
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    // Accumulate tokens into the streaming buffer directly (no setState) so
    // only the bubble listening to it rebuilds while tokens arrive.
    await _gateway.sendMessageStreaming(
      message: text,
      sessionId: widget.session.id,
      history: history,
      onToken: (token) {
        if (!mounted) return;
        streamingBuffer.append(token);
      },
      onToolProgress: (progress) {
        if (!mounted) return;
        _upsertToolProgress(progress);
      },
      onDone: () async {
        if (!mounted) return;
        streamingBuffer.complete();
        // Refresh messages to get the final server-side state
        try {
          final messages = await _client.getMessages(widget.session.id);
          if (!mounted) return;
          _extractToolMessages(messages);
          setState(() {
            _messages = messages;
            _streaming = false;
            _sending = false;
            _showScrollToBottom = false;
            _streamingBuffer = null;
          });
          streamingBuffer.dispose();
          if (_awaitingVoiceReply) {
            _awaitingVoiceReply = false;
            final assistant = messages.reversed.firstWhere(
              (message) => message['role'] == 'assistant',
              orElse: () => const <String, dynamic>{},
            );
            final assistantText = assistant['content']?.toString();
            if (assistantText != null) {
              await _speakAssistantText(assistantText);
            }
          }
          final saved = _savedPositions[widget.session.id];
          if (saved != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scrollController.hasClients) {
                _scrollController.jumpTo(
                  saved.clamp(0.0, _scrollController.position.maxScrollExtent),
                );
              }
            });
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scrollController.hasClients) {
                _scrollController.jumpTo(
                  _scrollController.position.maxScrollExtent,
                );
              }
            });
          }
        } catch (e) {
          setState(() {
            _streaming = false;
            _sending = false;
            _streamingBuffer = null;
          });
          streamingBuffer.dispose();
        }
      },
      onError: (error) {
        if (!mounted) return;
        // Remove the placeholder assistant message
        setState(() {
          if (_messages.isNotEmpty && _messages.last['role'] == 'assistant') {
            _messages.removeLast();
          }
          _streamingBuffer = null;
        });
        streamingBuffer.dispose();
        _handleSendError(text, error);
      },
    );
  }

  void _handleSendError(String text, Object e) {
    setState(() {
      _sending = false;
      _streaming = false;
      _awaitingVoiceReply = false;
      if (_messages.isNotEmpty &&
          _messages.last['role'] == 'user' &&
          _messages.last['content'] == text) {
        _messages.removeLast();
      }
    });

    if (mounted) {
      showAppSnackBar(
        context,
        'Send failed: $e',
        isError: true,
        duration: const Duration(seconds: 6),
      );
    }
  }

  void _upsertToolProgress(Map<String, dynamic> progress) {
    final toolCallId =
        progress['toolCallId']?.toString() ??
        progress['tool_call_id']?.toString() ??
        progress['id']?.toString() ??
        '';
    final tool = progress['tool']?.toString() ?? 'tool';
    final status = progress['status']?.toString() ?? 'running';
    final emoji = progress['emoji']?.toString() ?? '🔧';
    final label = progress['label']?.toString();
    final display = label == null || label.isEmpty ? tool : label;
    final done = status == 'completed' || status == 'finished';
    final content = done
        ? '$emoji $display — done'
        : '$emoji $display — $status';

    setState(() {
      final idx = toolCallId.isEmpty
          ? -1
          : _toolMessages.indexWhere((m) => m['toolCallId'] == toolCallId);
      final payload = {
        'role': 'tool_progress',
        'content': content,
        'toolCallId': toolCallId,
        'status': status,
        'tool': tool,
      };
      if (idx >= 0) {
        _toolMessages[idx] = payload;
      } else {
        _toolMessages.add(payload);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  Widget build(BuildContext context) {
    return AuroraScaffold(
      // Softer bloom than the list screens: chat is dense with text and a
      // full-strength glow would fight the message bubbles for attention.
      intensity: 0.65,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        // The session name rides in a capsule, as the title does in the
        // reference design.
        title: BrandPill(label: widget.session.title),
        actions: [
          if (_streaming)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Responding…',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            )
          else
            FaintIconButton(
              icon: Icons.refresh,
              onPressed: _loading ? null : _fetchMessages,
              tooltip: 'Refresh',
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
              _buildInputBar(),
            ],
          ),
        ),
      ),
    );
  }

  /// Floating glass composer: a pill-shaped field flanked by the voice
  /// controls and the gradient send orb.
  Widget _buildInputBar() {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final busy = _loading || _streaming;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_listening)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'I’m listening…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ClipRRect(
              borderRadius: BorderRadius.circular(HermesRadius.pill),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(HermesRadius.pill),
                    color: HermesGlass.fill(brightness),
                    border: Border.all(color: HermesGlass.stroke(brightness)),
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
                              contentPadding: EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                              isDense: true,
                            ),
                            minLines: 1,
                            maxLines: 4,
                            textCapitalization: TextCapitalization.sentences,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.send,
                            enabled: !busy,
                            onSubmitted: (_) => _sendMessage(),
                          ),
                        ),
                      ),
                      NeonIconButton(
                        icon: _listening ? Icons.mic_off : Icons.mic_none,
                        size: 40,
                        active: _listening,
                        tooltip: _listening
                            ? 'Stop listening'
                            : 'Speak to Hermes',
                        onPressed: (!busy && !_sending)
                            ? _toggleVoiceInput
                            : null,
                      ),
                      const SizedBox(width: 6),
                      if (_streaming)
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
                          onPressed: _loading ? null : _sendMessage,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Starter prompts shown on an empty conversation, mirroring the reference
  /// design's suggestion grid.
  /// Fixed height of a suggestion card. Comfortably above the 48dp minimum
  /// tap target, but short enough that the icon and label stay on one line
  /// rather than stacking.
  static const double _suggestionCardHeight = 60;

  static const List<({IconData icon, String label})> _suggestions = [
    (icon: Icons.auto_awesome, label: 'What can you do?'),
    (icon: Icons.memory, label: 'What do you remember?'),
    (icon: Icons.schedule, label: 'What runs on a schedule?'),
    (icon: Icons.terminal, label: 'Summarise recent sessions'),
  ];

  Widget _buildEmptyState() {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Two columns once there is room; a single column in the narrow
        // split-view pane.
        final columns = constraints.maxWidth >= 480 ? 2 : 1;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Column(
            children: [
              const PlasmaOrb(size: 195),
              const SizedBox(height: 26),
              Text(
                'How can I help?',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Send a message below to start the conversation.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 28),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _suggestions.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  // A fixed height rather than an aspect ratio, so the cards
                  // stay the same size whatever the pane width is.
                  mainAxisExtent: _suggestionCardHeight,
                ),
                itemBuilder: (context, i) {
                  final suggestion = _suggestions[i];
                  return GlassCard(
                    radius: HermesRadius.chip,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    onTap: _loading
                        ? null
                        : () => _sendSuggestion(suggestion.label),
                    child: Row(
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: HermesGlass.activeStroke(theme.brightness),
                            ),
                          ),
                          child: Icon(
                            suggestion.icon,
                            size: 13,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            suggestion.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _sendSuggestion(String prompt) {
    if (_sending || _streaming) return;
    _textController.text = prompt;
    _sendMessage();
  }

  Widget _buildBody() {
    if (_loading) {
      return const StatusView.loading();
    }

    if (_error != null) {
      return StatusView.error(
        icon: Icons.warning_amber,
        title: 'Failed to load messages',
        message: _error!,
        onRetry: _fetchMessages,
      );
    }

    if (_messages.isEmpty) {
      return _buildEmptyState();
    }

    // Build display list: consecutive tool messages grouped into cards,
    // interleaved with user/assistant bubbles.
    final toolQueue = List<Map<String, dynamic>>.from(_toolMessages);
    final displayMessages = <dynamic>[];
    final currentGroup = <Map<String, dynamic>>[];

    for (var i = 0; i < _messages.length; i++) {
      final msg = _messages[i];
      final role = (msg['role'] as String?) ?? 'assistant';
      if (isToolResultMessage(msg)) {
        if (toolQueue.isNotEmpty) {
          currentGroup.add(toolQueue.removeAt(0));
        }
        continue;
      }
      if (role != 'user' && role != 'assistant') continue;

      // The in-flight assistant reply is bound to the streaming buffer
      // instead of `msg['content']`, so its bubble can rebuild on its own
      // (via AnimatedBuilder) without a screen-level setState per token.
      final isStreamingPlaceholder =
          _streamingBuffer != null && role == 'assistant' && i == _messages.length - 1;
      if (isStreamingPlaceholder) {
        if (currentGroup.isNotEmpty) {
          displayMessages.add(currentGroup.toList());
          currentGroup.clear();
        }
        displayMessages.add(_streamingBuffer);
        continue;
      }

      final content = stripToolResultText(messageContentToText(msg['content']));
      if (content.isEmpty) continue;

      if (currentGroup.isNotEmpty) {
        displayMessages.add(currentGroup.toList());
        currentGroup.clear();
      }
      displayMessages.add({...msg, '_display_content': content});
    }
    if (currentGroup.isNotEmpty) {
      displayMessages.add(currentGroup.toList());
    }

    // Tools from SSE events that arrived during streaming but haven't been
    // matched to server messages yet — show them as a card.
    if (toolQueue.isNotEmpty) {
      displayMessages.add(toolQueue.toList());
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 4),
      itemCount: displayMessages.length,
      itemBuilder: (context, index) {
        final item = displayMessages[index];

        if (item is List<Map<String, dynamic>>) {
          return _ToolProgressCard(items: item, verbose: _verboseMode);
        }

        if (item is StreamingBuffer) {
          return AnimatedBuilder(
            animation: item,
            builder: (context, _) {
              if (item.text.isEmpty) return const SizedBox.shrink();
              return _MessageBubble(
                content: item.text,
                isUser: false,
                verbose: _verboseMode,
                metadata: const {'role': 'assistant'},
              );
            },
          );
        }

        final msg = item as Map<String, dynamic>;
        final role = (msg['role'] as String?) ?? 'assistant';
        final content =
            (msg['_display_content'] as String?) ??
            stripToolResultText(messageContentToText(msg['content']));
        final isUser = role == 'user';

        // Bot Mode: deliveries from other agents and background-process
        // notifications ride the user role without a human typing them.
        if (isUser) {
          final notice = parseAgentNotice(content);
          if (notice != null) return _AgentNoticeRow(notice: notice);
        }

        return _MessageBubble(
          content: content,
          isUser: isUser,
          verbose: _verboseMode,
          metadata: msg,
        );
      },
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final String content;
  final bool isUser;
  final bool verbose;
  final Map<String, dynamic> metadata;

  const _MessageBubble({
    required this.content,
    required this.isUser,
    this.verbose = false,
    this.metadata = const {},
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final assistantTextColor = theme.colorScheme.onSurface;

    // Collect extra metadata for verbose mode
    final List<String> metaLines = [];
    if (verbose) {
      final role = (metadata['role'] as String?) ?? 'unknown';
      metaLines.add('role: $role');
      // Show any extra fields that aren't role/content
      for (final entry in metadata.entries) {
        if (entry.key == 'role' || entry.key == 'content') continue;
        final value = entry.value?.toString() ?? 'null';
        if (value.length > 80) {
          metaLines.add('${entry.key}: ${value.substring(0, 80)}…');
        } else {
          metaLines.add('${entry.key}: $value');
        }
      }
    }

    // The user's bubble is the lit one — a gradient capsule with a bloom —
    // while the assistant speaks from a frosted panel.
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Verbose metadata header
          if (metaLines.isNotEmpty) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: (isUser ? Colors.white : Colors.black).withValues(
                  alpha: 0.1,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: metaLines
                    .map(
                      (line) => Text(
                        line,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: isUser
                              ? Colors.white.withValues(alpha: 0.8)
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
          // Message content
          MarkdownBody(
            data: content,
            styleSheet: MarkdownStyleSheet(
              p: (isUser
                  ? theme.textTheme.bodyMedium?.copyWith(color: Colors.white)
                  : theme.textTheme.bodyMedium?.copyWith(
                      color: assistantTextColor,
                    )),
              code: TextStyle(
                backgroundColor: (isUser ? Colors.white : Colors.black)
                    .withValues(alpha: 0.12),
                fontFamily: 'monospace',
                color: isUser ? Colors.white : null,
              ),
              a: TextStyle(
                color: isUser ? Colors.white70 : theme.colorScheme.primary,
              ),
              h1: isUser
                  ? theme.textTheme.headlineSmall?.copyWith(color: Colors.white)
                  : theme.textTheme.headlineSmall,
              h2: isUser
                  ? theme.textTheme.titleLarge?.copyWith(color: Colors.white)
                  : theme.textTheme.titleLarge,
              h3: isUser
                  ? theme.textTheme.titleMedium?.copyWith(color: Colors.white)
                  : theme.textTheme.titleMedium,
              blockquote: TextStyle(
                color: isUser ? Colors.white60 : Colors.grey,
                fontStyle: FontStyle.italic,
              ),
              blockquoteDecoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: isUser ? Colors.white38 : theme.colorScheme.primary,
                    width: 3,
                  ),
                ),
              ),
              em: isUser
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: Colors.white,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
              strong: isUser
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
            ),
          ),
        ],
      ),
    );

    // Flexible caps the bubble at the pane width (minus a 48px gap on the
    // opposite side) instead of the full screen width, so it never clips
    // when rendered in the narrower split-view detail pane.
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

class _ToolProgressCard extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final bool verbose;

  const _ToolProgressCard({required this.items, this.verbose = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurfaceVariant;

    final active = items.any((item) {
      final status = (item['status'] as String?) ?? '';
      return status != 'completed' && status != 'finished';
    });

    final emojis = items.map((item) {
      final content = (item['content'] as String?) ?? '';
      return content.isNotEmpty
          ? content.substring(0, content.length < 2 ? content.length : 2)
          : '\uD83D\uDD27';
    }).toList();

    // Compact pill, capped at the pane width so it never clips in the
    // narrower split-view detail pane.
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? HermesGlass.activeFill(theme.brightness)
              : HermesGlass.fill(theme.brightness),
          borderRadius: BorderRadius.circular(HermesRadius.pill),
          border: Border.all(
            color: active
                ? HermesGlass.activeStroke(theme.brightness)
                : HermesGlass.stroke(theme.brightness),
          ),
          boxShadow: active
              ? hermesGlow(hermesMagenta, alpha: 0.20, blur: 14)
              : null,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              active ? '\u23F3' : '\u2705',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                emojis.join(' '),
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (active)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: fg),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Bot Mode: a delivery from another agent, or a background-process
/// notification. Both arrive on the user role but are not the human speaking,
/// so they render as a centered timeline notice with the text one tap away
/// rather than as a user bubble.
class _AgentNoticeRow extends StatefulWidget {
  const _AgentNoticeRow({required this.notice});

  final AgentNotice notice;

  @override
  State<_AgentNoticeRow> createState() => _AgentNoticeRowState();
}

class _AgentNoticeRowState extends State<_AgentNoticeRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notice = widget.notice;
    final muted = theme.colorScheme.onSurfaceVariant;
    final isAgent = notice.kind == AgentNoticeKind.agentMessage;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isAgent)
                const Text('🤖', style: TextStyle(fontSize: 13))
              else
                Icon(Icons.terminal, size: 14, color: muted),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  notice.headline,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: muted,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          if (notice.body.isNotEmpty) ...[
            const SizedBox(height: 4),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  _expanded ? 'hide message' : 'show message',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: GlassCard(
                  radius: HermesRadius.tile,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Text(
                    notice.body,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
