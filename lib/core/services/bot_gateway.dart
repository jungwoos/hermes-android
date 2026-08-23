// Bot Mode over the dashboard's gateway socket.
//
// Verified against a live gated dashboard: log in, POST /api/auth/ws-ticket,
// connect ws://host/api/ws?ticket=…, then speak JSON-RPC. One dashboard
// session covers every bot, which is the point — the REST API server scopes
// keys per profile and would need one credential per bot.
//
// Reading a bot's conversation is two calls:
//   profiles.list  → canonical_session, the row the desktop opens (resolved
//                    server-side, so both clients land on one conversation)
//   session.resume → attaches it and returns the transcript. session.history
//                    alone answers 4001: it only sees sessions already open
//                    in the gateway process.
import 'dart:async';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../utils/message_content.dart';
import 'connection_manager.dart';
import 'rpc_client.dart';

/// One agent profile as the gateway reports it.
class BotProfile {
  const BotProfile({
    required this.name,
    required this.displayName,
    required this.model,
    required this.skillCount,
    required this.canonicalSessionId,
    required this.canonicalPreview,
    required this.messageCount,
    required this.lastActive,
    required this.hasAvatar,
  });

  final String name;
  final String displayName;
  final String model;
  final int skillCount;

  /// The bot's forever-chat. Null when the bot has never been opened.
  ///
  /// Two mechanisms exist and the installed desktop decides which is real.
  /// Older builds pin the chat with a session id stored in
  /// `ui_meta['hermes-bots'].chat`; newer ones drop that pointer and identify
  /// the chat by the title `Bot Chat`, which the gateway resolves and reports
  /// as `canonical_session`. Preferring the pointer when it is present and
  /// falling back to the resolved row otherwise matches both, which is what
  /// makes mobile open the conversation the user's own desktop opens.
  final String? canonicalSessionId;
  final String canonicalPreview;
  final int messageCount;
  final double? lastActive;
  final bool hasAvatar;

  String get label => displayName.isNotEmpty ? displayName : name;

  static BotProfile fromRpc(Map<String, dynamic> row) {
    final canonical = row['canonical_session'];
    final chat = canonical is Map<String, dynamic> ? canonical : null;
    // `resolved_id` follows a compression lineage to the live tip; `id` is the
    // row that lineage started from.
    final resolved = (chat?['resolved_id'] ?? chat?['id']) as String?;
    final id = _desktopChatPointer(row) ?? resolved;
    final active = chat?['last_active'] ?? chat?['started_at'];
    return BotProfile(
      name: (row['name'] as String?) ?? '',
      displayName: (row['display_name'] as String?) ?? '',
      model: (row['model'] as String?) ?? '',
      skillCount: (row['skill_count'] as num?)?.toInt() ?? 0,
      canonicalSessionId: id != null && id.isNotEmpty ? id : null,
      canonicalPreview: (chat?['preview'] as String?) ?? '',
      messageCount: (chat?['message_count'] as num?)?.toInt() ?? 0,
      lastActive: active is num ? active.toDouble() : null,
      hasAvatar: row['has_avatar'] == true,
    );
  }
}

/// The session id an older desktop pinned this bot to, if any.
String? _desktopChatPointer(Map<String, dynamic> row) {
  final meta = row['ui_meta'];
  if (meta is! Map) return null;
  final bots = meta['hermes-bots'];
  if (bots is! Map) return null;
  final chat = bots['chat'];
  return chat is String && chat.isNotEmpty ? chat : null;
}

/// One turn in a bot's transcript.
class BotMessage {
  const BotMessage({required this.role, required this.text, this.timestamp});

  final String role;
  final String text;
  final double? timestamp;

  static BotMessage fromRpc(Map<String, dynamic> row) => BotMessage(
    role: (row['role'] as String?) ?? 'assistant',
    text: (row['text'] as String?) ?? '',
    timestamp: (row['timestamp'] as num?)?.toDouble(),
  );

  /// The dashboard's read-only transcript rows, whose `content` is the raw
  /// stored shape — multimodal parts and tool-result wrappers included.
  static BotMessage fromRest(Map<String, dynamic> row) => BotMessage(
    role: (row['role'] as String?) ?? 'assistant',
    text: stripToolResultText(messageContentToText(row['content'])),
    timestamp: (row['timestamp'] as num?)?.toDouble(),
  );
}

/// An attached bot conversation: the session the gateway opened plus the
/// transcript it returned.
class BotConversation {
  const BotConversation({required this.sessionId, required this.messages});

  final String sessionId;
  final List<BotMessage> messages;
}

/// Turns a gateway failure into something a reader can act on.
///
/// The raw text is kept as the detail — it is the only thing that identifies
/// an unfamiliar failure — but the common ones get a first line that says what
/// broke and whether the rest of the app is affected.
String describeBotFailure(Object error) {
  final raw = error.toString();
  if (raw.contains('database disk image is malformed')) {
    return "This bot's conversation store is corrupted, so the host cannot "
        'read its history. Other bots are unaffected. Recovering that '
        "profile's state.db restores it.\n\n$raw";
  }
  if (raw.contains('session not found')) {
    return 'The host no longer has this conversation. Open the bot on the '
        'desktop once to re-establish it.\n\n$raw';
  }
  if (raw.contains('401') || raw.contains('Unauthorized')) {
    return 'The dashboard rejected the connection. Check the dashboard '
        "username and password on this connection.\n\n$raw";
  }
  return raw;
}

/// Opens the gateway socket for a dashboard connection.
class BotGateway {
  BotGateway(this._rpc);

  final HermesRpcClient _rpc;

  /// Server-pushed turn events: `message.delta`, `message.complete`,
  /// `tool.*`, `turn.end`, `turn.error`.
  Stream<RpcEvent> get events => _rpc.events;

  /// Logs in over the dashboard session the app already holds, mints a
  /// single-use ticket, and connects. Tickets expire in ~30s and are consumed
  /// on use, so this mints one per connection.
  static Future<BotGateway> connect(
    DashboardClient dashboard, {
    Future<RpcTransport> Function(Uri uri)? openTransport,
    Duration handshakeTimeout = const Duration(seconds: 15),
  }) async {
    final ticket = await dashboard.mintWsTicket();
    final uri = gatewaySocketUri(dashboard.baseUrl, ticket: ticket);
    final transport = await (openTransport ?? _openWebSocket)(uri);
    final rpc = HermesRpcClient(transport);
    try {
      await rpc.ready.timeout(handshakeTimeout);
    } catch (e) {
      await rpc.close();
      rethrow;
    }
    return BotGateway(rpc);
  }

  Future<List<BotProfile>> listProfiles() async {
    final res = await _rpc.call('profiles.list');
    final rows = res['profiles'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(BotProfile.fromRpc)
        .toList();
  }

  /// Attaches [bot]'s canonical chat and returns its transcript.
  ///
  /// Returns null when the bot has no canonical chat yet — one is minted by
  /// the desktop on first open, and creating it from here would risk forking
  /// the identity the desktop pins by name.
  Future<BotConversation?> openCanonicalChat(BotProfile bot) async {
    final sessionId = bot.canonicalSessionId;
    if (sessionId == null) return null;
    final res = await _rpc.call('session.resume', {
      'session_id': sessionId,
      // Without this the resume runs against the dashboard's launch profile
      // and the row is not found.
      'profile': bot.name,
      'omit_messages': false,
    });
    final rows = res['messages'];
    return BotConversation(
      sessionId: (res['session_id'] as String?) ?? sessionId,
      messages: rows is List
          ? rows.whereType<Map<String, dynamic>>().map(BotMessage.fromRpc).toList()
          : const [],
    );
  }

  /// Opens [sessionId] in the gateway process so a turn can be submitted
  /// against it.
  ///
  /// Deliberately separate from reading: attaching rebinds the session's
  /// event transport to this client, so it waits until the user actually
  /// sends rather than happening merely because a chat was opened.
  Future<void> attach(String sessionId, String profile) => _rpc.call(
    'session.resume',
    {
      'session_id': sessionId,
      'profile': profile,
      // The transcript is already on screen, read over REST.
      'omit_messages': true,
    },
  );

  /// Sends a turn. The reply arrives on [events], not in the response.
  Future<void> submit(String sessionId, String text) =>
      _rpc.call('prompt.submit', {'session_id': sessionId, 'text': text});

  Future<void> close() => _rpc.close();

  static Future<RpcTransport> _openWebSocket(Uri uri) async {
    // No subprotocol: the gateway does not select one on the ticket path, and
    // offering `hermes-gateway-v1` fails the upgrade with "server sent no
    // subprotocol" (verified against a live dashboard).
    final channel = IOWebSocketChannel.connect(uri);
    await channel.ready;
    return _ChannelTransport(channel);
  }
}

class _ChannelTransport implements RpcTransport {
  _ChannelTransport(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<String> get incoming =>
      _channel.stream.map((frame) => frame is String ? frame : '$frame');

  @override
  void send(String frame) => _channel.sink.add('$frame\n');

  @override
  Future<void> close() => _channel.sink.close();
}
