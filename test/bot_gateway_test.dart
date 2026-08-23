import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bot_gateway.dart';
import 'package:hermes_android/core/services/rpc_client.dart';

/// Replays canned RPC responses, so the gateway contract is pinned against
/// the shapes a live dashboard actually returned.
class ScriptedTransport implements RpcTransport {
  ScriptedTransport(this.responses);

  /// method -> result payload
  final Map<String, Map<String, dynamic>> responses;
  final _in = StreamController<String>();
  final calls = <Map<String, dynamic>>[];

  @override
  Stream<String> get incoming => _in.stream;

  @override
  void send(String frame) {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(request);
    final result = responses[request['method']];
    scheduleMicrotask(() {
      if (_in.isClosed) return;
      _in.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          if (result == null)
            'error': {'code': 4001, 'message': 'session not found'}
          else
            'result': result,
        }),
      );
    });
  }

  @override
  Future<void> close() => _in.close();

  /// Pushes an event in the gateway's envelope shape.
  void pushEvent(String type, Map<String, dynamic> payload) => _in.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {'type': type, 'session_id': 's1', 'payload': payload},
    }),
  );
}

// Shapes captured from a live gated dashboard.
const _profilesResult = {
  'profiles': [
    {
      'name': 'gmail',
      'display_name': '',
      'model': 'grok-4.6',
      'skill_count': 12,
      'has_avatar': true,
      // An older desktop pins the chat here; the gateway still reports the
      // title-resolved row alongside it.
      'ui_meta': {
        'hermes-bots': {'chat': '20260818_230411_POINTER'},
      },
      'canonical_session': {
        'id': '20260821_010104_8e239b',
        'resolved_id': '20260821_010104_TIP',
        'title': 'Bot Chat',
        'preview': 'inbox triage',
        'message_count': 89,
        'last_active': 1787241666.4,
      },
    },
    {
      'name': 'fresh',
      'display_name': 'Fresh Bot',
      'model': '',
      'skill_count': 0,
      'has_avatar': false,
      'canonical_session': null,
    },
  ],
};

void main() {
  test('reads the roster and the gateway-resolved canonical chat', () async {
    final transport = ScriptedTransport({'profiles.list': _profilesResult});
    final gateway = BotGateway(HermesRpcClient(transport));

    final bots = await gateway.listProfiles();

    expect(bots.map((b) => b.name), ['gmail', 'fresh']);
    final gmail = bots.first;
    // The desktop pointer wins: it is the conversation the user's own
    // desktop opens, even though the gateway resolved a different row.
    expect(gmail.canonicalSessionId, '20260818_230411_POINTER');
    expect(gmail.messageCount, 89);
    expect(gmail.lastActive, 1787241666.4);
    expect(gmail.label, 'gmail');
    // display_name wins when the bot has been renamed.
    expect(bots.last.label, 'Fresh Bot');
    expect(bots.last.canonicalSessionId, isNull);
  });

  test('resume carries the profile — without it the row is not found', () async {
    final transport = ScriptedTransport({
      'profiles.list': _profilesResult,
      'session.resume': {
        'session_id': '20260818_230411_POINTER',
        'messages': [
          {'role': 'user', 'text': 'Hey', 'timestamp': 1787241666.4},
          {'role': 'assistant', 'text': 'Hello', 'timestamp': 1787241670.0},
          {'role': 'tool', 'text': 'ran a search'},
        ],
      },
    });
    final gateway = BotGateway(HermesRpcClient(transport));
    final bots = await gateway.listProfiles();

    final chat = await gateway.openCanonicalChat(bots.first);

    final resume = transport.calls.last;
    expect(resume['method'], 'session.resume');
    expect(resume['params']['profile'], 'gmail');
    expect(resume['params']['session_id'], '20260818_230411_POINTER');
    expect(chat!.messages.map((m) => m.role), ['user', 'assistant', 'tool']);
    expect(chat.messages.first.text, 'Hey');
  });

  test('a bot with no canonical chat is not opened', () async {
    // Minting one here would fork the identity the desktop pins by name.
    final transport = ScriptedTransport({'profiles.list': _profilesResult});
    final gateway = BotGateway(HermesRpcClient(transport));
    final bots = await gateway.listProfiles();

    expect(await gateway.openCanonicalChat(bots.last), isNull);
    expect(transport.calls.map((c) => c['method']), ['profiles.list']);
  });

  test('submit sends the turn and the reply arrives as events', () async {
    final transport = ScriptedTransport({
      'prompt.submit': <String, dynamic>{},
    });
    final gateway = BotGateway(HermesRpcClient(transport));
    final seen = <String>[];
    gateway.events.listen((e) => seen.add(e.method));

    await gateway.submit('s1', 'hello');
    transport.pushEvent('message.delta', {'text': 'hi'});
    transport.pushEvent('message.complete', {});
    transport.pushEvent('turn.end', {});
    await pumpEventQueue();

    expect(transport.calls.single['params'], {
      'session_id': 's1',
      'text': 'hello',
    });
    expect(seen, ['message.delta', 'message.complete', 'turn.end']);
  });

  test('a gateway error surfaces rather than looking like an empty chat', () async {
    final transport = ScriptedTransport({'profiles.list': _profilesResult});
    final gateway = BotGateway(HermesRpcClient(transport));
    final bots = await gateway.listProfiles();

    // session.resume is unscripted, so the transport answers 4001 — the same
    // code a corrupt or unreachable profile returns.
    await expectLater(
      gateway.openCanonicalChat(bots.first),
      throwsA(isA<RpcError>().having((e) => e.code, 'code', 4001)),
    );
  });

  group('describeBotFailure', () {
    test('names a corrupt profile store and scopes the blast radius', () {
      final text = describeBotFailure(
        RpcError('session.resume', 'handler error: database disk image is malformed'),
      );

      expect(text, contains('corrupted'));
      expect(text, contains('Other bots are unaffected'));
      // The raw text stays: it is what identifies the failure in a report.
      expect(text, contains('database disk image is malformed'));
    });

    test('points a missing conversation back at the desktop', () {
      final text = describeBotFailure(
        RpcError('session.resume', 'session not found', code: 4001),
      );

      expect(text, contains('desktop'));
    });

    test('passes an unfamiliar failure through unchanged', () {
      expect(describeBotFailure(StateError('kaboom')), 'Bad state: kaboom');
    });
  });

  group('chat identity across desktop versions', () {
    BotProfile parse(Map<String, dynamic> row) => BotProfile.fromRpc(row);

    test('falls back to the resolved row when no pointer is stored', () {
      // Newer desktops drop the pointer and identify the chat by title.
      final bot = parse({
        'name': 'gmail',
        'canonical_session': {
          'id': 'ROW',
          'resolved_id': 'TIP',
        },
      });

      expect(bot.canonicalSessionId, 'TIP');
    });

    test('an empty or malformed pointer does not shadow the resolved row', () {
      for (final meta in [
        {'hermes-bots': {'chat': ''}},
        {'hermes-bots': {'chat': 42}},
        {'hermes-bots': 'nonsense'},
        {'other': {}},
      ]) {
        final bot = parse({
          'name': 'gmail',
          'ui_meta': meta,
          'canonical_session': {'id': 'ROW', 'resolved_id': 'TIP'},
        });
        expect(bot.canonicalSessionId, 'TIP', reason: '$meta');
      }
    });

    test('a pointer with no resolved row is still openable', () {
      final bot = parse({
        'name': 'gmail',
        'ui_meta': {
          'hermes-bots': {'chat': 'PINNED'},
        },
        'canonical_session': null,
      });

      expect(bot.canonicalSessionId, 'PINNED');
    });
  });

  group('BotMessage.fromRest', () {
    test('flattens the stored content shape the dashboard returns', () {
      final msg = BotMessage.fromRest({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'hello'},
        ],
        'timestamp': 1787241666.4,
      });

      expect(msg.role, 'assistant');
      expect(msg.text, 'hello');
      expect(msg.timestamp, 1787241666.4);
    });

    test('plain string content passes through', () {
      expect(BotMessage.fromRest({'role': 'user', 'content': 'hi'}).text, 'hi');
    });

    test('a missing role reads as the assistant speaking', () {
      expect(BotMessage.fromRest({'content': 'x'}).role, 'assistant');
    });
  });
}
