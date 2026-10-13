import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_pos/app.dart';
import 'package:rsaas_pos/state/app_state.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fake_hub.dart';

const _paired = DeviceSetup(hubBaseUrl: 'https://10.0.0.5:8443/hub/v1', deviceToken: 'dev-token', fingerprint: 'AA:BB');

const tablet = Size(1280, 800);
const phone = Size(360, 740); // small Android phone (dp)
const bigPhone = Size(411, 891);

Future<FakeHubApi> start(WidgetTester t, Size size, [FakeHubApi? hub]) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final fake = hub ?? FakeHubApi();
  await t.pumpWidget(ProviderScope(overrides: [
    deviceStoreProvider.overrideWithValue(MemoryDeviceStore(_paired)),
    hubApiFactoryProvider.overrideWithValue((_) => fake),
  ], child: const PosApp()));
  await t.pumpAndSettle();
  return fake;
}

Future<void> signIn(WidgetTester t, String name, String pin) async {
  await t.tap(find.byKey(Key('staff-$name')));
  await t.pumpAndSettle();
  for (final d in pin.split('')) {
    await t.tap(find.byKey(Key('key-$d')));
  }
  await t.pump();
  await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
  await t.pumpAndSettle();
}

Future<void> switchUser(WidgetTester t) async {
  await t.tap(find.byKey(const Key('switch-user')));
  await t.pumpAndSettle();
}

Future<List<String>> menuEntries(WidgetTester t) async {
  await t.tap(find.byKey(const Key('role-menu')));
  await t.pumpAndSettle();
  final labels = t.widgetList<ListTile>(find.descendant(of: find.byType(PopupMenuItem<int>), matching: find.byType(ListTile)))
      .map((l) => (l.title! as Text).data!)
      .toList();
  await t.tapAt(const Offset(5, 400)); // close the menu
  await t.pumpAndSettle();
  return labels;
}

Future<void> openMenu(WidgetTester t, String label) async {
  await t.tap(find.byKey(const Key('role-menu')));
  await t.pumpAndSettle();
  await t.tap(find.text(label).last);
  await t.pumpAndSettle();
}

/// Cashier on a phone: table → waiter → Menu tab → Order tab → KOT → bill → exact cash.
Future<void> cashierServesTable1(WidgetTester t) async {
  await t.tap(find.byKey(const Key('table-1')));
  await t.pumpAndSettle();
  await t.tap(find.text('Anita'));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('dish-Butter Chicken')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('dish-Garlic Naan')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('tab-order')));
  await t.pumpAndSettle();
  expect(find.text('₹420.00'), findsWidgets);
  await t.tap(find.widgetWithText(SecondaryButton, 'Send KOT'));
  await t.pumpAndSettle();
  await t.tap(find.widgetWithText(PrimaryButton, 'Bill & pay'));
  await t.pumpAndSettle();
  await t.tap(find.widgetWithText(PrimaryButton, 'Generate bill'));
  await t.pumpAndSettle();
  await t.scrollUntilVisible(find.text('Exact'), 200, scrollable: find.byType(Scrollable).last);
  await t.tap(find.text('Exact'));
  await t.pump();
  await t.scrollUntilVisible(find.widgetWithText(PrimaryButton, 'Pay CASH'), 200, scrollable: find.byType(Scrollable).last);
  await t.tap(find.widgetWithText(PrimaryButton, 'Pay CASH'));
  await t.pumpAndSettle();
  expect(find.text('Paid'), findsOneWidget);
}

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  for (final size in [tablet, phone, bigPhone]) {
    final tag = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('[$tag] every role lands on its own home with only its menu entries', (t) async {
      await start(t, size);
      // owner
      await signIn(t, 'Owner', '9999');
      expect(find.byKey(const Key('table-1')), findsOneWidget);
      expect(await menuEntries(t), ['Tables', 'Kitchen display', 'Bill history', 'Tips', 'Printers', 'Hub & devices']);
      await switchUser(t);
      // cashier
      await signIn(t, 'Ravi', '1234');
      expect(find.widgetWithText(PrimaryButton, 'Takeaway'), findsOneWidget);
      expect(await menuEntries(t), ['Tables', 'Kitchen display', 'Bill history', 'Tips']);
      await switchUser(t);
      // waiter
      await signIn(t, 'Anita', '5555');
      expect(find.byKey(const Key('table-1')), findsOneWidget);
      expect(await menuEntries(t), ['Tables', 'Kitchen display', 'Bill history', 'Tips']);
      await switchUser(t);
      // chef → kitchen display
      await signIn(t, 'Kunal', '7777');
      expect(find.text('Kitchen'), findsOneWidget);
      expect(find.text('No tickets'), findsOneWidget);
      expect(await menuEntries(t), ['Kitchen display']);
      await switchUser(t);
      // IT admin → setup home
      await signIn(t, 'Imran', '3333');
      expect(find.byKey(const Key('admin-Printers')), findsOneWidget);
      expect(await menuEntries(t), ['Tips', 'Printers', 'Hub & devices']);
      await switchUser(t);
      // auditor → read-only table map
      await signIn(t, 'Asha', '2222');
      expect(find.text('Read-only'), findsOneWidget);
      expect(find.widgetWithText(PrimaryButton, 'Takeaway'), findsNothing);
      await t.tap(find.byKey(const Key('table-1')));
      await t.pumpAndSettle();
      expect(find.text('Which waiter serves this table?'), findsNothing); // free table: nothing to open
    });

    testWidgets('[$tag] cashier serves a table end to end without layout overflow', (t) async {
      if (size == tablet) {
        // tablet layout has no tabs; covered by pos_test.dart
        return;
      }
      final hub = await start(t, size);
      await signIn(t, 'Ravi', '1234');
      await cashierServesTable1(t);
      expect(hub.tickets, hasLength(1));
    });

    testWidgets('[$tag] waiter takes the order, chef cooks it, waiter sees READY; waiter cannot bill', (t) async {
      final hub = await start(t, size);
      await signIn(t, 'Anita', '5555');
      await t.tap(find.byKey(const Key('table-2')));
      await t.pumpAndSettle();
      expect(find.text('Which waiter serves this table?'), findsNothing); // a waiter opens tables as themselves
      await t.tap(find.byKey(const Key('dish-Garlic Naan')));
      await t.pumpAndSettle();
      if (size != tablet) {
        await t.tap(find.byKey(const Key('tab-order')));
        await t.pumpAndSettle();
      }
      await t.tap(find.widgetWithText(SecondaryButton, 'Send KOT'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('kot-1-new')), findsOneWidget);
      expect(find.widgetWithText(PrimaryButton, 'Bill & pay'), findsNothing);
      expect(find.text('The cashier bills this order'), findsOneWidget);
      expect(hub.orders.values.single['waiter_id'], 'u-w1');

      await switchUser(t);
      await signIn(t, 'Kunal', '7777');
      expect(find.text('KOT #1 · Table 2'), findsOneWidget);
      await t.tap(find.byKey(const Key('ticket-1-preparing')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('ticket-1-ready')));
      await t.pumpAndSettle();
      expect(hub.tickets.single['status'], 'ready');

      await switchUser(t);
      await signIn(t, 'Anita', '5555');
      await t.tap(find.byKey(const Key('table-2')));
      await t.pumpAndSettle();
      if (size != tablet) {
        await t.tap(find.byKey(const Key('tab-order')));
        await t.pumpAndSettle();
      }
      expect(find.byKey(const Key('kot-1-ready')), findsOneWidget);
    });

    testWidgets('[$tag] IT admin sets printers and test-prints; owner reprints a DUPLICATE and adjusts a paid bill', (t) async {
      final hub = await start(t, size);
      await signIn(t, 'Ravi', '1234');
      if (size == tablet) {
        await t.tap(find.byKey(const Key('table-1')));
        await t.pumpAndSettle();
        await t.tap(find.text('Anita'));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('dish-Garlic Naan')));
        await t.pumpAndSettle();
        await t.tap(find.widgetWithText(PrimaryButton, 'Bill & pay'));
        await t.pumpAndSettle();
        await t.tap(find.widgetWithText(PrimaryButton, 'Generate bill'));
        await t.pumpAndSettle();
        await t.tap(find.text('Exact'));
        await t.pump();
        await t.tap(find.widgetWithText(PrimaryButton, 'Pay CASH'));
        await t.pumpAndSettle();
      } else {
        await cashierServesTable1(t);
      }
      await t.tap(find.byKey(const Key('paid-print')));
      await t.pumpAndSettle();
      expect(find.text('No bill printer set up (Menu → Printers)'), findsOneWidget);
      await t.tap(find.widgetWithText(PrimaryButton, 'Back to tables'));
      await t.pumpAndSettle();
      await switchUser(t);

      await signIn(t, 'Imran', '3333');
      await t.tap(find.byKey(const Key('admin-Printers')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('printer-bill-host')), '192.168.1.50');
      await t.tap(find.widgetWithText(SecondaryButton, 'Test print').first);
      await t.pumpAndSettle();
      expect(hub.testPrints, ['bill']);
      expect(hub.printerSettings['bill'], {'host': '192.168.1.50', 'port': 9100, 'widthChars': 48});
      await t.tap(find.byTooltip('Back'));
      await t.pumpAndSettle();
      await switchUser(t);

      await signIn(t, 'Owner', '9999');
      await openMenu(t, 'Bill history');
      await t.tap(find.byKey(const Key('bill-BR01/26-27/000001')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('bill-reprint')));
      await t.pumpAndSettle();
      expect(hub.printed, hasLength(1));
      expect(find.text('Bill printed'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const Key('bill-BR01/26-27/000001')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('bill-adjust')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('adjust-amount')), '20');
      await t.enterText(find.byKey(const Key('adjust-reason')), 'Naan was cold');
      await t.pump();
      await t.tap(find.widgetWithText(DangerButton, 'Post adjustment'));
      await t.pumpAndSettle();
      expect(hub.adjustments.single, {'billId': hub.bills$.keys.single, 'amountPaise': -2000, 'reason': 'Naan was cold', 'approver': null, 'pin': null});
    });
  }

  testWidgets('cashier adjusting a paid bill needs an owner PIN', (t) async {
    final hub = await start(t, tablet);
    await signIn(t, 'Ravi', '1234');
    await t.tap(find.text('Takeaway'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('dish-Garlic Naan')));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(PrimaryButton, 'Bill & pay'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(PrimaryButton, 'Generate bill'));
    await t.pumpAndSettle();
    await t.tap(find.text('Exact'));
    await t.pump();
    await t.tap(find.widgetWithText(PrimaryButton, 'Pay CASH'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(PrimaryButton, 'Back to tables'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(SecondaryButton, 'Bills'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('bill-BR01/26-27/000001')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('bill-adjust')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('adjust-amount')), '10');
    await t.enterText(find.byKey(const Key('adjust-reason')), 'Wrong item rung up');
    await t.pump();
    final post = find.widgetWithText(DangerButton, 'Post adjustment');
    expect(t.widget<DangerButton>(post).onPressed, isNull); // needs owner approval
    await t.tap(find.text('Owner'));
    await t.enterText(find.byKey(const Key('adjust-pin')), '9999');
    await t.pump();
    await t.tap(post);
    await t.pumpAndSettle();
    expect(hub.adjustments.single['approver'], 'u-own');
    expect(hub.adjustments.single['pin'], '9999');
  });
}
