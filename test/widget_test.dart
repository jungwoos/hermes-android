import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/main.dart';

void main() {
  setUpAll(() {
    // The sandbox has no network access for HTTP font fetches; disabling
    // runtime fetching makes GoogleFonts.cinzel fall back to the platform
    // default font immediately instead of failing an unawaited HTTP call.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<ConnectionManager> makeManager() async {
    final prefs = await SharedPreferences.getInstance();
    return ConnectionManager(prefs);
  }

  /// The ambient plasma orb animates continuously, so the widget tree never
  /// reaches a settled state and `pumpAndSettle` would time out. Pumping a
  /// couple of frames is enough for layout and route transitions.
  Future<void> pumpFrames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('shows the empty state when there are no saved connections', (
    tester,
  ) async {
    final connManager = await makeManager();

    await tester.pumpWidget(HermesApp(connManager: connManager));
    await pumpFrames(tester);

    expect(find.text('No connections'), findsOneWidget);
  });

  testWidgets('renders a saved connection as a card', (tester) async {
    final connManager = await makeManager();
    connManager.saveConnection('Home', '192.168.1.50', 8642, 'test-key');
    // 'last_connection_id' is left unset so HomeScreen does not auto-navigate
    // away from the list before the test can inspect it.

    await tester.pumpWidget(HermesApp(connManager: connManager));
    await pumpFrames(tester);

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('No connections'), findsNothing);
  });

  testWidgets('tapping the add button opens the add connection dialog', (
    tester,
  ) async {
    final connManager = await makeManager();

    await tester.pumpWidget(HermesApp(connManager: connManager));
    await pumpFrames(tester);

    await tester.tap(find.byTooltip('Add Connection'));
    await pumpFrames(tester);

    expect(find.text('Add Gateway Connection'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Label'), findsOneWidget);
  });
}
