import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/rpc_client.dart';

/// A transport the test drives directly, so the protocol is exercised without
/// a socket.
class FakeTransport implements RpcTransport {
  final _in = StreamController<String>();
  final sent = <Map<String, dynamic>>[];
  bool closed = false;

  @override
  Stream<String> get incoming => _in.stream;

  @override
  void send(String frame) =>
      sent.add(jsonDecode(frame) as Map<String, dynamic>);

  @override
  Future<void> close() async {
    closed = true;
    await _in.close();
  }

  void deliver(String frame) => _in.add(frame);
  void fail(Object error) => _in.addError(error);
}

void main() {
  late FakeTransport transport;
  late HermesRpcClient client;

  setUp(() {
    transport = FakeTransport();
    client = HermesRpcClient(transport);
  });

  test('sends JSON-RPC 2.0 requests with incrementing ids', () async {
    unawaited(client.call('session.list', {'title': 'Bot Chat'}));
    unawaited(client.call('session.history'));

    expect(transport.sent.first['jsonrpc'], '2.0');
    expect(transport.sent.first['method'], 'session.list');
    expect(transport.sent.first['params'], {'title': 'Bot Chat'});
    expect(transport.sent[0]['id'], isNot(transport.sent[1]['id']));
  });

  test('resolves a call with the response carrying its id', () async {
    final pending = client.call('session.list');
    final id = transport.sent.single['id'];

    transport.deliver(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'sessions': [
            {'id': 's1'},
          ],
        },
      }),
    );

    expect((await pending)['sessions'], [
      {'id': 's1'},
    ]);
  });

  test('matches responses by id when they arrive out of order', () async {
    final first = client.call('a');
    final second = client.call('b');
    final firstId = transport.sent[0]['id'];
    final secondId = transport.sent[1]['id'];

    transport.deliver(
      jsonEncode({
        'id': secondId,
        'result': {'who': 'b'},
      }),
    );
    transport.deliver(
      jsonEncode({
        'id': firstId,
        'result': {'who': 'a'},
      }),
    );

    expect((await first)['who'], 'a');
    expect((await second)['who'], 'b');
  });

  test('turns an error response into an RpcError', () async {
    final pending = client.call('prompt.submit');
    final id = transport.sent.single['id'];

    transport.deliver(
      jsonEncode({
        'id': id,
        'error': {'code': 4001, 'message': 'session not found'},
      }),
    );

    await expectLater(
      pending,
      throwsA(
        isA<RpcError>()
            .having((e) => e.message, 'message', 'session not found')
            .having((e) => e.code, 'code', 4001),
      ),
    );
  });

  test('routes id-less frames to the event stream', () async {
    final events = <RpcEvent>[];
    client.events.listen(events.add);

    transport.deliver(
      jsonEncode({
        'method': 'message.delta',
        'params': {'text': 'hel'},
      }),
    );
    transport.deliver(
      jsonEncode({
        'method': 'message.delta',
        'params': {'text': 'lo'},
      }),
    );
    await pumpEventQueue();

    expect(events.map((e) => e.method), ['message.delta', 'message.delta']);
    expect(events.map((e) => e.params['text']).join(), 'hello');
  });

  test('splits coalesced frames — the gateway batches streamed tokens', () async {
    final events = <RpcEvent>[];
    client.events.listen(events.add);

    transport.deliver(
      '${jsonEncode({'method': 'message.delta', 'params': {'text': 'a'}})}\n'
      '${jsonEncode({'method': 'message.delta', 'params': {'text': 'b'}})}\n',
    );
    await pumpEventQueue();

    expect(events.length, 2);
  });

  test('a malformed frame is skipped, not fatal', () async {
    final events = <RpcEvent>[];
    client.events.listen(events.add);

    transport.deliver('not json');
    transport.deliver(
      jsonEncode({'method': 'message.complete', 'params': <String, dynamic>{}}),
    );
    await pumpEventQueue();

    expect(events.single.method, 'message.complete');
  });

  test('gateway.ready completes the handshake future', () async {
    var settled = false;
    unawaited(client.ready.then((_) => settled = true));

    transport.deliver(jsonEncode({'method': 'gateway.ready', 'params': {}}));
    await pumpEventQueue();

    expect(settled, isTrue);
  });

  test('a dropped socket fails calls still in flight', () async {
    final pending = client.call('session.history');

    transport.fail(StateError('connection reset'));

    await expectLater(pending, throwsA(isA<StateError>()));
  });

  test('closing fails pending calls and shuts the transport down', () async {
    final pending = client.call('session.history');
    // Observe before closing: close() completes the error synchronously, and
    // an unobserved completer error is an unhandled exception.
    final rejected = expectLater(pending, throwsA(isA<StateError>()));

    await client.close();

    await rejected;
    expect(transport.closed, isTrue);
    await expectLater(client.call('session.list'), throwsA(isA<RpcError>()));
  });

  group('gatewaySocketUri', () {
    test('upgrades the scheme and appends the token', () {
      final uri = gatewaySocketUri('http://hermes.local:9119', token: 'TOK');

      expect(uri.scheme, 'ws');
      expect(uri.path, '/api/ws');
      expect(uri.queryParameters['token'], 'TOK');
    });

    test('prefers the ticket — a gated dashboard rejects the token', () {
      final uri = gatewaySocketUri(
        'http://hermes.local:9119',
        ticket: 'T1',
        token: 'TOK',
      );

      expect(uri.queryParameters['ticket'], 'T1');
      expect(uri.queryParameters.containsKey('token'), isFalse);
    });

    test('uses wss for an https dashboard', () {
      expect(
        gatewaySocketUri('https://hermes.example', token: 't').scheme,
        'wss',
      );
    });

    test('omits the credential when there is none', () {
      final uri = gatewaySocketUri('http://hermes.local:9119/');

      expect(uri.hasQuery, isFalse);
      expect(uri.toString(), 'ws://hermes.local:9119/api/ws');
    });
  });
}
