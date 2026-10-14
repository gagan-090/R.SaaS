import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_pos/app.dart';
import 'package:rsaas_pos/hub/hub_api.dart';
import 'package:rsaas_pos/screens/setup_screens.dart';
import 'package:rsaas_pos/state/app_state.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fake_hub.dart';

const paired = DeviceSetup(hubBaseUrl: 'https://10.0.0.5:8443/hub/v1', deviceToken: 'dev-token', fingerprint: 'AA:BB');
const tablet = Size(1280, 800);
const phone = Size(360, 740); // small Android phone (dp)
const bigPhone = Size(411, 891);

Future<FakeHubApi> start(WidgetTester t, {Size size = tablet, Brightness brightness = Brightness.dark, DeviceSetup? setup = paired, List<Override> extra = const []}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  t.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
  final fake = FakeHubApi();
  await t.pumpWidget(ProviderScope(overrides: [
    deviceStoreProvider.overrideWithValue(MemoryDeviceStore(setup)),
    hubApiFactoryProvider.overrideWithValue((_) => fake),
    ...extra,
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
  await t.tap(find.byKey(const Key('user-menu')).first);
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('switch-user')));
  await t.pumpAndSettle();
}

Future<void> nav(WidgetTester t, String tab) async {
  await t.tap(find.byKey(Key('nav-$tab')));
  await t.pumpAndSettle();
}

List<String> navTabs(WidgetTester t) => [
      for (final k in ['Tables', 'Kitchen', 'Bills', 'Setup', 'More'])
        if (find.byKey(Key('nav-$k')).evaluate().isNotEmpty) k,
    ];

Future<void> typeAmount(WidgetTester t, String rupees) async {
  await t.tap(find.bySemanticsLabel('Clear'));
  for (final d in rupees.split('')) {
    await t.tap(find.byKey(Key('key-$d')));
  }
  await t.pump();
}

Future<void> scrollTo(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pumpAndSettle();
}

/// Opens table 1 for Anita, adds butter chicken + naan, sends the KOT. Works on tablet (panel) and phone (cart bar).
Future<void> orderTable1(WidgetTester t, {required bool narrow}) async {
  await t.tap(find.byKey(const Key('table-1')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('waiter-Anita')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('dish-Butter Chicken')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('dish-Garlic Naan')));
  await t.pumpAndSettle();
  if (narrow) {
    expect(find.text('₹420'), findsOneWidget); // cart bar total
    await t.tap(find.byKey(const Key('cart-send-kot')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('view-order')));
    await t.pumpAndSettle();
  } else {
    expect(find.text('₹420.00'), findsOneWidget); // to pay, incl. 5% GST
    await t.tap(find.byKey(const Key('send-kot')));
    await t.pumpAndSettle();
  }
  expect(find.byKey(const Key('kot-1-new')), findsOneWidget);
}

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  test('pairing QR payload round-trips', () {
    const p = PairingPayload(host: '192.168.1.10', port: 8443, code: '123456', fingerprint: 'AA:BB:CC');
    final back = PairingPayload.tryParse(p.encode())!;
    expect((back.host, back.port, back.code, back.fingerprint), ('192.168.1.10', 8443, '123456', 'AA:BB:CC'));
    expect(back.baseUrl, 'https://192.168.1.10:8443/hub/v1');
    expect(PairingPayload.tryParse('https://evil.example'), isNull);
  });

  testWidgets('S1: joining a hub with the pairing text stores the device token', (t) async {
    PairingPayload? claimed;
    final store = MemoryDeviceStore();
    t.view.physicalSize = tablet;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(overrides: [
      deviceStoreProvider.overrideWithValue(store),
      hubApiFactoryProvider.overrideWithValue((_) => FakeHubApi()),
      pairFnProvider.overrideWithValue((p, name, platform) async {
        claimed = p;
        return 'issued-device-token';
      }),
    ], child: const PosApp()));
    await t.pumpAndSettle();
    expect(find.text('Set up this device'), findsOneWidget);
    await t.tap(find.text('Join a hub'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('pair-payload')), const PairingPayload(host: '10.0.0.5', port: 8443, code: '654321', fingerprint: 'AA:BB').encode());
    await t.tap(find.widgetWithText(PrimaryButton, 'Pair'));
    await t.pumpAndSettle();
    expect(claimed?.code, '654321');
    expect(store.value?.deviceToken, 'issued-device-token');
    expect(find.text('Who is working?'), findsOneWidget); // S3 next
  });

  testWidgets('S3: wrong PIN shakes and clears; right PIN opens the shell with hub status', (t) async {
    await start(t);
    await signIn(t, 'Ravi', '0000');
    expect(find.text('Wrong user or PIN'), findsOneWidget);
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
    }
    await t.pump();
    await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
    await t.pumpAndSettle();
    expect(find.text('3 waiting to sync'), findsOneWidget);
    expect(find.byKey(const Key('table-1')), findsOneWidget);
    expect(find.text('Demo Dhaba · MG Road'), findsOneWidget);
  });

  testWidgets('S3: someone with no PIN is told how to set one; once the hub has it, the pad opens', (t) async {
    final hub = await start(t);
    final owner = hub.staffList.firstWhere((u) => u['id'] == 'u-own');
    owner.remove('pin'); // e.g. signed up on the web and never set one
    await t.tap(find.byKey(const Key('staff-Owner'))); // the list on screen is older
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('not-you')));
    await t.pumpAndSettle();
    expect(find.text('No PIN yet'), findsOneWidget);
    await t.tap(find.byKey(const Key('staff-Owner')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('no-pin-help')), findsOneWidget);
    expect(find.textContaining('Set my PIN'), findsOneWidget);
    await t.tap(find.widgetWithText(PrimaryButton, 'OK'));
    await t.pumpAndSettle();
    expect(find.text('No PIN yet'), findsOneWidget);
    owner['pin'] = '9999'; // set in the web console, pulled by the hub
    await t.tap(find.byKey(const Key('staff-Owner')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('pin-dots')), findsOneWidget);
  });

  testWidgets('pull down to refresh: works on the sign-in names and on an empty kitchen', (t) async {
    final hub = await start(t, size: phone, brightness: Brightness.light);
    hub.staffList.add({'id': 'u-new', 'name': 'Meera', 'roles': ['waiter'], 'pin': '4444'});
    expect(find.byKey(const Key('staff-Meera')), findsNothing);
    await t.fling(find.text('Who is working?'), const Offset(0, 500), 1500);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('staff-Meera')), findsOneWidget); // new staff arrive without restarting

    await signIn(t, 'Kunal', '7777');
    expect(find.text('No tickets'), findsOneWidget);
    final before = hub.kdsLoads;
    await t.fling(find.text('No tickets'), const Offset(0, 500), 1500); // not a list: still pulls
    await t.pumpAndSettle();
    expect(hub.kdsLoads, greaterThan(before));
    expect(find.text('No tickets'), findsOneWidget);
  });

  for (final (size, brightness) in [(tablet, Brightness.dark), (phone, Brightness.light), (bigPhone, Brightness.dark)]) {
    final tag = '${size.width.toInt()}x${size.height.toInt()} ${brightness.name}';
    final narrow = size != tablet;

    testWidgets('[$tag] white theme by default on any device; every role lands on its own tabs', (t) async {
      await start(t, size: size, brightness: brightness);
      expect(Theme.of(t.element(find.byType(Scaffold).first)).brightness, Brightness.light);
      expect(Theme.of(t.element(find.byType(Scaffold).first)).scaffoldBackgroundColor, HPColors.white);
      await signIn(t, 'Owner', '9999');
      expect(navTabs(t), ['Tables', 'Kitchen', 'Bills', 'More']);
      expect(find.byKey(const Key('new-takeaway')), findsOneWidget);
      await nav(t, 'More');
      expect(find.byKey(const Key('more-tips')), findsOneWidget);
      expect(find.byKey(const Key('more-printers')), findsOneWidget);
      await t.tap(find.byKey(const Key('more-switch-user')));
      await t.pumpAndSettle();

      await signIn(t, 'Ravi', '1234');
      expect(navTabs(t), ['Tables', 'Kitchen', 'Bills', 'More']);
      await switchUser(t);

      await signIn(t, 'Anita', '5555');
      expect(navTabs(t), ['Tables', 'Kitchen', 'Bills', 'More']);
      await switchUser(t);

      await signIn(t, 'Kunal', '7777');
      expect(navTabs(t), ['Kitchen', 'More']);
      expect(find.text('No tickets'), findsOneWidget);
      await switchUser(t);

      await signIn(t, 'Imran', '3333');
      expect(navTabs(t), ['Setup', 'More']);
      expect(find.byKey(const Key('admin-Printers')), findsOneWidget);
      await switchUser(t);

      await signIn(t, 'Asha', '2222');
      expect(navTabs(t), ['Tables', 'Kitchen', 'Bills', 'More']);
      expect(find.text('Read-only'), findsOneWidget);
      expect(find.byKey(const Key('new-takeaway')), findsNothing);
      await t.tap(find.byKey(const Key('table-1')));
      await t.pumpAndSettle();
      expect(find.text('Who serves table 1?'), findsNothing);
    });

    testWidgets('[$tag] cashier: order with waiter, KOT, bill, tip, split UPI + cash with change', (t) async {
      final fake = await start(t, size: size, brightness: brightness);
      await signIn(t, 'Ravi', '1234');
      await orderTable1(t, narrow: narrow);
      await t.tap(find.byKey(const Key('bill-pay')));
      await t.pumpAndSettle();
      await scrollTo(t, find.byKey(const Key('generate-bill')));
      await t.tap(find.byKey(const Key('generate-bill')));
      await t.pumpAndSettle();
      expect(find.textContaining('BR01/26-27/000001'), findsWidgets);

      await scrollTo(t, find.text('Add tip'));
      await t.tap(find.text('Add tip'));
      await t.pumpAndSettle();
      await t.tap(find.text('₹50'));
      await t.pump();
      await t.tap(find.widgetWithText(PrimaryButton, 'Add tip'));
      await t.pumpAndSettle();
      expect(fake.lastTip, containsPair('waiterId', 'u-w1')); // defaults to the table's waiter
      expect(fake.lastTip, containsPair('amountPaise', 5000));
      expect(find.text('₹470.00'), findsWidgets);

      await scrollTo(t, find.text('UPI'));
      await t.tap(find.text('UPI'));
      await t.pump();
      await typeAmount(t, '200');
      await scrollTo(t, find.widgetWithText(PrimaryButton, 'Pay UPI'));
      await t.tap(find.widgetWithText(PrimaryButton, 'Pay UPI'));
      await t.pumpAndSettle();
      expect(find.text('₹270.00'), findsOneWidget); // still to collect
      await scrollTo(t, find.text('Cash'));
      await t.tap(find.text('Cash'));
      await t.pump();
      await typeAmount(t, '500');
      await scrollTo(t, find.widgetWithText(PrimaryButton, 'Pay CASH'));
      await t.tap(find.widgetWithText(PrimaryButton, 'Pay CASH'));
      await t.pumpAndSettle();
      expect(find.text('Change due ₹230.00'), findsOneWidget);
      expect(fake.payCalls.toSet(), hasLength(2));
      expect(fake.mediaRequests, contains('img-bc'), reason: 'dish photos come from the hub');
    });

    testWidgets('[$tag] waiter orders, chef cooks, waiter sees READY; waiter cannot bill', (t) async {
      final hub = await start(t, size: size, brightness: brightness);
      await signIn(t, 'Anita', '5555');
      await t.tap(find.byKey(const Key('table-2')));
      await t.pumpAndSettle();
      expect(find.text('Who serves table 2?'), findsNothing); // waiters open tables as themselves
      await t.tap(find.byKey(const Key('dish-Garlic Naan')));
      await t.pumpAndSettle();
      if (narrow) {
        await t.tap(find.byKey(const Key('cart-send-kot')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('view-order')));
        await t.pumpAndSettle();
      } else {
        await t.tap(find.byKey(const Key('send-kot')));
        await t.pumpAndSettle();
      }
      expect(find.byKey(const Key('kot-1-new')), findsOneWidget);
      expect(find.byKey(const Key('bill-pay')), findsNothing);
      expect(find.text('The cashier bills this order'), findsOneWidget);
      expect(hub.orders.values.single['waiter_id'], 'u-w1');
      if (narrow) {
        await t.tapAt(const Offset(10, 10)); // close the sheet
        await t.pumpAndSettle();
      }
      await switchUser(t);

      await signIn(t, 'Kunal', '7777');
      expect(find.text('Table 2'), findsWidgets);
      await t.tap(find.byKey(const Key('ticket-1-preparing')));
      await t.pumpAndSettle();
      await scrollTo(t, find.byKey(const Key('ticket-1-ready')));
      await t.tap(find.byKey(const Key('ticket-1-ready')));
      await t.pumpAndSettle();
      expect(hub.tickets.single['status'], 'ready');
      await switchUser(t);

      await signIn(t, 'Anita', '5555');
      await t.tap(find.byKey(const Key('table-2')));
      await t.pumpAndSettle();
      if (narrow) {
        await t.tap(find.byKey(const Key('view-order')));
        await t.pumpAndSettle();
      }
      expect(find.byKey(const Key('kot-1-ready')), findsOneWidget);
      expect(find.textContaining('Ready at the pass'), findsOneWidget);
    });

    testWidgets('[$tag] IT admin sets the printer and test-prints; owner reprints a DUPLICATE and adjusts a paid bill', (t) async {
      final hub = await start(t, size: size, brightness: brightness);
      await signIn(t, 'Ravi', '1234');
      await t.tap(find.byKey(const Key('new-takeaway')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('dish-Garlic Naan')));
      await t.pumpAndSettle();
      if (narrow) {
        await t.tap(find.byKey(const Key('view-order')));
        await t.pumpAndSettle();
      }
      await t.tap(find.byKey(const Key('bill-pay')));
      await t.pumpAndSettle();
      await scrollTo(t, find.byKey(const Key('generate-bill')));
      await t.tap(find.byKey(const Key('generate-bill')));
      await t.pumpAndSettle();
      await scrollTo(t, find.text('Exact'));
      await t.tap(find.text('Exact'));
      await t.pump();
      await scrollTo(t, find.widgetWithText(PrimaryButton, 'Pay CASH'));
      await t.tap(find.widgetWithText(PrimaryButton, 'Pay CASH'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('paid-print')));
      await t.pumpAndSettle();
      expect(find.text('No bill printer set up (More → Printers)'), findsOneWidget);
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
      await nav(t, 'Bills');
      await t.tap(find.byKey(const Key('bill-BR01/26-27/000001')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('bill-reprint')));
      await t.pumpAndSettle();
      expect(hub.printed, hasLength(1));
      expect(find.text('Bill printed'), findsOneWidget);
      await t.pump(const Duration(seconds: 3));
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

  testWidgets('C6: a failed payment is retried with the SAME idempotency key', (t) async {
    final fake = await start(t);
    await signIn(t, 'Ravi', '1234');
    await t.tap(find.byKey(const Key('new-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('dish-Garlic Naan')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('bill-pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('generate-bill')));
    await t.pumpAndSettle();
    await t.tap(find.text('Card'));
    await t.pump();
    await typeAmount(t, '63');
    fake.failNextPayments = 1;
    await t.tap(find.widgetWithText(PrimaryButton, 'Pay CARD'));
    await t.pumpAndSettle();
    expect(find.textContaining('retry safely'), findsOneWidget);
    await t.pump(const Duration(seconds: 5)); // let the error toast go away
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(PrimaryButton, 'Pay CARD'));
    await t.pumpAndSettle();
    expect(fake.payCalls, hasLength(2));
    expect(fake.payCalls[0], fake.payCalls[1]);
    expect(find.text('Paid'), findsOneWidget);
  });

  testWidgets('C4: reversal needs a reason; a sent line needs an owner PIN for a cashier; notes go to the kitchen', (t) async {
    final fake = await start(t);
    await signIn(t, 'Ravi', '1234');
    await t.tap(find.byKey(const Key('new-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('dish-Butter Chicken')));
    await t.pumpAndSettle();
    await t.tap(find.text('Add note'));
    await t.pumpAndSettle();
    await t.tap(find.text('Less spicy'));
    await t.tap(find.byKey(const Key('save-note')));
    await t.pumpAndSettle();
    expect(((fake.orders.values.single['lines'] as List).single as Map)['notes'], 'Less spicy');
    expect(find.text('Less spicy'), findsOneWidget);

    await t.tap(find.byKey(const Key('send-kot')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('reverse-Butter Chicken')));
    await t.pumpAndSettle();
    final confirm = find.widgetWithText(DangerButton, 'Reverse item');
    expect(t.widget<DangerButton>(confirm).onPressed, isNull);
    await t.enterText(find.byKey(const Key('reverse-reason')), 'Guest allergic');
    await t.pump();
    expect(t.widget<DangerButton>(confirm).onPressed, isNull); // still needs the owner PIN
    await t.tap(find.text('Owner'));
    await t.enterText(find.byKey(const Key('approver-pin')), '9999');
    await t.pump();
    await t.tap(confirm);
    await t.pumpAndSettle();
    expect(fake.reversals.single, {'lineId': 'l-2', 'reason': 'Guest allergic', 'approver': 'u-own', 'pin': '9999'});
    expect(find.textContaining('Guest allergic'), findsOneWidget);
  });

  testWidgets('cashier adjusting a paid bill needs an owner PIN', (t) async {
    final hub = await start(t);
    await signIn(t, 'Ravi', '1234');
    await t.tap(find.byKey(const Key('new-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('dish-Garlic Naan')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('bill-pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('generate-bill')));
    await t.pumpAndSettle();
    await t.tap(find.text('Exact'));
    await t.pump();
    await t.tap(find.widgetWithText(PrimaryButton, 'Pay CASH'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(PrimaryButton, 'Back to tables'));
    await t.pumpAndSettle();
    await nav(t, 'Bills');
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

  testWidgets('restaurant branding from the hub: own colour, text size, heading case and logo for every role', (t) async {
    addTearDown(() => HPBrand.activate(null));
    final hub = await start(t, size: phone, brightness: Brightness.light);
    expect(find.byKey(const Key('brand-name')), findsNothing); // House Plating look
    hub.branding = {'color': '#1A73E8', 'textSize': 'large', 'headingWeight': 'heavy', 'headingCase': 'upper', 'logoImageId': 'logo-1'};
    await t.fling(find.text('WHO IS WORKING?').evaluate().isEmpty ? find.text('Who is working?') : find.text('WHO IS WORKING?'), const Offset(0, 500), 1500);
    await t.pumpAndSettle();
    expect(find.text('DEMO DHABA'), findsOneWidget);
    expect(find.text('WHO IS WORKING?'), findsOneWidget);
    expect(hub.mediaRequests, contains('logo-1'));
    expect(HPColors.saffron, const Color(0xFF1A73E8));
    final ctx = t.element(find.byType(Scaffold).first);
    expect(Theme.of(ctx).colorScheme.primary, const Color(0xFF1A73E8));
    expect(MediaQuery.of(ctx).textScaler, const TextScaler.linear(1.12));
    await signIn(t, 'Kunal', '7777'); // chef: the kitchen is branded too
    expect(find.text('KITCHEN'), findsWidgets);
  });

  testWidgets('a dish with sizes asks which one; the line and total use that size\'s price; sold-out sizes cannot be picked', (t) async {
    final hub = await start(t);
    await signIn(t, 'Ravi', '1234');
    await t.tap(find.byKey(const Key('table-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('waiter-Anita')));
    await t.pumpAndSettle();
    expect(find.text('from ₹30'), findsOneWidget, reason: 'card shows the lowest available price');
    await t.tap(find.byKey(const Key('dish-Cola')));
    await t.pumpAndSettle();
    expect(find.text('Choose a size'), findsOneWidget);
    expect(find.text('1 l · Sold out'), findsOneWidget);
    await t.tap(find.byKey(const Key('size-1 litre')));
    await t.pumpAndSettle();
    expect(find.text('Choose a size'), findsOneWidget, reason: 'a sold-out size does nothing');
    await t.tap(find.byKey(const Key('size-500 ml')));
    await t.pumpAndSettle();
    final line = (hub.orders.values.single['lines'] as List).cast<Map>().single;
    expect((line['name_snapshot'], line['price_snapshot_paise'], line['variant_id']), ('Cola · 500 ml', 5000, 'v500'));
    expect(find.textContaining('Cola · 500 ml'), findsWidgets);
  });

  testWidgets('floor plan: tables where the owner placed them; tap one to start an order; out-of-use tables refuse', (t) async {
    final hub = await start(t);
    hub.tables.last['manual_status'] = 'unavailable';
    await signIn(t, 'Ravi', '1234');
    await t.tap(find.byKey(const Key('plan-toggle')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('plan-table-1')), findsOneWidget);
    expect(find.text('Out of use'), findsWidgets, reason: 'legend + state');
    await t.tap(find.byKey(const Key('plan-table-2')));
    await t.pumpAndSettle();
    expect(find.text('Table 2 is marked out of use'), findsOneWidget);
    expect(hub.orders, isEmpty);
    await t.tap(find.byKey(const Key('plan-table-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('waiter-Anita')));
    await t.pumpAndSettle();
    expect(hub.orders.values.single['table_id'], 't1');
  });

  testWidgets('appearance: Dark from More overrides a light device; Auto follows it again', (t) async {
    await start(t, size: phone, brightness: Brightness.light);
    await signIn(t, 'Ravi', '1234');
    Brightness now() => Theme.of(t.element(find.byType(Scaffold).last)).brightness;
    expect(now(), Brightness.light);
    await nav(t, 'More');
    await t.ensureVisible(find.byKey(const Key('theme-mode')));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Dark'));
    await t.pumpAndSettle();
    expect(now(), Brightness.dark);
    await t.tap(find.byTooltip('Follow this device'));
    await t.pumpAndSettle();
    expect(now(), Brightness.light);
  });
}
