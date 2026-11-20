// Opt-in design pack: every console page for each role, 5 views per page (phone light, phone dark, phone full length,
// tablet landscape, desktop), with the real fonts and icons — for redesign work (e.g. Google Stitch).
//   flutter test test/stitch_shots_test.dart --update-goldens --dart-define=SHOTS=true --dart-define=SHOTS_DIR=/abs/dir
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/state/providers.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'console_test.dart' show FakeRestaurantApi;
import 'fixture_api.dart';
import 'responsive_matrix_test.dart' show openNav, signIn;
import 'screenshots_test.dart' show loadFonts;

const enabled = bool.fromEnvironment('SHOTS');
const outDir = String.fromEnvironment('SHOTS_DIR', defaultValue: '/tmp/rsaas-stitch');

/// Optional folder with HelveticaNeue-{Regular,Medium,Bold,Italic,BoldItalic}.ttf (has the ₹ sign); else Liberation Sans.
const fontDir = String.fromEnvironment('FONT_DIR');

Future<void> loadDesignFonts() async {
  if (fontDir.isEmpty) return loadFonts();
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await l.load();
  }

  final sans = [for (final w in ['Regular', 'Medium', 'Bold', 'Italic', 'BoldItalic']) '$fontDir/HelveticaNeue-$w.ttf'];
  for (final fam in ['Arial', 'Roboto', 'packages/rsaas_ui_kit/LiberationSans']) {
    await load(fam, sans);
  }
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/usr/local/share/flutter';
  await load('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
}

/// A restaurant that looks lived in: the 9 categories, real dishes with sizes, two floors of tables, a team, expenses.
void seedRestaurant(FakeRestaurantApi f) {
  f.taxes.add({'id': 'tx5', 'name': 'GST 5%', 'rateBp': 500});
  const cats = ['Beverages', 'Soups', 'Starters', 'Snacks & Fast Food', 'Main Course', 'Chinese', 'Indian Breads', 'Rice & Biryani', 'Desserts'];
  for (final (i, c) in cats.indexed) {
    f.cats.add({'id': 'c$i', 'name': c, 'sortOrder': (i + 1) * 10});
  }
  final dishes = <(int, String, bool, List<(String, int)>)>[
    (0, 'Masala Chai', true, [('Cup', 3000)]), (0, 'Cold Coffee', true, [('300 ml', 9000), ('500 ml', 13000)]), (0, 'Fresh Lime Soda', true, [('Glass', 7000)]),
    (1, 'Tomato Shorba', true, [('Bowl', 11000)]), (1, 'Hot & Sour Soup', false, [('Half', 9000), ('Full', 14000)]),
    (2, 'Paneer Tikka', true, [('Half plate', 18000), ('Full plate', 29000)]), (2, 'Chicken 65', false, [('Half plate', 21000), ('Full plate', 33000)]),
    (3, 'Veg Burger', true, [('Regular', 12000)]), (3, 'Masala Fries', true, [('Regular', 9000)]),
    (4, 'Butter Chicken', false, [('Half', 24000), ('Full', 38000)]), (4, 'Dal Makhani', true, [('Half', 16000), ('Full', 26000)]), (4, 'Kadai Paneer', true, [('Full', 28000)]),
    (5, 'Veg Hakka Noodles', true, [('Half', 14000), ('Full', 22000)]), (5, 'Chilli Chicken', false, [('Dry', 26000), ('Gravy', 27000)]),
    (6, 'Butter Naan', true, [('1 pc', 5000)]), (6, 'Laccha Paratha', true, [('1 pc', 6000)]),
    (7, 'Veg Biryani', true, [('Half', 17000), ('Full', 26000)]), (7, 'Chicken Dum Biryani', false, [('Half', 22000), ('Full', 34000)]),
    (8, 'Gulab Jamun', true, [('2 pcs', 8000)]), (8, 'Rasmalai', true, [('2 pcs', 11000)]),
  ];
  for (final (i, (c, name, veg, sizes)) in dishes.indexed) {
    f.items.add({
      'id': 'i$i', 'code': '${1101 + i}', 'name': name, 'categoryId': 'c$c', 'taxRuleId': 'tx5', 'available': i != 4, 'isVeg': veg, 'imageId': null,
      'pricePaise': sizes.first.$2,
      'variants': [for (final (j, (n, pr)) in sizes.indexed) {'id': 'v$i-$j', 'code': '${1101 + i}-$j', 'name': n, 'pricePaise': pr, 'isDefault': j == 0, 'available': true}],
    });
  }
  Map<String, dynamic> table(String fl, String n, int seats, String shape, num x, num y) =>
      {'id': 't-$fl-$n', 'name': n, 'seats': seats, 'floorId': fl, 'shape': shape, 'x': x, 'y': y, 'width': shape == 'rect' ? 160 : 80, 'height': 80, 'rotation': 0, 'chairs': null, 'status': 'available'};
  f.floors.addAll([
    {'id': 'f1', 'name': 'Ground floor', 'branchId': 'b1', 'sortOrder': 0, 'version': 1, 'width': 1200, 'height': 800, 'tables': [
      table('f1', '1', 4, 'square', 180, 160), table('f1', '2', 4, 'square', 420, 160), table('f1', '3', 2, 'round', 660, 160), table('f1', '4', 2, 'round', 880, 160),
      table('f1', '5', 8, 'rect', 300, 480), table('f1', '6', 6, 'rect', 700, 480), table('f1', '7', 4, 'square', 1000, 480),
    ]},
    {'id': 'f2', 'name': 'Rooftop', 'branchId': 'b1', 'sortOrder': 1, 'version': 1, 'width': 1200, 'height': 800, 'tables': [
      table('f2', 'R1', 4, 'round', 250, 250), table('f2', 'R2', 4, 'round', 600, 250), table('f2', 'R3', 6, 'rect', 450, 550),
    ]},
  ]);
  f.tableLive.addAll({'t-f1-1': 'occupied', 't-f1-5': 'billing', 't-f1-3': 'occupied'});
  f.staff.addAll([
    {'id': 'u-c1', 'name': 'Ravi Kumar', 'email': 'ravi@demo.com', 'status': 'active', 'role': 'cashier', 'hasPin': true, 'canDiscount': true},
    {'id': 'u-w1', 'name': 'Anita Sharma', 'email': 'anita@demo.com', 'status': 'active', 'role': 'waiter', 'hasPin': true, 'canDiscount': false},
    {'id': 'u-w2', 'name': 'Imran Khan', 'email': 'imran@demo.com', 'status': 'active', 'role': 'waiter', 'hasPin': false, 'canDiscount': false},
    {'id': 'u-ch', 'name': 'Kunal Verma', 'email': 'kunal@demo.com', 'status': 'active', 'role': 'chef', 'hasPin': true, 'canDiscount': false},
    {'id': 'u-old', 'name': 'Suresh Pal', 'email': 'suresh@demo.com', 'status': 'disabled', 'role': 'waiter', 'hasPin': true, 'canDiscount': false},
  ]);
  f.expenses.addAll([
    for (final (i, (cat, desc, amt, mode)) in [
      ('Rent', 'November rent — MG Road', 4500000, 'bank'), ('Utilities', 'Electricity bill', 1284000, 'upi'), ('Other', 'Gas cylinders (4)', 440000, 'cash'),
      ('Other', 'Vegetables — Azadpur mandi', 362500, 'cash'), ('Utilities', 'Internet', 99900, 'upi'),
    ].indexed)
      {'id': 'e$i', 'category': cat, 'description': desc, 'amountPaise': amt, 'paymentMode': mode, 'paidOn': '2026-11-${(18 - i).toString().padLeft(2, '0')}', 'reference': null, 'createdByName': 'Demo Owner', 'voidedAt': null, 'voidReason': null},
  ]);
}

/// The 5 views of every page: (file prefix, size, dark).
const views = <(String, Size, bool)>[
  ('1-phone-light', Size(390, 844), false),
  ('2-phone-dark', Size(390, 844), true),
  ('3-phone-full-page', Size(390, 2400), false),
  ('4-tablet-landscape', Size(1280, 800), false),
  ('5-desktop', Size(1440, 900), false),
];

String slug(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');

void main() {
  setUpAll(() async {
    HPType.useGoogleFonts = false;
    await loadDesignFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({})); // each view starts in the light theme

  Future<void> boot(WidgetTester t, Size size, bool dark, http.Client client) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: client))], child: const AdminApp()));
    await t.pumpAndSettle();
    if (dark) {
      await ProviderScope.containerOf(t.element(find.byType(AdminApp))).read(themeModeProvider.notifier).set(ThemeMode.dark);
      await t.pumpAndSettle();
    }
  }

  for (final (view, size, dark) in views) {
    Future<void> shot(WidgetTester t, String role, String page) async {
      await t.pumpAndSettle();
      await expectLater(find.byType(AdminApp), matchesGoldenFile(Uri.file('$outDir/web-console/$role/${slug(page)}/$view.png')));
    }

    testWidgets('[$view] super admin', skip: !enabled, (t) async {
      final fx = FixtureApi();
      await boot(t, size, dark, fx.client());
      await shot(t, 'super-admin', '00 Sign in');
      await signIn(t, email: 'admin@example.com', mfa: true);
      await shot(t, 'super-admin', '01 Dashboard');
      await openNav(t, size, 'Restaurants');
      await shot(t, 'super-admin', '02 Restaurants');
      final first = (FixtureApi.fixture('GET_restaurants.json')! as Map)['items'][0] as Map;
      final row = find.byKey(Key('row-${first['code']}'));
      await t.tap(row.evaluate().isNotEmpty ? row : find.text('${first['name']}').first);
      await shot(t, 'super-admin', '03 Restaurant detail');
      for (final (i, page) in ['Plans', 'Admins', 'Audit log'].indexed) {
        if (await openNav(t, size, page)) await shot(t, 'super-admin', '0${i + 4} $page');
      }
    });

    testWidgets('[$view] restaurant owner console', skip: !enabled, (t) async {
      final fake = FakeRestaurantApi()..brandingInPlan = true;
      seedRestaurant(fake);
      await boot(t, size, dark, fake.client());
      await shot(t, 'restaurant-owner', '00 Sign in');
      await signIn(t, email: 'owner@demo.com');
      await shot(t, 'restaurant-owner', '01 Home');
      var i = 2;
      for (final page in ['Dashboard', 'Menu', 'Floors & tables', 'Inventory', 'Expenses', 'Audit & records', 'Staff', 'Roles', 'Hubs & devices', 'Settings']) {
        if (await openNav(t, size, page)) await shot(t, 'restaurant-owner', '${i.toString().padLeft(2, '0')} $page');
        i++;
      }
    });
  }
}
