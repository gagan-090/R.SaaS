import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rsaas_pos/app.dart';
import 'package:rsaas_pos/hub/hub_mode.dart';
import 'package:rsaas_pos/screens/setup_screens.dart';
import 'package:rsaas_pos/state/app_state.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fake_hub.dart';

/// Starts nothing: records the config it was given, as the real main device would use it.
class _FakeHubHost extends HubHost {
  HubHostConfig? started;
  @override
  Future<void> start(HubHostConfig c) async {
    started = c;
    localDeviceToken = 'local-hub-token';
    fingerprint = 'CC:DD';
  }
}

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  /// The cloud with a main device already registered ("Cashier terminal", e.g. this phone before a reinstall).
  ({MockClient client, List<Map<String, dynamic>> registers, List<String> logins}) cloud() {
    final registers = <Map<String, dynamic>>[], logins = <String>[];
    http.Response json(int code, Object body) => http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json'});
    final client = MockClient((r) async {
      final path = r.url.path;
      if (path.endsWith('/auth/login')) {
        logins.add(r.body);
        return json(200, {'status': 'ok', 'accessToken': 'acc-1'});
      }
      if (path.endsWith('/me')) return json(200, {'hasPin': true});
      if (path.endsWith('/devices/register-hub')) {
        expect(r.headers['authorization'], 'Bearer acc-1');
        final b = jsonDecode(r.body) as Map<String, dynamic>;
        registers.add(b);
        if (b['replace'] != true) {
          return json(409, {'statusCode': 409, 'code': 'hub_exists', 'message': 'This restaurant already has a main device ("Cashier terminal").', 'hubName': 'Cashier terminal'});
        }
        return json(201, {'deviceId': 'd2', 'deviceToken': 'cloud-dev-token', 'branchId': 'b1', 'branchCode': 'MG', 'licensePublicKey': 'pk'});
      }
      return json(404, {'code': 'not_found', 'message': 'Cannot ${r.method} $path'});
    });
    return (client: client, registers: registers, logins: logins);
  }

  Future<(MemoryDeviceStore, _FakeHubHost)> open(WidgetTester t, MockClient client) async {
    final store = MemoryDeviceStore();
    final host = _FakeHubHost();
    t.view.physicalSize = const Size(360, 740); // small Android phone
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(overrides: [
      deviceStoreProvider.overrideWithValue(store),
      hubApiFactoryProvider.overrideWithValue((_) => FakeHubApi()),
      setupHttpClientProvider.overrideWithValue(client),
      hubHostProvider.overrideWithValue(host),
    ], child: const PosApp()));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('setup-email')), 'owner@demo.test');
    await t.enterText(find.byKey(const Key('setup-secret')), 'correct horse');
    await t.ensureVisible(find.byKey(const Key('setup-sign-in')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('setup-sign-in')));
    await t.pumpAndSettle();
    return (store, host);
  }

  testWidgets('owner password, a main device already exists: "Make this the main device" takes over without a second sign-in', (t) async {
    final c = cloud();
    final (store, host) = await open(t, c.client);
    expect(find.byKey(const Key('hub-exists')), findsOneWidget);
    expect(find.textContaining('"Cashier terminal" is the main device now'), findsOneWidget);
    expect(find.byKey(const Key('setup-error')), findsNothing); // a choice, not a dead end
    expect(t.takeException(), isNull); // fits on a small phone

    await t.ensureVisible(find.byKey(const Key('take-over-hub')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('take-over-hub')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-take-over')));
    await t.pumpAndSettle();

    expect(c.logins, hasLength(1)); // the password was typed once
    expect(c.registers.last['replace'], isTrue);
    expect(host.started?.cloudDeviceToken, 'cloud-dev-token');
    expect(store.value?.isHub, isTrue);
    expect(store.value?.deviceToken, 'local-hub-token');
    expect(find.text('Who is working?'), findsOneWidget); // straight on to the PIN screen
  });

  testWidgets('owner password, a main device already exists: cancel keeps the choice; "Join with my PIN" goes back to the PIN sign-in', (t) async {
    final c = cloud();
    final (store, _) = await open(t, c.client);
    await t.ensureVisible(find.byKey(const Key('take-over-hub')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('take-over-hub')));
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(c.registers, hasLength(1)); // nothing replaced
    expect(find.byKey(const Key('hub-exists')), findsOneWidget);

    await t.ensureVisible(find.byKey(const Key('join-instead')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('join-instead')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('hub-exists')), findsNothing);
    expect(find.byKey(const Key('setup-sign-in')), findsOneWidget);
    expect(find.byKey(const Key('setup-hub-address')), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const Key('setup-secret'))).controller!.text, isEmpty);
    expect(t.widget<TextField>(find.byKey(const Key('setup-secret'))).enabled, isTrue);
    expect(store.value, isNull);
  });
}
