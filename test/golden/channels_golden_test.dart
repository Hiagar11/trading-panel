import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_panel/main.dart';

void main() {
  testWidgets('channel card — active channel golden', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const channel = <String, dynamic>{
      'id': '1',
      'name': 'Alpha Signals Pro',
      'active': true,
      'daily_pnl': 124.50,
    };

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: kBg,
          cardTheme: const CardThemeData(color: kCard, elevation: 0),
          colorScheme: const ColorScheme.dark(surface: kCard),
        ),
        home: Scaffold(
          backgroundColor: kBg,
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: ChannelCard(
              channel: channel,
              isOwner: false,
              onDelete: () {},
              onToggle: () {},
              onAnalyze: () {},
            ),
          ),
        ),
      ),
    );
    // Single frame — before _fetchPositions() network call resolves
    await tester.pump(Duration.zero);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/channel_card_active.png'),
    );
  });

  testWidgets('channel card — inactive channel golden', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const channel = <String, dynamic>{
      'id': '2',
      'name': 'Quiet Channel',
      'active': false,
    };

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: kBg,
          cardTheme: const CardThemeData(color: kCard, elevation: 0),
          colorScheme: const ColorScheme.dark(surface: kCard),
        ),
        home: Scaffold(
          backgroundColor: kBg,
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: ChannelCard(
              channel: channel,
              isOwner: true,
              onDelete: () {},
              onToggle: () {},
              onAnalyze: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(Duration.zero);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/channel_card_inactive.png'),
    );
  });
}
