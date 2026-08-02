import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme.dart';
import 'package:hermes_android/core/widgets/aurora.dart';
import 'package:hermes_android/main.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// The ambient plasma orb animates continuously, so the widget tree never
  /// reaches a settled state and `pumpAndSettle` would time out.
  Future<void> pumpFrames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  test('fromPrefsValue/toPrefsValue round-trip theme mode strings', () {
    expect(HermesThemeMode.fromPrefsValue('dark'), ThemeMode.dark);
    expect(HermesThemeMode.fromPrefsValue('light'), ThemeMode.light);
    expect(HermesThemeMode.fromPrefsValue('system'), ThemeMode.system);
    expect(HermesThemeMode.fromPrefsValue(null), ThemeMode.system);

    expect(HermesThemeMode.toPrefsValue(ThemeMode.dark), 'dark');
    expect(HermesThemeMode.toPrefsValue(ThemeMode.light), 'light');
    expect(HermesThemeMode.toPrefsValue(ThemeMode.system), 'system');
  });

  // A widget test rather than a plain `test`: hermesTheme() pulls its text
  // theme from google_fonts, which kicks off an unawaited font load. With
  // runtime fetching disabled that load throws, and only the flutter_test
  // zone absorbs the resulting async error.
  testWidgets('both brightnesses share the neon accent and a see-through app '
      'bar', (tester) async {
    final dark = hermesTheme(Brightness.dark);
    final light = hermesTheme(Brightness.light);

    expect(dark.colorScheme.primary, hermesMagenta);
    expect(light.colorScheme.primary, hermesViolet);

    // The aurora is painted behind the Scaffold, so the app bar must not
    // paint its own background over it.
    expect(dark.appBarTheme.backgroundColor, Colors.transparent);
    expect(light.appBarTheme.backgroundColor, Colors.transparent);

    // Dark mode sits on ink, light mode on a violet-tinted paper — neither is
    // the stock Material grey.
    expect(dark.scaffoldBackgroundColor, hermesInk);
    expect(light.scaffoldBackgroundColor, hermesMist);
  });

  testWidgets('AuroraScaffold paints the aurora behind a transparent Scaffold', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: hermesTheme(Brightness.dark),
        home: const AuroraScaffold(body: Text('content')),
      ),
    );
    await pumpFrames(tester);

    expect(find.byType(AuroraBackground), findsOneWidget);
    expect(find.text('content'), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      Colors.transparent,
    );
  });

  testWidgets(
    'toggling HermesThemeMode.notifier updates the running MaterialApp '
    'without an ancestor-state lookup',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final connManager = ConnectionManager(prefs);

      await tester.pumpWidget(HermesApp(connManager: connManager));
      await pumpFrames(tester);

      MaterialApp materialApp() =>
          tester.widget<MaterialApp>(find.byType(MaterialApp));

      expect(materialApp().themeMode, ThemeMode.system);

      HermesThemeMode.notifier.value = ThemeMode.dark;
      await tester.pump();
      expect(materialApp().themeMode, ThemeMode.dark);

      HermesThemeMode.notifier.value = ThemeMode.light;
      await tester.pump();
      expect(materialApp().themeMode, ThemeMode.light);
    },
  );
}
