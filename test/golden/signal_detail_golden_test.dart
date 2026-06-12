import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_panel/main.dart';

void main() {
  testWidgets('signal detail sheet — LONG signal golden', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const signal = <String, dynamic>{
      'id': '42',
      'pair': 'SOLUSDT',
      'direction': 'LONG',
      'price': '185.50',
      'sl': '178.00',
      'tp': '198.00',
      'channel_title': 'Alpha Signals Pro',
      'leverage': '10x',
      'note': 'Strong support breakout',
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
          // Wrap in a sized container so DraggableScrollableSheet renders correctly
          body: SizedBox.expand(
            child: Stack(
              children: [
                const SignalDetailSheet(signal: signal),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(Duration.zero);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/signal_detail_long.png'),
    );
  });

  testWidgets('signal detail sheet — SHORT SL hit golden', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const signal = <String, dynamic>{
      'id': '99',
      'pair': 'BNBUSDT',
      'direction': 'SHORT',
      'price': '420.00',
      'sl': '435.00',
      'tp': '400.00',
      'outcome': 'sl',
      'channel_title': 'Bear Market Alpha',
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
          body: SizedBox.expand(
            child: Stack(
              children: [
                const SignalDetailSheet(signal: signal),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(Duration.zero);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/signal_detail_sl_hit.png'),
    );
  });
}
