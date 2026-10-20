import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/state/providers.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fixture_api.dart';

/// Every Super Admin page on a phone (390 × 844) in light and dark: any overflow fails the test.
void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('[390 ${brightness.name}] Super Admin pages fit a phone', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(t.view.reset);
      addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
      final fx = FixtureApi()
        ..overrides['GET /restaurants/registrations'] = (200, {
          'counts': {'awaiting': 1, 'expired': 0},
          'items': [
            {
              'id': 'r1', 'restaurantName': 'A Very Long Restaurant Name That Wraps', 'ownerName': 'Meera', 'ownerEmail': 'meera.longname@example.test',
              'planCode': 'premium', 'planName': 'Premium', 'createdAt': '2026-10-13T08:00:00Z', 'expiresAt': '2026-10-16T08:00:00Z',
              'lastSentAt': '2026-10-13T08:00:00Z', 'sendCount': 2, 'lastEmailError': 'You can only send testing emails to your own email address',
              'cancelledAt': null, 'cancelReason': null, 'state': 'awaiting',
            },
          ],
        });
      await t.pumpWidget(ProviderScope(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fx.client()))], child: const AdminApp()));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('login-email')), 'admin@example.com');
      await t.enterText(find.byKey(const Key('login-password')), 'pw');
      await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('mfa-code')), '123456');
      await t.tap(find.widgetWithText(PrimaryButton, 'Verify'));
      await t.pumpAndSettle();

      // dashboard: 2-column KPI grid and the attention list
      expect(find.byKey(const Key('kpi-Awaiting verification')), findsOneWidget);
      expect(find.text('NEEDS YOUR ATTENTION'), findsOneWidget);
      final card = t.getSize(find.byKey(const Key('kpi-Awaiting verification')));
      expect(card.width, lessThan(200), reason: 'two KPI cards per row on a phone');

      Future<void> go(String label) async {
        await t.tap(find.byKey(const Key('open-nav')));
        await t.pumpAndSettle();
        // the open Admins sub-menu can push later items below the fold of the drawer
        await t.scrollUntilVisible(find.byKey(Key('nav-$label')), 200, scrollable: find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable)).first);
        await t.pumpAndSettle();
        await t.tap(find.byKey(Key('nav-$label')));
        await t.pumpAndSettle();
      }

      await go('Restaurants');
      await t.tap(find.descendant(of: find.byKey(const Key('restaurants-tabs')), matching: find.text('Awaiting verification')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('registration-A Very Long Restaurant Name That Wraps')), findsOneWidget);
      await t.tap(find.descendant(of: find.byKey(const Key('restaurants-tabs')), matching: find.text('Restaurants')));
      await t.pumpAndSettle();
      final first = (FixtureApi.fixture('GET_restaurants.json')! as Map)['items'][0] as Map;
      await t.tap(find.byKey(Key('row-${first['code']}')));
      await t.pumpAndSettle();
      expect(find.byTooltip('Back to restaurants'), findsOneWidget);
      await t.scrollUntilVisible(find.text('HISTORY'), 400, scrollable: find.byType(Scrollable).first);
      expect(find.text('HISTORY'), findsOneWidget);

      await go('Plans');
      await go('Admins');
      await go('Audit log');
    });
  }
}
