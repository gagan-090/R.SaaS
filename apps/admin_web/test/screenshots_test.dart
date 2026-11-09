// Opt-in visual review: renders every console page at phone and tablet sizes, portrait and landscape, with the real
// fonts and icons, and writes PNGs. Overflow tests catch broken layouts; these pictures catch layouts that fit but
// look wrong (oversized cards, stretched rows, wasted space).
//   flutter test test/screenshots_test.dart --update-goldens --dart-define=SHOTS=true --dart-define=SHOTS_DIR=/abs/dir
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/state/providers.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'console_test.dart' show FakeRestaurantApi;
import 'fixture_api.dart';
import 'responsive_matrix_test.dart' show openNav, signIn;

const enabled = bool.fromEnvironment('SHOTS');
const outDir = String.fromEnvironment('SHOTS_DIR', defaultValue: '/tmp/rsaas-shots');

const sizes = <(String, Size)>[
  ('phone-P', Size(390, 844)),
  ('phone-L', Size(844, 390)),
  ('tablet-P', Size(800, 1280)),
  ('tablet-L', Size(1280, 800)),
];

Future<void> loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await l.load();
  }

  const kit = '../../packages/ui_kit/fonts';
  final sans = ['$kit/LiberationSans-Regular.ttf', '$kit/LiberationSans-Bold.ttf', '$kit/LiberationSans-Italic.ttf', '$kit/LiberationSans-BoldItalic.ttf'];
  await load('Arial', sans);
  await load('packages/rsaas_ui_kit/LiberationSans', sans);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/usr/local/share/flutter';
  await load('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
}

Future<void> shot(WidgetTester t, String size, String name) async {
  await t.pumpAndSettle();
  await expectLater(find.byType(AdminApp), matchesGoldenFile(Uri.file('$outDir/admin/$size/$name.png')));
}

void main() {
  setUpAll(() async {
    HPType.useGoogleFonts = false;
    await loadFonts();
  });

  for (final (tag, size) in sizes) {
    testWidgets('[$tag] super admin pages', skip: !enabled, (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final fx = FixtureApi();
      await t.pumpWidget(ProviderScope(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fx.client()))], child: const AdminApp()));
      await t.pumpAndSettle();
      await shot(t, tag, 'sa-00-login');
      await signIn(t, email: 'admin@example.com', mfa: true);
      await shot(t, tag, 'sa-01-dashboard');
      await openNav(t, size, 'Restaurants');
      await shot(t, tag, 'sa-02-restaurants');
      final first = (FixtureApi.fixture('GET_restaurants.json')! as Map)['items'][0] as Map;
      final row = find.byKey(Key('row-${first['code']}'));
      await t.tap(row.evaluate().isNotEmpty ? row : find.text('${first['name']}').first);
      await shot(t, tag, 'sa-03-restaurant-detail');
      for (final (i, page) in ['Plans', 'Admins', 'Audit log'].indexed) {
        if (await openNav(t, size, page)) await shot(t, tag, 'sa-${(i + 4).toString().padLeft(2, '0')}-${page.toLowerCase().replaceAll(' ', '-')}');
      }
    });

    testWidgets('[$tag] restaurant console pages', skip: !enabled, (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final fake = FakeRestaurantApi();
      await t.pumpWidget(ProviderScope(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fake.client()))], child: const AdminApp()));
      await t.pumpAndSettle();
      await signIn(t, email: 'owner@demo.com');
      await shot(t, tag, 'rc-00-home');
      var i = 1;
      for (final page in ['Dashboard', 'Menu', 'Floors & tables', 'Inventory', 'Expenses', 'Audit & records', 'Staff', 'Roles', 'Hubs & devices', 'Settings']) {
        if (await openNav(t, size, page)) await shot(t, tag, 'rc-${(i++).toString().padLeft(2, '0')}-${page.toLowerCase().replaceAll(RegExp(r'[^a-z]+'), '-')}');
      }
    });
  }
}
