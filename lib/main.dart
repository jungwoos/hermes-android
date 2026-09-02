import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/screens/hermes_shell.dart';
import 'core/services/connection_manager.dart';
import 'core/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final connManager = ConnectionManager(prefs);
  runApp(HermesApp(connManager: connManager));
}

class HermesApp extends StatefulWidget {
  final ConnectionManager connManager;
  const HermesApp({required this.connManager, super.key});

  @override
  State<HermesApp> createState() => HermesAppState();
}

class HermesAppState extends State<HermesApp> {
  @override
  void initState() {
    super.initState();
    HermesThemeMode.notifier.value = HermesThemeMode.fromPrefsValue(
      widget.connManager.prefs.getString('theme_mode'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: HermesThemeMode.notifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'Hermes Agent',
          themeMode: mode,
          theme: hermesTheme(Brightness.light),
          darkTheme: hermesTheme(Brightness.dark),
          // One screen for the whole app: the gateway roster is a panel inside
          // HermesShell, not a route above it.
          home: HermesShell(connManager: widget.connManager),
        );
      },
    );
  }
}
