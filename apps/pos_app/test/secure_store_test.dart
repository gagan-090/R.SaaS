import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_pos/app.dart';
import 'package:rsaas_pos/state/app_state.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fake_hub.dart';

/// The phone's encrypted storage, as Android behaves after a reinstall that restored old data without its key:
/// every read fails with BadPaddingException until the store is cleared.
class _BrokenKeystore {
  final calls = <String>[];
  final values = <String, String>{};
  bool broken = true;

  Future<Object?> handle(MethodCall c) async {
    calls.add(c.method);
    final args = (c.arguments as Map?)?.cast<String, Object?>() ?? const {};
    switch (c.method) {
      case 'read' || 'readAll' || 'containsKey':
        if (broken) {
          throw PlatformException(code: 'Exception encountered', message: 'read',
              details: 'javax.crypto.BadPaddingException: error:1e000065:Cipher functions:OPENSSL_internal:BAD_DECRYPT');
        }
        return c.method == 'read' ? values[args['key']] : null;
      case 'deleteAll':
        broken = false;
        values.clear();
        return null;
      case 'write':
        if (broken) throw PlatformException(code: 'Exception encountered', message: 'write');
        values[args['key']! as String] = args['value']! as String;
        return null;
      case 'delete':
        values.remove(args['key']);
        return null;
    }
    return null;
  }
}

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late _BrokenKeystore keystore;
  setUp(() {
    keystore = _BrokenKeystore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, keystore.handle);
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('unreadable saved setup is wiped and read as "not set up"; saving afterwards works', () async {
    final store = SecureDeviceStore();
    expect(await store.read(), isNull);
    expect(keystore.calls, containsAllInOrder(['read', 'deleteAll']));
    const setup = DeviceSetup(hubBaseUrl: 'https://10.0.0.5:8443/hub/v1', deviceToken: 'tok', fingerprint: 'AA:BB');
    await store.write(setup);
    expect((await store.read())?.deviceToken, 'tok');
    expect(jsonDecode(keystore.values.values.single) as Map, containsPair('deviceToken', 'tok'));
  });

  test('a write that hits the same broken leftovers clears them and saves', () async {
    final store = SecureDeviceStore();
    await store.write(const DeviceSetup(hubBaseUrl: 'https://h/hub/v1', deviceToken: 't2'));
    expect(keystore.calls, containsAllInOrder(['write', 'deleteAll', 'write']));
    expect((await store.read())?.deviceToken, 't2');
  });

  testWidgets('the app opens on the setup sign-in, not "Something went wrong"', (t) async {
    t.view.physicalSize = const Size(360, 740);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(overrides: [hubApiFactoryProvider.overrideWithValue((_) => FakeHubApi())], child: const PosApp()));
    await t.pumpAndSettle();
    expect(find.text('Something went wrong'), findsNothing);
    expect(find.textContaining('BadPadding'), findsNothing);
    expect(find.text('Sign in to set up this device'), findsOneWidget);
  });
}
