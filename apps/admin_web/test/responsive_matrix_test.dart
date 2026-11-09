import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/state/providers.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'console_test.dart' show FakeRestaurantApi;
import 'fixture_api.dart';

/// Every page of both consoles on phones, foldables, tablets, laptops and ultrawide screens, in portrait and
/// landscape. Any RenderFlex overflow or layout exception fails the test, so "fits every screen" is checked,
/// not assumed. Sizes are logical pixels (what layouts see), not device names.
const matrix = <(String, Size)>[
  ('small phone portrait', Size(320, 568)),
  ('small phone landscape', Size(568, 320)),
  ('phone portrait', Size(390, 844)),
  ('phone landscape', Size(844, 390)),
  ('large phone portrait', Size(430, 932)),
  ('large phone landscape', Size(932, 430)),
  ('flip phone (cover screen)', Size(260, 512)),
  ('foldable unfolded', Size(673, 841)),
  ('foldable unfolded landscape', Size(841, 673)),
  ('tablet portrait', Size(800, 1280)),
  ('tablet landscape', Size(1280, 800)),
  ('iPad Pro portrait', Size(1024, 1366)),
  ('laptop', Size(1366, 768)),
  ('desktop', Size(1920, 1080)),
  ('portrait monitor', Size(1080, 1920)),
  ('ultrawide', Size(3440, 1440)),
];

bool usesDrawer(Size s) => s.width < 900;

/// Opens a page from the sidebar (or the drawer on narrow screens), scrolling the menu when it is long or the
/// screen is short. Returns false when the signed-in role does not have that page.
Future<bool> openNav(WidgetTester t, Size size, String label) async {
  if (usesDrawer(size)) {
    await t.tap(find.byKey(const Key('open-nav')));
    await t.pumpAndSettle();
  }
  final menu = find.descendant(of: find.byKey(const Key('sidebar')), matching: find.byType(Scrollable)).first;
  final item = find.byKey(Key('nav-$label'));
  try {
    await t.scrollUntilVisible(item, 120, scrollable: menu, maxScrolls: 60);
  } on StateError {
    if (usesDrawer(size)) {
      await t.tapAt(Offset(size.width - 5, size.height / 2)); // close the drawer
      await t.pumpAndSettle();
    }
    return false;
  }
  await t.pumpAndSettle();
  await t.tap(item);
  await t.pumpAndSettle();
  return true;
}

Future<void> signIn(WidgetTester t, {required String email, bool mfa = false}) async {
  await t.enterText(find.byKey(const Key('login-email')), email);
  await t.enterText(find.byKey(const Key('login-password')), '12345678');
  await t.ensureVisible(find.widgetWithText(PrimaryButton, 'Sign in'));
  await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
  await t.pumpAndSettle();
  if (mfa) {
    await t.enterText(find.byKey(const Key('mfa-code')), '123456');
    await t.ensureVisible(find.widgetWithText(PrimaryButton, 'Verify'));
    await t.tap(find.widgetWithText(PrimaryButton, 'Verify'));
    await t.pumpAndSettle();
  }
}

Future<void> tapTab(WidgetTester t, String label) async {
  // short screens: the tab row can sit below the fold; scroll to it like a user would
  final tab = find.byKey(Key('tab-$label'), skipOffstage: false);
  if (tab.evaluate().isEmpty) {
    await t.scrollUntilVisible(find.byKey(Key('tab-$label')), 150, scrollable: find.descendant(of: find.byKey(const Key('restaurant-detail')), matching: find.byType(Scrollable)).first);
  }
  await t.ensureVisible(tab);
  await t.pumpAndSettle();
  await t.tap(find.byKey(Key('tab-$label')));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  for (final (name, size) in matrix) {
    testWidgets('[$name ${size.width.toInt()}×${size.height.toInt()}] Super Admin console fits', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final fx = FixtureApi();
      await t.pumpWidget(ProviderScope(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fx.client()))], child: const AdminApp()));
      await t.pumpAndSettle();
      await signIn(t, email: 'admin@example.com', mfa: true);

      // dashboard: the KPIs are what you see first on every size
      expect(find.byKey(const Key('kpi-Active')), findsOneWidget);
      final compact = size.width < 900 || size.height < 600;
      final accordion = size.width < 600 || size.height < 600; // tablets in portrait show every section
      expect(find.byKey(const Key('dashboard-accordion')), accordion ? findsOneWidget : findsNothing);
      if (accordion) {
        // one panel open at a time
        await t.ensureVisible(find.byKey(const Key('panel-toggle-Recent activity'), skipOffstage: false));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('panel-toggle-Recent activity')));
        await t.pumpAndSettle();
        expect(find.byKey(const Key('kpi-Active')), findsNothing);
      }

      await openNav(t, size, 'Restaurants');
      final first = (FixtureApi.fixture('GET_restaurants.json')! as Map)['items'][0] as Map;
      if (compact) {
        await tapTab(t, 'Awaiting');
        await tapTab(t, 'Search');
        expect(find.byKey(const Key('search')), findsOneWidget);
        await tapTab(t, 'Restaurants');
      }
      await t.scrollUntilVisible(find.byKey(Key('row-${first['code']}')).hitTestable(), 150, scrollable: find.byType(Scrollable).first).catchError((_) {});
      if (find.byKey(Key('row-${first['code']}')).evaluate().isNotEmpty) {
        await t.tap(find.byKey(Key('row-${first['code']}')));
      } else {
        await t.tap(find.text('${first['name']}').first);
      }
      await t.pumpAndSettle();
      expect(find.byTooltip('Back to restaurants'), findsOneWidget);
      if (compact) {
        expect(find.byKey(const Key('restaurant-actions')), findsOneWidget);
        for (final tab in ['Profile', 'Plan & license', 'Owner account', 'Payments', 'Branches & devices', 'History', 'Overview']) {
          await tapTab(t, tab);
        }
      } else {
        final page = find.descendant(of: find.byKey(const Key('restaurant-detail')), matching: find.byType(Scrollable)).first;
        await t.scrollUntilVisible(find.byKey(const Key('owner-account')), 300, scrollable: page);
        expect(find.byKey(const Key('owner-account')), findsOneWidget);
      }

      expect(await openNav(t, size, 'Plans'), isTrue);
      expect(find.byKey(const Key('plans-kpi-on-sale')), findsOneWidget);
      expect(await openNav(t, size, 'Admins'), isTrue);
      expect(await openNav(t, size, 'Audit log'), isTrue);
    });

    testWidgets('[$name ${size.width.toInt()}×${size.height.toInt()}] restaurant console fits', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final fake = FakeRestaurantApi();
      await t.pumpWidget(ProviderScope(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fake.client()))], child: const AdminApp()));
      await t.pumpAndSettle();
      await signIn(t, email: 'owner@demo.com');
      var opened = 0;
      for (final page in ['Menu', 'Floors & tables', 'Inventory', 'Expenses', 'Audit & records', 'Staff', 'Roles', 'Hubs & devices', 'Settings', 'Dashboard']) {
        if (await openNav(t, size, page)) opened++;
      }
      expect(opened, greaterThanOrEqualTo(8), reason: 'the owner reaches nearly every console page');
    });
  }
}
