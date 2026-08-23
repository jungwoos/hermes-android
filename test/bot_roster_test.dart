import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/bot_roster.dart';

List<Map<String, dynamic>> _bots(List<String> names) =>
    [for (final n in names) <String, dynamic>{'name': n}];

List<String> _names(List<Map<String, dynamic>> bots) =>
    [for (final b in bots) b['name'] as String];

void main() {
  group('sortBotsByRecency', () {
    test('puts the most recently used bot first', () {
      final sorted = sortBotsByRecency(_bots(['alpha', 'beta', 'gamma']), {
        'alpha': 100,
        'beta': 300,
        'gamma': 200,
      });

      expect(_names(sorted), ['beta', 'gamma', 'alpha']);
    });

    test('sinks never-used bots below used ones, in name order', () {
      final sorted = sortBotsByRecency(_bots(['zeta', 'alpha', 'used']), {
        'used': 500,
      });

      expect(_names(sorted), ['used', 'alpha', 'zeta']);
    });

    test('falls back to name order when nothing has been used', () {
      final sorted = sortBotsByRecency(_bots(['gamma', 'alpha', 'beta']), {});

      expect(_names(sorted), ['alpha', 'beta', 'gamma']);
    });

    test('breaks a recency tie by name so the order is stable', () {
      final sorted = sortBotsByRecency(_bots(['beta', 'alpha']), {
        'alpha': 100,
        'beta': 100,
      });

      expect(_names(sorted), ['alpha', 'beta']);
    });

    test('does not mutate the list it was given', () {
      final original = _bots(['b', 'a']);
      sortBotsByRecency(original, {'a': 1});

      expect(_names(original), ['b', 'a']);
    });
  });

  group('formatBotLastActive', () {
    final now = DateTime(2026, 8, 24, 15, 30);

    test('shows clock time for the same day', () {
      final at = DateTime(2026, 8, 24, 9, 5);
      final stamp = at.millisecondsSinceEpoch / 1000;

      expect(formatBotLastActive(stamp, now: now), '09:05');
    });

    test('shows day/month for anything earlier', () {
      final at = DateTime(2026, 8, 21, 9, 5);
      final stamp = at.millisecondsSinceEpoch / 1000;

      expect(formatBotLastActive(stamp, now: now), '21/8');
    });
  });

  group('latestBotSession', () {
    SavedConnection botConn() => SavedConnection.forBot(
      SavedConnection(
        id: 'c1',
        label: 'Home',
        host: 'hermes.local',
        port: 8642,
        apiKey: 'DEFAULT',
      ),
      'coder',
      const BotTarget(port: 8643, apiKey: 'CODER'),
    );

    test('newBotSession makes an empty client-side chat named for the bot', () {
      final session = newBotSession('coder');

      expect(session.title, 'coder');
      expect(session.messageCount, 0);
      expect(session.id, isNotEmpty);
    });

    test('picks the newest conversation regardless of response order', () async {
      final conn = botConn();
      final client = ApiClient(
        baseUrl: conn.baseUrl,
        apiKey: conn.apiKey,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/sessions');
          expect(request.headers['Authorization'], 'Bearer CODER');
          return http.Response(
            '{"data":['
            '{"id":"old","title":"Old","started_at":100},'
            '{"id":"newest","title":"Newest","started_at":900},'
            '{"id":"mid","title":"Mid","started_at":500}'
            ']}',
            200,
          );
        }),
      );

      final sessions = await client.getSessions();
      final newest = sessions.reduce(
        (a, b) => b.startedAt > a.startedAt ? b : a,
      );
      expect(newest.id, 'newest');
      client.close();
    });
  });
}
