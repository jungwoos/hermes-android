import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bot_gateway.dart';
import 'package:hermes_android/core/widgets/bot_roster.dart';

BotProfile bot(String name, {double? lastActive, String display = ''}) =>
    BotProfile(
      name: name,
      displayName: display,
      model: '',
      skillCount: 0,
      canonicalSessionId: lastActive == null ? null : 'sid-$name',
      canonicalPreview: '',
      messageCount: 0,
      lastActive: lastActive,
      hasAvatar: false,
    );

List<String> names(List<BotProfile> bots) => [for (final b in bots) b.label];

void main() {
  group('sortBotsByRecency', () {
    test('puts the most recently used bot first', () {
      final sorted = sortBotsByRecency([
        bot('alpha', lastActive: 100),
        bot('beta', lastActive: 300),
        bot('gamma', lastActive: 200),
      ]);

      expect(names(sorted), ['beta', 'gamma', 'alpha']);
    });

    test('sinks bots with no conversation below used ones, in name order', () {
      final sorted = sortBotsByRecency([
        bot('zeta'),
        bot('alpha'),
        bot('used', lastActive: 500),
      ]);

      expect(names(sorted), ['used', 'alpha', 'zeta']);
    });

    test('falls back to name order when nothing has been used', () {
      expect(
        names(sortBotsByRecency([bot('gamma'), bot('alpha'), bot('beta')])),
        ['alpha', 'beta', 'gamma'],
      );
    });

    test('breaks a recency tie by name so the order is stable', () {
      final sorted = sortBotsByRecency([
        bot('beta', lastActive: 100),
        bot('alpha', lastActive: 100),
      ]);

      expect(names(sorted), ['alpha', 'beta']);
    });

    test('orders by the renamed label, which is what the roster shows', () {
      final sorted = sortBotsByRecency([
        bot('zzz', display: 'Aardvark'),
        bot('aaa', display: 'Zebra'),
      ]);

      expect(names(sorted), ['Aardvark', 'Zebra']);
    });

    test('does not mutate the list it was given', () {
      final original = [bot('b'), bot('a', lastActive: 1)];
      sortBotsByRecency(original);

      expect(names(original), ['b', 'a']);
    });
  });

  group('formatBotLastActive', () {
    final now = DateTime(2026, 8, 24, 15, 30);

    test('shows clock time for the same day', () {
      final at = DateTime(2026, 8, 24, 9, 5);
      expect(
        formatBotLastActive(at.millisecondsSinceEpoch / 1000, now: now),
        '09:05',
      );
    });

    test('shows day/month for anything earlier', () {
      final at = DateTime(2026, 8, 21, 9, 5);
      expect(
        formatBotLastActive(at.millisecondsSinceEpoch / 1000, now: now),
        '21/8',
      );
    });
  });

  group('visibleBots', () {
    test('drops hidden names and keeps the roster order', () {
      final shown = visibleBots(
        [bot('alpha'), bot('beta'), bot('gamma')],
        {'beta'},
      );

      expect(names(shown), ['alpha', 'gamma']);
    });

    test('includeHidden lists everything, so a hidden bot can come back', () {
      final all = visibleBots(
        [bot('alpha'), bot('beta')],
        {'alpha', 'beta'},
        includeHidden: true,
      );

      expect(names(all), ['alpha', 'beta']);
    });

    test('hiding a name that is not on the roster changes nothing', () {
      final shown = visibleBots([bot('alpha')], {'ghost'});

      expect(names(shown), ['alpha']);
    });
  });

  group('compactBotLabel', () {
    test('leaves a name that already fits alone', () {
      expect(compactBotLabel('career'), 'career');
      expect(compactBotLabel('default'), 'default');
    });

    test('drops vowels after the first to squeeze a long name', () {
      expect(compactBotLabel('webresearch'), 'webrsrch');
      expect(compactBotLabel('orchestrator'), 'orchstrtr');
    });

    test('keeps the leading vowel, so the name stays recognisable', () {
      expect(compactBotLabel('automation'), 'autmtn');
    });
  });
}
