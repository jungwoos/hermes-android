// Bot Mode roster as a full-screen destination (narrow layouts and the
// split-view detail pane). The wide-screen session panel embeds the same
// [BotRosterView] in its Bots tab instead.
import 'package:flutter/material.dart';

import '../services/bot_gateway.dart';
import '../services/connection_manager.dart';
import '../widgets/aurora.dart';
import '../widgets/bot_roster.dart';
import '../widgets/glass.dart';
import 'bot_chat_screen.dart';

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

  void _openBotChat(BotProfile bot) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            BotChatScreen(connection: widget.connection, bot: bot),
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
