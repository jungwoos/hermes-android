import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

SavedConnection _base({String prefix = '', String id = 'conn-1'}) {
  return SavedConnection(
    id: id,
    label: 'Home',
    host: '192.168.1.50',
    port: 8642,
    apiKey: 'DEFAULT_KEY',
    gatewayPrefix: prefix.isEmpty ? null : prefix,
    dashboardPortOverride: 9119,
    dashboardUsername: 'me',
    dashboardPassword: 'pw',
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('BotTarget', () {
    test('round-trips through storage', () {
      const target = BotTarget(port: 8643, prefix: '/p/coder', apiKey: 'K');
      final decoded = BotTarget.decode(target.encode())!;

      expect(decoded.port, 8643);
      expect(decoded.prefix, '/p/coder');
      expect(decoded.apiKey, 'K');
    });

    test('decoding rejects junk instead of throwing', () {
      expect(BotTarget.decode(null), isNull);
      expect(BotTarget.decode(''), isNull);
      expect(BotTarget.decode('not json'), isNull);
      expect(BotTarget.decode('{"port":"8643"}'), isNull);
      expect(BotTarget.decode('{"port":8643}'), isNull);
    });
  });

  group('ConnectionManager bot targets', () {
    test('stores credentials per connection and per bot', () async {
      final prefs = await SharedPreferences.getInstance();
      final manager = ConnectionManager(prefs);

      await manager.saveBotTarget(
        'conn-1',
        'coder',
        const BotTarget(port: 8643, apiKey: 'CODER'),
      );
      await manager.saveBotTarget(
        'conn-2',
        'coder',
        const BotTarget(port: 9000, apiKey: 'OTHER'),
      );

      expect(manager.getBotTarget('conn-1', 'coder')!.apiKey, 'CODER');
      // Same bot name reached from a different host is a different target.
      expect(manager.getBotTarget('conn-2', 'coder')!.port, 9000);
      expect(manager.getBotTarget('conn-1', 'writer'), isNull);
    });
  });

  group('SavedConnection.forBot', () {
    test('swaps port, prefix and key but keeps host and dashboard', () {
      final bot = SavedConnection.forBot(
        _base(),
        'coder',
        const BotTarget(port: 8643, prefix: '/p/coder', apiKey: 'CODER_KEY'),
      );

      expect(bot.host, '192.168.1.50');
      expect(bot.port, 8643);
      expect(bot.apiKey, 'CODER_KEY');
      expect(bot.gatewayPrefix, '/p/coder');
      expect(bot.label, 'coder');
      // The dashboard is shared across profiles, so its settings carry over.
      expect(bot.dashboardPort, 9119);
      expect(bot.dashboardUsername, 'me');
    });

    test('an empty prefix clears the base connection prefix', () {
      // A per-profile gateway is addressed by port alone; inheriting the base
      // connection's prefix would point the bot at the wrong route.
      final bot = SavedConnection.forBot(
        _base(prefix: '/profile/peter'),
        'coder',
        const BotTarget(port: 8643, apiKey: 'K'),
      );

      expect(bot.gatewayPrefix, isNull);
    });

    test('derives a stable id so reopening a bot keeps its identity', () {
      final first = SavedConnection.forBot(
        _base(),
        'coder',
        const BotTarget(port: 8643, apiKey: 'K'),
      );
      final second = SavedConnection.forBot(
        _base(),
        'coder',
        const BotTarget(port: 8643, apiKey: 'K'),
      );

      expect(first.id, second.id);
      expect(first.id, isNot(_base().id));
    });

    test('the chat base URL includes the multiplex prefix', () {
      final bot = SavedConnection.forBot(
        _base(),
        'coder',
        const BotTarget(port: 8642, prefix: '/p/coder', apiKey: 'K'),
      );

      expect(
        SavedConnection.joinBaseUrl(bot.baseUrl, bot.gatewayPrefix ?? ''),
        'http://192.168.1.50:8642/p/coder',
      );
    });
  });
}
