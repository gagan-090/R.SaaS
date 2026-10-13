import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_pos/app.dart';
import 'package:rsaas_pos/hub/hub_api.dart';
import 'package:rsaas_pos/screens/setup_screens.dart';
import 'package:rsaas_pos/state/app_state.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fake_hub.dart';

const _paired = DeviceSetup(hubBaseUrl: 'https://10.0.0.5:8443/hub/v1', deviceToken: 'dev-token', fingerprint: 'AA:BB');

Future<FakeHubApi> pump(WidgetTester t, {DeviceSetup? setup = _paired, List<Override> extra = const []}) async {
  t.view.physicalSize = const Size(1400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
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

Future<void> typeAmount(WidgetTester t, String rupees) async {
  await t.tap(find.bySemanticsLabel('Clear'));
  for (final d in rupees.split('')) {
    await t.tap(find.byKey(Key('key-$d')));
  }
  await t.pump();
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

  testWidgets('S1: pairing with a scanned QR payload stores the device token', (t) async {
    PairingPayload? claimed;
    final store = MemoryDeviceStore();
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final fake = FakeHubApi();
    await t.pumpWidget(ProviderScope(overrides: [
      deviceStoreProvider.overrideWithValue(store),
      hubApiFactoryProvider.overrideWithValue((_) => fake),
      pairFnProvider.overrideWithValue((p, name, platform) async {
        claimed = p;
        return 'issued-device-token';
      }),
    ], child: const PosApp()));
    await t.pumpAndSettle();
    expect(find.text('Pair with the kitchen hub'), findsOneWidget);
    await t.enterText(find.byKey(const Key('pair-payload')), const PairingPayload(host: '10.0.0.5', port: 8443, code: '654321', fingerprint: 'AA:BB').encode());
    await t.tap(find.widgetWithText(PrimaryButton, 'Pair'));
    await t.pumpAndSettle();
    expect(claimed?.code, '654321');
    expect(store.value?.deviceToken, 'issued-device-token');
    expect(store.value?.fingerprint, 'AA:BB');
    expect(find.text('Who is working?'), findsOneWidget); // S3 next
  });

  testWidgets('S3/S4: PIN login with wrong then right PIN; status bar shows hub + sync', (t) async {
    await pump(t);
    await signIn(t, 'Ravi', '0000');
    expect(find.text('Wrong user or PIN'), findsOneWidget);
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
    }
    await t.pump();
    await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
    await t.pumpAndSettle();
    expect(find.text('Hub online'), findsOneWidget);
    expect(find.text('3 waiting to sync'), findsOneWidget);
    expect(find.byKey(const Key('table-1')), findsOneWidget);
  });

  testWidgets('C1→C2→C5→C7→C6: order, KOT, bill, tip to a waiter, split UPI + cash with change', (t) async {
    final fake = await pump(t);
    await signIn(t, 'Ravi', '1234');
    await t.tap(find.byKey(const Key('table-1')));
    await t.pumpAndSettle();
    await t.tap(find.text('Anita')); // waiter for the table
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('dish-Butter Chicken')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('dish-Garlic Naan')));
    await t.pumpAndSettle();
    expect(find.text('₹420.00'), findsOneWidget); // 340 + 60 + 5% GST
    await t.tap(find.widgetWithText(SecondaryButton, 'Send KOT'));
    await t.pumpAndSettle();
    expect(find.text('IN THE KITCHEN'), findsOneWidget);
    await t.tap(find.widgetWithText(PrimaryButton, 'Bill & pay'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(PrimaryButton, 'Generate bill'));
    await t.pumpAndSettle();
    expect(find.textContaining('BR01/26-27/000001'), findsOneWidget);

    await t.tap(find.text('Add tip'));
    await t.pumpAndSettle();
    await t.tap(find.text('₹50'));
    await t.pump();
    await t.tap(find.widgetWithText(PrimaryButton, 'Add tip'));
    await t.pumpAndSettle();
    expect(fake.lastTip, containsPair('waiterId', 'u-w1')); // defaults to the table's waiter
    expect(fake.lastTip, containsPair('amountPaise', 5000));
    expect(find.text('₹470.00'), findsOneWidget);

    await t.tap(find.text('UPI'));
    await t.pump();
    await typeAmount(t, '200');
    await t.tap(find.widgetWithText(PrimaryButton, 'Pay UPI'));
    await t.pumpAndSettle();
    expect(find.text('₹270.00'), findsOneWidget);
    await t.tap(find.text('Cash'));
    await t.pump();
    await typeAmount(t, '500');
    await t.tap(find.widgetWithText(PrimaryButton, 'Pay CASH'));
    await t.pumpAndSettle();
    expect(find.text('Change due ₹230.00'), findsOneWidget);
    expect(fake.payCalls.toSet(), hasLength(2));
  });

  testWidgets('C6: a failed payment is retried with the SAME idempotency key', (t) async {
    final fake = await pump(t);
    await signIn(t, 'Ravi', '1234');
    await t.tap(find.text('Takeaway'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('dish-Garlic Naan')));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(PrimaryButton, 'Bill & pay'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(PrimaryButton, 'Generate bill'));
    await t.pumpAndSettle();
    await t.tap(find.text('Card'));
    await t.pump();
    await typeAmount(t, '63');
    fake.failNextPayments = 1;
    await t.tap(find.widgetWithText(PrimaryButton, 'Pay CARD'));
    await t.pumpAndSettle();
    expect(find.textContaining('retry safely'), findsOneWidget);
    await t.pump(const Duration(seconds: 5)); // let the error snackbar go away
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(PrimaryButton, 'Pay CARD'));
    await t.pumpAndSettle();
    expect(fake.payCalls, hasLength(2));
    expect(fake.payCalls[0], fake.payCalls[1]);
    expect(find.text('Paid'), findsOneWidget);
  });

  testWidgets('C4: reversal needs a reason; a sent line needs an owner PIN for a cashier', (t) async {
    final fake = await pump(t);
    await signIn(t, 'Ravi', '1234');
    await t.tap(find.text('Takeaway'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('dish-Butter Chicken')));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(SecondaryButton, 'Send KOT'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('reverse-Butter Chicken')));
    await t.pumpAndSettle();
    final confirm = find.widgetWithText(DangerButton, 'Reverse item');
    expect(t.widget<DangerButton>(confirm).onPressed, isNull);
    await t.enterText(find.byKey(const Key('reverse-reason')), 'Guest allergic');
    await t.pump();
    expect(t.widget<DangerButton>(confirm).onPressed, isNull); // still needs the owner PIN
    await t.tap(find.text('Owner'));
    for (final d in '9999'.split('')) {
      await t.tap(find.byKey(Key('key-$d')).last);
    }
    await t.pump();
    await t.tap(confirm);
    await t.pumpAndSettle();
    expect(fake.reversals.single, {'lineId': 'l-2', 'reason': 'Guest allergic', 'approver': 'u-own', 'pin': '9999'});
    expect(find.textContaining('Guest allergic'), findsOneWidget);
  });
}
