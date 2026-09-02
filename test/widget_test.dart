import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/screens/hermes_shell.dart';
import 'package:hermes_android/core/widgets/brand_hero.dart';
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

  /// A dashboard-only gateway: no API server means the shell opens it without
  /// a health check, so the test stays off the network.
  Future<ConnectionManager> managerWithOpenConnection() async {
    final connManager = await makeManager();
    connManager.saveConnection('Home', '192.168.1.50', dashboardPort: 9119);
    final id = connManager.getConnections().single.id;
    await connManager.prefs.setString('last_connection_id', id);
    return connManager;
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

  testWidgets('the gateway roster lives inside the shell, not above it', (
    tester,
  ) async {
    final connManager = await makeManager();
    connManager.saveConnection('Home', '192.168.1.50', dashboardPort: 9119);

    await tester.pumpWidget(HermesApp(connManager: connManager));
    await pumpFrames(tester);

    // One shell, with the roster rendered in its side panel — picking a
    // gateway is a selection here, not a route pushed on top.
    expect(find.byType(HermesShell), findsOneWidget);
    expect(find.text('Gateways'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('renders a saved connection as a card', (tester) async {
    final connManager = await makeManager();
    connManager.saveConnection(
      'Home',
      '192.168.1.50',
      dashboardPort: 9119,
      gatewayPort: 8642,
      apiKey: 'test-key',
    );
    // 'last_connection_id' is left unset, so the shell opens on the roster
    // instead of restoring a gateway (which would hit the network).

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

    expect(find.text('Add Connection'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Label'), findsOneWidget);
    // The dashboard is the primary surface, so its port and login are the
    // fields on show; the gateway lives in the collapsed section.
    expect(find.widgetWithText(TextField, 'Dashboard Port'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Gateway Port'), findsNothing);
  });

  // Real metrics of the test device (Galaxy Z Fold, density 420 → dpr 2.625):
  // cover 1248x1972px = 475x751dp, main screen 1848x2448px = 704x933dp.
  const foldDpr = 2.625;
  const coverScreen = Size(1248, 1972);
  const mainScreen = Size(1848, 2448);

  void useScreen(WidgetTester tester, Size physicalSize) {
    tester.view.devicePixelRatio = foldDpr;
    tester.view.physicalSize = physicalSize;
    addTearDown(tester.view.reset);
  }

  testWidgets('the list column carries the navigation, not a drawer', (
    tester,
  ) async {
    useScreen(tester, coverScreen);
    final connManager = await managerWithOpenConnection();

    await tester.pumpWidget(HermesApp(connManager: connManager));
    await pumpFrames(tester);

    expect(find.byType(Drawer), findsNothing);
    // The Bot/Ses tabs are over the list. Only the selected side spells
    // itself out, and this connection opens on Bots.
    expect(find.text('Bot'), findsOneWidget);
    expect(find.text('S'), findsOneWidget);
    // Bot comes first. Asserted by position, since finding both labels says
    // nothing about their order.
    expect(
      tester.getCenter(find.text('Bot')).dx,
      lessThan(tester.getCenter(find.text('S')).dx),
    );
    // …and the dashboard destinations under it.
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Cron Jobs'), findsOneWidget);
    expect(find.text('Skills'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('both Fold screens show two panes', (tester) async {
    for (final screen in [mainScreen, coverScreen]) {
      useScreen(tester, screen);
      final connManager = await makeManager();

      await tester.pumpWidget(HermesApp(connManager: connManager));
      await pumpFrames(tester);

      // Two panes: the compact roster in the column, the hero in the main
      // pane beside it. The cover screen (475dp) used to fall back to one.
      expect(find.byType(HermesHeader), findsOneWidget);
      expect(find.text('No connections'), findsOneWidget);
    }
  });

  testWidgets('the 100dp cover column renders gateway cards without overflow', (
    tester,
  ) async {
    useScreen(tester, coverScreen);
    final connManager = await makeManager();
    // Two gateways, and no last-used id, so the roster is what the pinned
    // 100dp column shows. Any overflow in those cards fails this test.
    connManager.saveConnection('Home', '192.168.1.50', dashboardPort: 9119);
    connManager.saveConnection(
      'Studio',
      'hermes-studio.tailnet.ts.net',
      dashboardPort: 9119,
      gatewayPort: 8642,
      apiKey: 'key',
    );

    await tester.pumpWidget(HermesApp(connManager: connManager));
    await pumpFrames(tester);

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);
    // The address line is dropped at this width.
    expect(find.textContaining('192.168.1.50:9119'), findsNothing);
  });

  testWidgets('a phone-width screen still shows one column', (tester) async {
    // 360dp is below the two-pane floor, so the list is the pane.
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(720, 1560);
    addTearDown(tester.view.reset);
    final connManager = await makeManager();

    await tester.pumpWidget(HermesApp(connManager: connManager));
    await pumpFrames(tester);

    expect(find.byType(HermesHeader), findsNothing);
    expect(find.textContaining('Tap + to add'), findsOneWidget);
  });

  testWidgets('the HERMES bar is the entry screen only', (tester) async {
    useScreen(tester, mainScreen);
    final connManager = await managerWithOpenConnection();

    await tester.pumpWidget(HermesApp(connManager: connManager));
    await pumpFrames(tester);

    // A gateway is open, so the shell drops its bar; each pane brings its
    // own. (The wordmark still appears inside the hero placeholder, so this
    // checks for the bar itself.)
    expect(find.byType(AppBar), findsNothing);
    // Navigation lives in the list column instead.
    expect(find.text('Bot'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('the entry screen keeps the HERMES bar', (tester) async {
    useScreen(tester, mainScreen);
    final connManager = await makeManager();

    await tester.pumpWidget(HermesApp(connManager: connManager));
    await pumpFrames(tester);

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('HERMES'), findsWidgets);
  });
}
