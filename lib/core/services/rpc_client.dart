// JSON-RPC client for the Hermes dashboard's gateway socket (`/api/ws`).
//
// The dashboard bridges this socket straight into tui_gateway, the same RPC
// surface the desktop and TUI speak. That matters for Bot Mode: only this
// surface can resolve a bot's canonical chat (`session.list` by exact title,
// including hidden rows) and run a turn against another profile — the REST
// API server can do neither, and its keys are scoped per profile so it would
// need one credential per bot.
//
// Wire protocol (tui_gateway/ws.py): newline-delimited JSON-RPC 2.0 in both
// directions, identical to stdio. Responses carry the request id; anything
// with a method and no id is a server-pushed event. The server emits
// `gateway.ready` right after accepting the connection.
import 'dart:async';
import 'dart:convert';

/// A frame-level channel, so the protocol can be exercised without a socket.
abstract class RpcTransport {
  Stream<String> get incoming;
  void send(String frame);
  Future<void> close();
}

/// A JSON-RPC error returned by the gateway.
class RpcError implements Exception {
  RpcError(this.method, this.message, {this.code});

  final String method;
  final String message;
  final int? code;

  @override
  String toString() =>
      'RpcError($method): $message${code == null ? '' : ' [$code]'}';
}

/// A server-pushed notification (no id), e.g. `message.delta`.
///
/// The gateway wraps every event in one envelope —
/// `{"method":"event","params":{"type":…,"session_id":…,"payload":{…}}}` —
/// so [method] is the unwrapped `type` and [params] the payload. Verified
/// against a live gateway; matching on the outer `event` name instead would
/// see one undifferentiated stream.
class RpcEvent {
  const RpcEvent(this.method, this.params, {this.sessionId});

  final String method;
  final Map<String, dynamic> params;

  /// The session the event belongs to; events for other sessions share the
  /// socket when more than one is attached.
  final String? sessionId;
}

class HermesRpcClient {
  HermesRpcClient(this._transport) {
    // Callers only await the handshake when they need to order a first
    // request behind it. Observe the failure path here so a socket that dies
    // before anyone looks does not surface as an unhandled exception.
    unawaited(_ready.future.catchError((_) {}));
    _subscription = _transport.incoming.listen(
      _onFrame,
      onError: _failAll,
      onDone: () => _failAll(StateError('gateway socket closed')),
    );
  }

  final RpcTransport _transport;
  late final StreamSubscription<String> _subscription;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<RpcEvent>.broadcast();
  final _ready = Completer<void>();
  int _nextId = 1;
  bool _closed = false;

  /// Server-pushed notifications, including the streaming `message.*` frames.
  Stream<RpcEvent> get events => _events.stream;

  /// Completes when the gateway announces itself, so callers do not race the
  /// handshake with their first request.
  Future<void> get ready => _ready.future;

  /// Issues [method] and waits for the matching response.
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    if (_closed) {
      return Future.error(RpcError(method, 'client is closed'));
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _transport.send(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params ?? const <String, dynamic>{},
      }),
    );
    return completer.future;
  }

  void _onFrame(String frame) {
    // Frames can arrive coalesced; the gateway batches streaming tokens.
    for (final line in const LineSplitter().convert(frame)) {
      final text = line.trim();
      if (text.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        continue; // A malformed frame must not kill the connection.
      }
      if (decoded is! Map<String, dynamic>) continue;
      _dispatch(decoded);
    }
  }

  void _dispatch(Map<String, dynamic> frame) {
    final id = frame['id'];
    final method = frame['method'] as String?;

    if (id == null && method != null) {
      final raw = frame['params'];
      final params = raw is Map<String, dynamic> ? raw : const <String, dynamic>{};
      final event = method == 'event'
          ? (params['type'] as String?) ?? 'event'
          : method;
      final payload = method == 'event' ? params['payload'] : params;
      if (event == 'gateway.ready' && !_ready.isCompleted) _ready.complete();
      _events.add(
        RpcEvent(
          event,
          payload is Map<String, dynamic> ? payload : const {},
          sessionId: params['session_id'] as String?,
        ),
      );
      return;
    }

    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null) return;

    final error = frame['error'];
    if (error is Map) {
      completer.completeError(
        RpcError(
          method ?? 'response',
          (error['message'] ?? 'unknown error').toString(),
          code: error['code'] is int ? error['code'] as int : null,
        ),
      );
      return;
    }
    final result = frame['result'];
    completer.complete(
      result is Map<String, dynamic> ? result : <String, dynamic>{},
    );
  }

  void _failAll(Object error, [StackTrace? stack]) {
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failAll(StateError('client closed'));
    await _subscription.cancel();
    await _events.close();
    await _transport.close();
  }
}

/// Builds the gateway socket URL for a dashboard base URL.
///
/// A gated dashboard wants a single-use [ticket] — the legacy `?token=`
/// credential is rejected outright on an upgrade once the gate is engaged.
/// An open/loopback dashboard still accepts [token], which is the same SPA
/// session token the REST client already resolves.
Uri gatewaySocketUri(
  String dashboardBaseUrl, {
  String? ticket,
  String? token,
}) {
  final base = dashboardBaseUrl
      .replaceFirst('https://', 'wss://')
      .replaceFirst('http://', 'ws://');
  final trimmed = base.endsWith('/')
      ? base.substring(0, base.length - 1)
      : base;
  final credential = <String, String>{
    if (ticket != null && ticket.isNotEmpty) 'ticket': ticket,
    if ((ticket == null || ticket.isEmpty) && token != null && token.isNotEmpty)
      'token': token,
  };
  final query = credential.isEmpty
      ? ''
      : '?${credential.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
  return Uri.parse('$trimmed/api/ws$query');
}
