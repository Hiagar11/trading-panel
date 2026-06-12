import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_panel/main.dart';

void main() {
  testWidgets('signal card — LONG with SL/TP golden', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const signal = <String, dynamic>{
      'id': '1',
      'pair': 'BTCUSDT',
      'direction': 'LONG',
      'price': '65000.00',
      'sl': '63000.00',
      'tp': '68000.00',
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
            child: SignalCard(signal: signal, showPnlAlways: true),
          ),
        ),
      ),
    );
    await tester.pump(Duration.zero);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/signal_card.png'),
    );
  });

  testWidgets('signal card — SHORT with TP hit golden', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const signal = <String, dynamic>{
      'id': '2',
      'pair': 'ETHUSDT',
      'direction': 'SHORT',
      'price': '3200.00',
      'sl': '3400.00',
      'tp': '3000.00',
      'outcome': 'tp',
      'pnl': 47.50,
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
            child: SignalCard(signal: signal, showPnlAlways: true),
          ),
        ),
      ),
    );
    await tester.pump(Duration.zero);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/signal_card_tp_hit.png'),
    );
  });
}
