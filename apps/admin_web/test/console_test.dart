import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/state/providers.dart';
import 'package:rsaas_admin_web/util/image_prep.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

/// In-memory restaurant API with the same response shapes as apps/api/src/tenant/*.controller.ts.
class FakeRestaurantApi {
  final calls = <http.Request>[];
  final cats = <Map<String, dynamic>>[];
  final items = <Map<String, dynamic>>[];
  final taxes = <Map<String, dynamic>>[];
  final floors = <Map<String, dynamic>>[];
  final staff = <Map<String, dynamic>>[
    {'id': 'u-own', 'name': 'Demo Owner', 'email': 'owner@demo.com', 'status': 'active', 'role': 'owner', 'hasPin': true, 'canDiscount': false},
  ];
  final devices = <Map<String, dynamic>>[
    {'id': 'd1', 'name': 'Cashier phone', 'platform': 'android', 'isHub': true, 'pairedAt': '2026-10-13T04:00:00Z', 'lastSeenAt': DateTime.now().toUtc().toIso8601String(), 'revokedAt': null, 'online': true, 'branch': {'id': 'b1', 'code': 'BR01', 'name': 'MG Road'}},
  ];
  int _n = 0;
  String id(String p) => '$p-${++_n}';

  Map<String, dynamic> me = {
    'type': 'user', 'id': 'u-own', 'email': 'owner@demo.com', 'name': 'Demo Owner', 'tenantId': 't1', 'roles': ['owner'],
    'permissions': ['restaurant.profile.read', 'restaurant.profile.manage', 'license.read', 'staff.read', 'staff.manage', 'device.manage', 'floor.read', 'floor.manage', 'menu.read', 'menu.publish', 'reports.read'],
  };

  Map<String, dynamic> overview() => {
        'restaurant': {'id': 't1', 'code': 'R000000', 'name': 'Demo Dhaba', 'gstin': '27AAAPA1234A1Z5', 'address': 'MG Road, Pune', 'status': 'active'},
        'branches': [{'id': 'b1', 'code': 'BR01', 'name': 'MG Road'}],
        'license': {'state': 'active', 'plan': 'premium', 'planName': 'Premium', 'features': ['menu', 'tables', 'roles.extended', 'kds'], 'limits': {}, 'endsAt': '2026-11-12T00:00:00Z'},
        'counts': {'items': items.length, 'categories': cats.length, 'tables': floors.fold<int>(0, (s, f) => s + (f['tables'] as List).length), 'staff': staff.where((u) => u['status'] == 'active').length, 'devices': devices.length},
        'hub': {'online': true, 'lastSeenAt': DateTime.now().toUtc().toIso8601String()},
      };

  String? lastRange;
  Map<String, dynamic> dashboard() => {
        'range': lastRange ?? '7d', 'dayCount': 7, 'from': '2026-10-07T00:00:00Z',
        'kpis': {
          'salesPaise': 900000, 'bills': 18, 'avgBillPaise': 50000, 'orders': 20, 'dineInPaise': 700000, 'takeawayPaise': 200000,
          'dineInBills': 14, 'takeawayBills': 4, 'discountsPaise': 15000, 'taxesPaise': 42000, 'tipsPaise': 12000,
          'reversals': {'count': 2, 'amountPaise': 18000}, 'adjustments': {'count': 1, 'amountPaise': -2000},
        },
        'previous': {'salesPaise': 800000, 'bills': 16, 'avgBillPaise': 50000},
        'change': {'salesPct': 12.5, 'billsPct': 12.5},
        'series': [for (var i = 0; i < 7; i++) {'day': '2026-10-${(7 + i).toString().padLeft(2, '0')}', 'salesPaise': i * 150000, 'bills': i * 3}],
        'hourly': [for (var h = 0; h < 24; h++) {'hour': h, 'salesPaise': h == 20 ? 500000 : (h == 13 ? 400000 : 0), 'bills': h == 20 ? 10 : (h == 13 ? 8 : 0)}],
        'busiestHour': 20,
        'byMode': {'cash': 300000, 'upi': 500000, 'card': 100000},
        'byCategory': [{'name': 'Mains', 'qty': 40, 'amountPaise': 600000}, {'name': 'Breads', 'qty': 60, 'amountPaise': 120000}],
        'byWaiter': [{'name': 'Anita', 'salesPaise': 500000, 'bills': 9, 'tipsPaise': 8000}, {'name': 'No waiter', 'salesPaise': 200000, 'bills': 4, 'tipsPaise': 0}],
        'topItems': [{'name': 'Butter Chicken', 'category': 'Mains', 'qty': 40, 'amountPaise': 1360000}],
        'reversals': {'items': [], 'reasons': [{'reason': 'Guest changed mind', 'count': 2}]},
        'live': {'openTables': 3, 'takeaways': 1, 'unpaidBills': 2, 'unpaidPaise': 84000},
        'recentBills': [{'id': 'bill-1', 'invoiceNo': 'BR01/26-27/000101', 'totalPaise': 74400, 'status': 'paid', 'createdAt': '2026-10-13T14:00:00Z', 'closedAt': '2026-10-13T14:30:00Z', 'where': 'Table 7', 'waiter': 'Anita'}],
        'today': {'salesPaise': 900000, 'bills': 18, 'avgBillPaise': 50000},
      };

  Map<String, dynamic> billDetail() => {
        'id': 'bill-1', 'invoiceNo': 'BR01/26-27/000101', 'status': 'paid', 'createdAt': '2026-10-13T14:00:00Z', 'closedAt': '2026-10-13T14:30:00Z',
        'where': 'Table 7', 'waiter': 'Anita',
        'totals': {'subtotalPaise': 68000, 'discountPaise': 0, 'cgstPaise': 1700, 'sgstPaise': 1700, 'tipPaise': 3000, 'roundOffPaise': 0, 'totalPaise': 74400},
        'lines': [
          {'name': 'Butter Chicken', 'qty': 2, 'pricePaise': 34000, 'amountPaise': 68000, 'status': 'sent', 'notes': 'less spicy', 'reversalReason': null},
          {'name': 'Naan', 'qty': 3, 'pricePaise': 6000, 'amountPaise': 18000, 'status': 'reversed', 'notes': null, 'reversalReason': 'Guest changed mind'},
        ],
        'payments': [{'mode': 'upi', 'amountPaise': 40000, 'changePaise': 0}, {'mode': 'cash', 'amountPaise': 34400, 'changePaise': 15600}],
        'tips': [{'waiter': 'Anita', 'amountPaise': 3000}],
        'adjustments': [{'amountPaise': -2000, 'reason': 'Naan was cold'}],
      };

  http.Client client() => MockClient((req) async {
        calls.add(req);
        final path = req.url.path.replaceFirst('/api/v1', '');
        final body = req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;
        Object? out;
        var status = 200;
        switch ((req.method, path)) {
          case ('POST', '/auth/login'):
            out = {'status': 'ok', 'accessToken': 'a', 'refreshToken': 'r', 'expiresIn': 900};
          case ('GET', '/me'):
            out = me;
          case ('GET', '/tenant/overview'):
            out = overview();
          case ('GET', '/tenant/dashboard'):
            lastRange = req.url.queryParameters['range'];
            out = dashboard();
          case ('GET', '/tenant/bills/bill-1'):
            out = billDetail();
          case ('GET', '/menu/categories'):
            out = cats;
          case ('POST', '/menu/categories'):
            final c = {'id': id('c'), 'name': body['name'], 'sortOrder': body['sortOrder'] ?? 0};
            cats.add(c);
            out = c;
            status = 201;
          case ('GET', '/menu/items'):
            out = items;
          case ('POST', '/menu/items'):
            final it = {'id': id('i'), 'imageId': null, 'available': true, ...body};
            items.add(it);
            out = it;
            status = 201;
          case ('GET', '/tax-rules'):
            out = taxes;
          case ('POST', '/tax-rules'):
            final t = {'id': id('tx'), 'name': body['name'], 'rateBp': body['rateBp']};
            taxes.add(t);
            out = t;
            status = 201;
          case ('GET', '/floors'):
            out = floors;
          case ('POST', '/floors'):
            final f = {'id': id('f'), 'name': body['name'], 'branchId': body['branchId'], 'sortOrder': 0, 'tables': <Map<String, dynamic>>[]};
            floors.add(f);
            out = f;
            status = 201;
          case ('POST', '/tables'):
            final t = {'id': id('t'), 'name': body['name'], 'seats': body['seats'], 'floorId': body['floorId']};
            (floors.firstWhere((f) => f['id'] == body['floorId'])['tables'] as List).add(t);
            out = t;
            status = 201;
          case ('GET', '/staff'):
            out = staff;
          case ('POST', '/staff'):
            final u = {'id': id('u'), 'name': body['name'], 'role': body['role'], 'status': 'active', 'hasPin': true, 'canDiscount': body['canDiscount'] ?? false, 'email': body['email']};
            staff.add(u);
            out = u;
            status = 201;
          case ('GET', '/devices'):
            out = devices;
          default:
            if (req.method == 'PATCH' && path.startsWith('/menu/items/')) {
              final it = items.firstWhere((i) => i['id'] == path.split('/').last);
              it.addAll(body);
              out = it;
            } else if (req.method == 'PATCH' && path.startsWith('/staff/')) {
              final u = staff.firstWhere((x) => x['id'] == path.split('/').last);
              u.addAll({for (final e in body.entries) if (e.key != 'pin') e.key: e.value});
              out = u;
            } else if (req.method == 'POST' && path.endsWith('/revoke')) {
              final d = devices.firstWhere((x) => x['id'] == path.split('/')[2]);
              d['revokedAt'] = '2026-10-13T05:00:00Z';
              out = {'id': d['id'], 'revokedAt': d['revokedAt']};
            } else {
              return http.Response('{"code":"not_mocked","message":"${req.method} $path not mocked"}', 404);
            }
        }
        return http.Response.bytes(utf8.encode(jsonEncode(out)), status, headers: {'content-type': 'application/json'});
      });

  Map<String, dynamic> last(String method, String path) => jsonDecode(calls.lastWhere((c) => c.method == method && c.url.path.endsWith(path)).body) as Map<String, dynamic>;
}

const desktop = Size(1440, 900);
const phone = Size(390, 844);

Future<FakeRestaurantApi> start(WidgetTester t, {Size size = desktop, Brightness brightness = Brightness.light}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  t.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
  final fake = FakeRestaurantApi();
  await t.pumpWidget(ProviderScope(
    overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://192.168.1.25:3000/api/v1', client: fake.client()))],
    child: const AdminApp(),
  ));
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('login-email')), 'owner@demo.com');
  await t.enterText(find.byKey(const Key('login-password')), '12345678');
  await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
  await t.pumpAndSettle();
  return fake;
}

Future<void> go(WidgetTester t, String label, {required Size size}) async {
  if (size == phone) {
    await t.tap(find.byKey(const Key('open-nav')));
    await t.pumpAndSettle();
  }
  await t.tap(find.byKey(Key('nav-$label')));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  for (final (size, brightness) in [(desktop, Brightness.light), (phone, Brightness.dark), (phone, Brightness.light)]) {
    final tag = '${size.width.toInt()} ${brightness.name}';

    testWidgets('[$tag] owner lands on the restaurant dashboard with a setup checklist; platform pages are not offered', (t) async {
      await start(t, size: size, brightness: brightness);
      expect(find.text('Demo Dhaba'), findsOneWidget);
      expect(find.textContaining('GET READY FOR SERVICE'), findsOneWidget);
      expect(find.byKey(const Key('kpi-sales')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('kpi-sales')), matching: find.text('₹9,000')), findsOneWidget);
      expect(find.textContaining('▲ 12.5%'), findsWidgets); // sales and bills both up
      expect(find.byKey(const Key('live-strip')), findsOneWidget);
      expect(find.text('Hub online'), findsOneWidget);
      if (size == phone) {
        await t.tap(find.byKey(const Key('open-nav')));
        await t.pumpAndSettle();
      }
      for (final n in ['Menu', 'Floors & tables', 'Staff', 'Hubs & devices', 'Settings']) {
        expect(find.byKey(Key('nav-$n')), findsOneWidget);
      }
      expect(find.byKey(const Key('nav-Restaurants')), findsNothing);
      final theme = Theme.of(t.element(find.byType(Scaffold).first));
      expect(theme.brightness, brightness, reason: 'follows the device setting');
    });

    testWidgets('[$tag] menu: add a category and a dish; price in rupees is sent as paise; sold-out toggle', (t) async {
      final api = await start(t, size: size, brightness: brightness);
      await go(t, 'Menu', size: size);
      expect(find.text('Your menu is empty'), findsOneWidget);
      await t.tap(find.byKey(const Key('add-category')).first);
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('category-name')), 'Mains');
      await t.tap(find.widgetWithText(PrimaryButton, 'Save'));
      await t.pumpAndSettle();
      expect(api.cats.single['name'], 'Mains');

      await t.tap(find.byKey(const Key('add-dish')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('dish-name')), 'Paneer Tikka');
      await t.enterText(find.byKey(const Key('dish-price')), '249.50');
      await t.tap(find.byKey(const Key('save-dish')));
      await t.pumpAndSettle();
      final sent = api.last('POST', '/menu/items');
      expect(sent['pricePaise'], 24950);
      expect(sent['categoryId'], api.cats.single['id']);
      expect(sent['taxRuleId'], api.taxes.single['id'], reason: 'GST 5% is created on the first dish');
      expect((sent['plateColors'] as Map).keys, containsAll(['base', 'sauce', 'garnish']));
      expect(find.byKey(const Key('item-Paneer Tikka')), findsOneWidget);

      await t.tap(find.byKey(const Key('available-Paneer Tikka')));
      await t.pumpAndSettle();
      expect(api.last('PATCH', api.items.single['id'] as String), {'available': false});
    });

    testWidgets('[$tag] staff: PIN is validated; a waiter is added; a person can be turned off', (t) async {
      final api = await start(t, size: size, brightness: brightness);
      await go(t, 'Staff', size: size);
      await t.tap(find.byKey(const Key('add-staff')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('staff-name')), 'Anita');
      await t.enterText(find.byKey(const Key('staff-pin')), '12');
      await t.tap(find.byKey(const Key('save-staff')));
      await t.pumpAndSettle();
      expect(find.text('PIN must be 4–8 digits'), findsOneWidget);
      await t.enterText(find.byKey(const Key('staff-pin')), '4321');
      await t.tap(find.byKey(const Key('save-staff')));
      await t.pumpAndSettle();
      expect(api.last('POST', '/staff'), containsPair('role', 'waiter'));
      expect(api.last('POST', '/staff'), containsPair('pin', '4321'));
      expect(find.byKey(const Key('staff-Anita')), findsOneWidget);

      await t.tap(find.byKey(const Key('staff-Anita')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(DangerButton, 'Turn off'));
      await t.pumpAndSettle();
      expect(api.staff.firstWhere((u) => u['name'] == 'Anita')['status'], 'disabled');
    });

    testWidgets('[$tag] floors & tables: add a floor and a 6-seat table', (t) async {
      final api = await start(t, size: size, brightness: brightness);
      await go(t, 'Floors & tables', size: size);
      await t.tap(find.byKey(const Key('add-floor')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('ask-field')), 'Ground floor');
      await t.tap(find.widgetWithText(PrimaryButton, 'Save'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('add-table')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(ChoiceChip, '6'));
      await t.tap(find.byKey(const Key('save-table')));
      await t.pumpAndSettle();
      expect(api.last('POST', '/tables'), {'floorId': api.floors.single['id'], 'name': '1', 'seats': 6});
      expect(find.byKey(const Key('console-table-1')), findsOneWidget);
    });

    testWidgets('[$tag] hubs & devices: shows the address for the POS and revokes only with a reason', (t) async {
      final api = await start(t, size: size, brightness: brightness);
      await go(t, 'Hubs & devices', size: size);
      expect(find.text('http://192.168.1.25:3000/api/v1'), findsOneWidget);
      expect(find.byKey(const Key('device-Cashier phone')), findsOneWidget);
      await t.tap(find.byTooltip('Revoke'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('reason-field')), 'Phone lost');
      await t.pump();
      await t.tap(find.widgetWithText(DangerButton, 'Revoke'));
      await t.pumpAndSettle();
      expect(api.last('POST', '/revoke'), {'reason': 'Phone lost'});
    });
  }

  test('dish photos are cropped square, capped at 640 px and sent as JPEG', () {
    final src = img.Image(width: 1600, height: 900);
    img.fill(src, color: img.ColorRgb8(217, 98, 43));
    final out = prepareDishPhoto(Uint8List.fromList(img.encodePng(src)));
    expect(out.contentType, 'image/jpeg');
    final back = img.decodeJpg(out.bytes)!;
    expect((back.width, back.height), (640, 640));
    expect(base64Decode(out.base64).length, out.bytes.length);
    expect(() => prepareDishPhoto(Uint8List.fromList(utf8.encode('not an image'))), throwsFormatException);
  });

  for (final size in [desktop, phone]) {
    testWidgets('[${size.width.toInt()}] dashboard: range switch, every section, bill drill-down', (t) async {
      final api = await start(t, size: size);
      expect(api.lastRange, 'today', reason: 'opens on today');
      for (final title in ['SALES BY HOUR · TODAY', 'HOW GUESTS PAID', 'DINE-IN VS TAKEAWAY', 'SALES BY CATEGORY', 'DISCOUNTS, REVERSALS, CORRECTIONS', 'STAFF PERFORMANCE', 'RECENT BILLS']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('Busiest 8 PM'), findsOneWidget);
      expect(find.text('1× Guest changed mind'.replaceFirst('1×', '2×')), findsOneWidget);
      await t.tap(find.text('7 days'));
      await t.pumpAndSettle();
      expect(api.lastRange, '7d');
      expect(find.text('SALES BY DAY · 7 DAYS'), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('recent-BR01/26-27/000101')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('recent-BR01/26-27/000101')));
      await t.pumpAndSettle();
      expect(find.text('Reversed: Guest changed mind'), findsOneWidget);
      expect(find.text('Tip to Anita'), findsOneWidget);
      expect(find.text('Naan was cold'), findsOneWidget);
      expect(find.textContaining('change ₹156'), findsOneWidget);
    });
  }

  testWidgets('settings: plan, status and features read as words, not codes', (t) async {
    await start(t);
    await go(t, 'Settings', size: desktop);
    expect(find.text('Active'), findsWidgets);
    expect(find.text('active'), findsNothing);
    expect(find.text('Kitchen display'), findsOneWidget);
    expect(find.text('kds'), findsNothing);
    expect(find.text('roles.extended'), findsNothing);
  });
}
