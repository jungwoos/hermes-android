import 'dart:convert';

/// How to reach one bot's API server.
///
/// A bot is a separate agent profile, and the gateway scopes API keys per
/// profile — the default profile's key is rejected on another profile's
/// routes. So talking to a bot needs its own credentials, kept here and
/// stored per (connection, bot).
///
/// Two topologies exist. With a gateway per profile, each bot listens on its
/// own [port] and [prefix] is empty. Under a multiplexing gateway, every bot
/// shares the default port and is addressed by the `/p/<name>` [prefix].
class BotTarget {
  const BotTarget({required this.port, required this.apiKey, this.prefix = ''});

  final int port;
  final String prefix;
  final String apiKey;

  Map<String, dynamic> toMap() => {
    'port': port,
    'prefix': prefix,
    'apiKey': apiKey,
  };

  static BotTarget? fromMap(Map<String, dynamic> map) {
    final port = map['port'];
    final apiKey = map['apiKey'];
    if (port is! int || apiKey is! String) return null;
    return BotTarget(
      port: port,
      prefix: (map['prefix'] as String?) ?? '',
      apiKey: apiKey,
    );
  }

  String encode() => jsonEncode(toMap());

  static BotTarget? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? fromMap(decoded) : null;
    } catch (_) {
      return null;
    }
  }
}
