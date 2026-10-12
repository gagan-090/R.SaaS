import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

Widget host(Widget child, {bool dark = true}) => MaterialApp(
      theme: dark ? HPTheme.service() : HPTheme.backOffice(),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  testWidgets('primary button fires and disables while busy', (t) async {
    var taps = 0;
    await t.pumpWidget(host(PrimaryButton(label: 'Bill & pay', onPressed: () => taps++)));
    await t.tap(find.text('Bill & pay'));
    expect(taps, 1);
    await t.pumpWidget(host(PrimaryButton(label: 'Bill & pay', busy: true, onPressed: () => taps++)));
    await t.tap(find.text('Bill & pay'));
    expect(taps, 1);
  });

  testWidgets('reason dialog cannot be confirmed without a reason', (t) async {
    String? result = 'unset';
    await t.pumpWidget(host(Builder(
      builder: (c) => TextButton(onPressed: () async => result = await ReasonDialog.show(c, title: 'Suspend restaurant', confirmLabel: 'Suspend'), child: const Text('open')),
    ), dark: false));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.text('Suspend').last);
    await t.pumpAndSettle();
    expect(find.byType(ReasonDialog), findsOneWidget); // still open
    await t.enterText(find.byKey(const Key('reason-field')), '  Unpaid invoice  ');
    await t.pump();
    await t.tap(find.text('Suspend').last);
    await t.pumpAndSettle();
    expect(result, 'Unpaid invoice');
  });

  testWidgets('keypad emits digits, backspace and clear', (t) async {
    final keys = <String>[];
    await t.pumpWidget(host(SizedBox(width: 320, child: NumericKeypad(onKey: keys.add, onBackspace: () => keys.add('<'), onClear: () => keys.add('C')))));
    for (final k in ['1', '0', '5']) {
      await t.tap(find.byKey(Key('key-$k')));
    }
    await t.tap(find.bySemanticsLabel('Backspace'));
    await t.tap(find.bySemanticsLabel('Clear'));
    expect(keys, ['1', '0', '5', '<', 'C']);
  });

  testWidgets('table tile states carry words, not only colour', (t) async {
    await t.pumpWidget(host(Wrap(children: const [
      TableTile(name: '12', seats: 4, state: TableState.free),
      TableTile(name: '7', seats: 6, state: TableState.billPrinted, runningTotal: '₹770.00', minutesSeated: 42),
    ])));
    expect(find.text('4 seats'), findsOneWidget);
    expect(find.text('₹770.00'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Table 7, Bill printed')), findsOneWidget);
  });

  testWidgets('status chip, offline banner, plate, veg mark, stepper, states render in both themes', (t) async {
    for (final dark in [true, false]) {
      var qty = 2;
      await t.pumpWidget(host(SingleChildScrollView(child: Column(children: [
        const StatusChip(label: 'Hub online', tone: HPTone.success),
        const OfflineBanner(message: 'Kitchen hub offline', pending: 3),
        const PlateIcon(base: Color(0xFFD9622B), sauce: Color(0xFFF2C27B), garnish: Color(0xFF4F8A3B)),
        const VegMark(isVeg: false),
        StatefulBuilder(builder: (c, set) => QtyStepper(qty: qty, onChanged: (v) => set(() => qty = v))),
        const SizedBox(height: 120, child: EmptyState(title: 'No restaurants yet')),
        SizedBox(height: 160, child: ErrorState(message: 'Network down', onRetry: () {})),
        const OrderCard(title: 'Table 12', subtitle: '3 items · 18 min', total: '₹770.00', status: 'Ordering'),
      ])), dark: dark));
      expect(find.text('Kitchen hub offline · 3 changes waiting'), findsOneWidget);
      expect(find.bySemanticsLabel('Non-vegetarian'), findsOneWidget);
      await t.tap(find.byTooltip('Increase'));
      await t.pump();
      expect(find.text('3'), findsOneWidget);
    }
  });

  test('formatPaise uses Indian grouping', () {
    expect(formatPaise(12345678), '₹1,23,456.78');
    expect(formatPaise(100000000), '₹10,00,000.00');
    expect(formatPaise(-5), '−₹0.05');
  });
}
