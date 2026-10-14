import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

Widget host(Widget child, {bool dark = true}) => MaterialApp(
      theme: dark ? HPTheme.service() : HPTheme.backOffice(),
      home: Scaffold(body: Center(child: child)),
    );

Widget hostTheme(Widget child, ThemeData theme) => MaterialApp(theme: theme, home: Scaffold(body: Center(child: child)));

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

  test('every theme carries its palette; light grounds keep text contrast ≥ 4.5:1', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (math.max(la, lb) + .05) / (math.min(la, lb) + .05);
    }

    for (final (theme, dark) in [
      (HPTheme.service(), true),
      (HPTheme.service(brightness: Brightness.light), false),
      (HPTheme.backOffice(), false),
      (HPTheme.backOffice(brightness: Brightness.dark), true),
    ]) {
      final p = theme.extension<HPPalette>()!;
      expect(p.isDark, dark);
      expect(theme.brightness, dark ? Brightness.dark : Brightness.light);
      expect(contrast(p.text, p.ground), greaterThan(4.5));
      expect(contrast(p.muted, p.ground), greaterThan(4.5), reason: 'secondary text stays readable');
      expect(contrast(p.accentInk, p.ground), greaterThan(4.5), reason: 'accent used as text');
      expect(contrast(HPColors.onSaffron, HPColors.saffron), greaterThan(4.5), reason: 'text on the saffron button');
    }
  });

  testWidgets('dish card, KPI card, skeleton, search and count badge render in all four themes', (t) async {
    for (final (i, theme) in [HPTheme.service(), HPTheme.service(brightness: Brightness.light), HPTheme.backOffice(), HPTheme.backOffice(brightness: Brightness.dark)].indexed) {
      var taps = 0;
      String? q;
      await t.pumpWidget(hostTheme(
        SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 170,
              height: 180,
              child: DishCard(name: 'Butter Chicken', price: '₹340', isVeg: false, base: const Color(0xFFD9622B), sauce: const Color(0xFFF2C27B), garnish: const Color(0xFF4F8A3B), qty: 2, onTap: () => taps++),
            ),
            const KpiCard(label: 'Sales today', value: '₹9,000', caption: '18 bills', icon: Icons.currency_rupee_rounded),
            const SkeletonBox(height: 20),
            HPSearchField(onChanged: (v) => q = v),
            const CountBadge(3),
            const TableTile(name: '4', seats: 4, state: TableState.ordering, runningTotal: '₹420', minutesSeated: 12, caption: 'Anita', expand: false),
          ]),
        ),
        theme,
      ));
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(find.text('Butter Chicken'));
      expect(taps, 1);
      expect(find.text('2'), findsOneWidget, reason: 'quantity badge on the dish card');
      await t.enterText(find.byType(TextField), 'naan $i');
      expect(q, 'naan $i');
      expect(find.text('12 min · Anita'), findsOneWidget);
    }
  });

  testWidgets('sold-out dish cannot be added', (t) async {
    var taps = 0;
    await t.pumpWidget(host(SizedBox(width: 180, height: 190, child: DishCard(name: 'Biryani', price: '₹320', isVeg: false, base: Colors.orange, sauce: Colors.brown, garnish: Colors.green, available: false, onTap: () => taps++))));
    await t.tap(find.text('Biryani'));
    expect(taps, 0);
    expect(find.text('Sold out'), findsOneWidget);
  });

  testWidgets('selected chips use text that is readable on the accent fill (light back office: paper on wine)', (t) async {
    for (final theme in [HPTheme.backOffice(), HPTheme.backOffice(brightness: Brightness.dark), HPTheme.service(), HPTheme.service(brightness: Brightness.light)]) {
      await t.pumpWidget(hostTheme(FilterChip(label: const Text('Kitchen display'), selected: true, onSelected: (_) {}), theme));
      await t.pumpAndSettle(); // MaterialApp animates between themes
      final p = theme.extension<HPPalette>()!;
      final rich = t.widget<RichText>(find.descendant(of: find.text('Kitchen display'), matching: find.byType(RichText)));
      expect(rich.text.style?.color, p.onAccent);
    }
  });

  test('any brand colour stays readable: links/totals darken on white, lighten on dark; fill text flips', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (math.max(la, lb) + .05) / (math.min(la, lb) + .05);
    }

    for (final hex in ['#FFEB3B', '#F0A93B', '#1A73E8', '#212121', '#6B1F2A', '#00E5FF']) {
      final b = HPBrand.fromJson({'color': hex})!;
      for (final base in [HPPalette.backOfficeLight, HPPalette.serviceLight, HPPalette.serviceDark, HPPalette.backOfficeDark]) {
        final p = b.apply(base);
        expect(contrast(p.accentInk, p.ground), greaterThan(3.0), reason: '$hex text on ${base.isDark ? 'dark' : 'white'}');
        expect(contrast(p.onAccent, p.accent), greaterThan(3.0), reason: '$hex button text');
      }
    }
    expect(HPBrand.fromJson({'color': 'blue'}), isNull);
    expect(HPBrand.fromJson({'color': '#1a73e8'})!.hex, '#1A73E8');
    HPBrand.activate(HPBrand.fromJson({'color': '#1A73E8', 'headingCase': 'upper', 'headingWeight': 'heavy'}));
    expect((HPColors.saffron, HPType.heading('Bills'), HPType.titleScreen().fontWeight), (const Color(0xFF1A73E8), 'BILLS', FontWeight.w900));
    expect(HPTone.saffron.color, HPColors.amber, reason: 'warning statuses keep their colour');
    HPBrand.activate(null);
    expect((HPColors.saffron, HPType.heading('Bills')), (HPColors.amber, 'Bills'));
  });

  test('floor plan: chairs follow the seat count; rotated tables overlap by their real footprint', () {
    expect(HPFloorTable.arrangeChairs('round', 80, 80, 4).length, 4);
    expect(HPFloorTable.arrangeChairs('rect', 140, 80, 6).length, 6);
    expect(HPFloorTable.arrangeChairs('rect', 200, 80, 7).length, 7);
    HPFloorTable t(String n, double x, double y, {int rot = 0, double w = 160, double h = 40}) =>
        HPFloorTable(name: n, seats: 4, shape: 'rect', x: x, y: y, width: w, height: h, rotation: rot);
    expect(floorOverlaps([t('A', 100, 100), t('B', 100, 160)]), isEmpty);
    expect(floorOverlaps([t('A', 100, 100, rot: 90), t('B', 100, 160)]), [('A', 'B')], reason: 'turned upright it reaches table B');
    final j = t('C', 10, 20)..chairs = [const HPChair(1, 2, 90)];
    final back = HPFloorTable.fromJson(j.toJson());
    expect((back.x, back.chairs!.single.rotation), (10, 90));
  });
}
