import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/status_view.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('loading state shows a spinner and optional caption', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const StatusView.loading(message: 'Connecting...')),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Connecting...'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('error state shows the message and a working Retry button', (
    tester,
  ) async {
    var retried = false;
    await tester.pumpWidget(
      wrap(
        StatusView.error(
          title: 'Failed to load things',
          message: 'boom',
          onRetry: () => retried = true,
        ),
      ),
    );

    expect(find.text('Failed to load things'), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('empty state shows the title without a Retry button', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const StatusView.empty(title: 'No items yet')),
    );

    expect(find.text('No items yet'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  Color cardColorOf(WidgetTester tester, String message) {
    return tester
        .widget<Card>(
          find.ancestor(of: find.text(message), matching: find.byType(Card)),
        )
        .color!;
  }

  testWidgets(
    'success/error status cards use a light background in light mode, not '
    'the old hardcoded shade900',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          home: Scaffold(
            body: Column(
              children: const [
                StatusMessageCard.success(message: 'Model applied'),
                StatusMessageCard.error(message: 'Failed to apply'),
              ],
            ),
          ),
        ),
      );

      final successColor = cardColorOf(tester, 'Model applied');
      final errorColor = cardColorOf(tester, 'Failed to apply');

      expect(successColor, isNot(Colors.green.shade900));
      expect(errorColor, isNot(Colors.red.shade900));
      // Light backgrounds read as high luminance; the old shade900 cards
      // were both near-black regardless of theme brightness.
      expect(successColor.computeLuminance(), greaterThan(0.5));
      expect(errorColor.computeLuminance(), greaterThan(0.3));
    },
  );

  testWidgets(
    'success/error status cards still render legibly in dark mode',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: Column(
              children: const [
                StatusMessageCard.success(message: 'Model applied'),
                StatusMessageCard.error(message: 'Failed to apply'),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Model applied'), findsOneWidget);
      expect(find.text('Failed to apply'), findsOneWidget);
    },
  );
}
