import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_panel/main.dart';

void main() {
  testWidgets('positions tab — not logged in golden', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // SessionManager.token is null by default — isLoggedIn returns false.
    // _fetch() exits early without network calls → deterministic state.
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: kBg,
          cardTheme: const CardThemeData(color: kCard, elevation: 0),
          colorScheme: const ColorScheme.dark(surface: kCard),
        ),
        home: const Scaffold(
          backgroundColor: kBg,
          body: PositionsTab(),
        ),
      ),
    );
    // pumpAndSettle is safe here: no network I/O, just setState calls
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/positions_no_auth.png'),
    );
  });

  testWidgets('positions tab — loading shimmer golden', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Simulate "logged in" by setting a fake token so the loading branch is hit
    SessionManager.token = 'test-token';
    addTearDown(() => SessionManager.token = null);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: kBg,
          cardTheme: const CardThemeData(color: kCard, elevation: 0),
          colorScheme: const ColorScheme.dark(surface: kCard),
        ),
        home: const Scaffold(
          backgroundColor: kBg,
          body: PositionsTab(),
        ),
      ),
    );
    // Single frame: captures loading indicator before network resolves
    await tester.pump(Duration.zero);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/positions_loading.png'),
    );
  });
}
