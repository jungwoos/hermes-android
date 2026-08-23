// Bot Mode roster as a full-screen destination (narrow layouts and the
// split-view detail pane). The wide-screen session panel embeds the same
// [BotRosterView] in its Bots tab instead.
import 'package:flutter/material.dart';

import '../services/connection_manager.dart';
import '../widgets/aurora.dart';
import '../widgets/bot_roster.dart';
import '../widgets/glass.dart';
import 'chat_screen.dart';

class BotsScreen extends StatefulWidget {
  final SavedConnection connection;

  /// When true the screen is rendered inside the split-view detail pane, so
  /// it must not show a back button.
  final bool embedded;

  const BotsScreen({
    required this.connection,
    this.embedded = false,
    super.key,
  });

  @override
  State<BotsScreen> createState() => _BotsScreenState();
}

class _BotsScreenState extends State<BotsScreen> {
  final _roster = GlobalKey<BotRosterViewState>();

  Future<void> _openBotChat(String bot, {required bool fresh}) async {
    final connection = await resolveBotConnection(
      context: context,
      base: widget.connection,
      bot: bot,
      multiplex: _roster.currentState?.multiplex ?? false,
    );
    if (connection == null || !mounted) return;

    // Reopen the bot's canonical chat — the same row the desktop opens —
    // so the two clients share one conversation instead of each keeping
    // its own. Unless the user explicitly asked for a new one.
    final session =
        (fresh ? null : await canonicalBotSession(connection)) ??
        newBotSession(bot);
    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(connection: connection, session: session),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AuroraScaffold(
      intensity: 0.7,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: const Text('Bots'),
        actions: [
          FaintIconButton(
            icon: Icons.refresh,
            tooltip: 'Refresh',
            onPressed: () => _roster.currentState?.load(),
          ),
        ],
      ),
      body: BotRosterView(
        key: _roster,
        connection: widget.connection,
        onOpenChat: _openBotChat,
      ),
    );
  }
}
