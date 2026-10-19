import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/screens/console/floor_editor.dart';
import 'package:rsaas_admin_web/screens/console/import_dialog.dart';
import 'package:rsaas_admin_web/util/download.dart';
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
  final customRoles = <Map<String, dynamic>>[];
  final tableLive = <String, String>{}; // table id → occupied / billing from synced orders
  bool inventoryInPlan = true;
  bool noPlan = false; // license revoked: every plan-gated route answers 403 feature_not_in_plan
  int failNextMovement = 0; // simulate a dropped connection: the client must retry with the same key
  final movements = <Map<String, dynamic>>[];
  final products = <Map<String, dynamic>>[
    {'id': 'p1', 'sku': 'RICE-BAS', 'name': 'Basmati rice', 'category': 'Grains', 'baseUnit': 'g', 'purchaseUnit': 'kg', 'conversionFactor': 1000, 'unitCostPaise': 6000, 'avgCostPaise': 6, 'minStock': 5000, 'active': true, 'stock': 2000, 'valuePaise': 12000, 'low': true, 'negative': false, 'expiring': <Object>[], 'defaultSupplierId': null, 'defaultLocationId': null},
  ];
  final expenses = <Map<String, dynamic>>[];
  Map<String, dynamic>? importJob;
  List<String> features = ['menu', 'tables', 'roles.extended', 'kds', 'floor.editor'];
  int _n = 0;
  String id(String p) => '$p-${++_n}';

  Map<String, dynamic> me = {
    'type': 'user', 'id': 'u-own', 'email': 'owner@demo.com', 'name': 'Demo Owner', 'tenantId': 't1', 'roles': ['owner'],
    'tenant': {'id': 't1', 'code': 'R000000', 'name': 'Demo Dhaba'},
    'permissions': ['restaurant.profile.read', 'restaurant.profile.manage', 'license.read', 'staff.read', 'staff.manage', 'device.manage', 'floor.read', 'floor.manage', 'menu.read', 'menu.publish', 'reports.read', 'order.write',
      'inventory.read', 'inventory.manage', 'inventory.write', 'inventory.consume', 'inventory.request', 'expense.read', 'expense.write', 'import.run'],
  };

  bool brandingInPlan = false;
  Map<String, dynamic>? brand; // saved look
  static const brandDefaults = {'color': '#6B1F2A', 'textSize': 'standard', 'headingWeight': 'bold', 'headingCase': 'normal', 'logoImageId': null};

  Map<String, dynamic> overview() => {
        'branding': brandingInPlan ? brand : null,
        'restaurant': {'id': 't1', 'code': 'R000000', 'name': 'Demo Dhaba', 'gstin': '27AAAPA1234A1Z5', 'address': 'MG Road, Pune', 'status': 'active'},
        'branches': [{'id': 'b1', 'code': 'BR01', 'name': 'MG Road'}],
        'license': noPlan
            ? {'state': 'none', 'plan': null, 'planName': null, 'features': <String>[], 'limits': {}, 'endsAt': null}
            : {'state': 'active', 'plan': 'premium', 'planName': 'Premium', 'features': features, 'limits': {}, 'endsAt': '2026-11-12T00:00:00Z'},
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
        if (noPlan && (path.startsWith('/menu/') || path.startsWith('/floors'))) {
          return http.Response('{"code":"feature_not_in_plan","message":"Your plan does not include \\"menu\\""}', 403);
        }
        switch ((req.method, path)) {
          case ('POST', '/auth/login'):
            out = {'status': 'ok', 'accessToken': 'a', 'refreshToken': 'r', 'expiresIn': 900};
          case ('GET', '/me'):
            out = me;
          case ('GET', '/tenant/overview'):
            out = overview();
          case ('GET', '/tenant/branding'):
            out = {'enabled': brandingInPlan, 'branding': brandingInPlan ? brand : null, 'saved': brand ?? brandDefaults, 'defaults': brandDefaults};
          case ('PUT', '/tenant/branding'):
            if (!brandingInPlan) return http.Response('{"code":"feature_not_in_plan","message":"Not in your plan"}', 403);
            brand = {...brandDefaults, ...?brand, ...body};
            out = brand;
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
            final vs = [for (final v in (body['variants'] as List).cast<Map<String, dynamic>>()) {'id': id('v'), 'code': v['code'] ?? 'C${++_n}', ...v}];
            final it = {'id': id('i'), 'code': 'ITEM-${items.length + 1}', 'imageId': null, 'available': true, ...body, 'variants': vs,
              'pricePaise': (vs.firstWhere((v) => v['isDefault'] == true, orElse: () => vs.first))['pricePaise']};
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
            final n = (floors.firstWhere((f) => f['id'] == body['floorId'])['tables'] as List).length;
            final t = {'id': id('t'), 'name': body['name'], 'seats': body['seats'], 'floorId': body['floorId'], 'shape': 'square', 'x': 120 + n * 160, 'y': 120, 'width': 80, 'height': 80, 'rotation': 0, 'chairs': null, 'status': 'available'};
            (floors.firstWhere((f) => f['id'] == body['floorId'])['tables'] as List).add(t);
            out = t;
            status = 201;
          case ('GET', '/staff'):
            out = staff;
          case ('POST', '/staff'):
            final u = {'id': id('u'), 'name': body['name'], 'role': body['role'], 'status': body['status'] ?? 'active', 'hasPin': body['pin'] != null, 'canDiscount': body['canDiscount'] ?? false, 'email': body['email'], 'webAccess': body['webAccess'] ?? false};
            staff.add(u);
            out = {...u, 'invite': body['sendInvite'] == true ? {'emailSent': true} : null};
            status = 201;
          case ('GET', '/devices'):
            out = devices;
          case ('GET', '/inventory/products'):
            if (!inventoryInPlan) return http.Response('{"code":"feature_not_in_plan","message":"Your plan does not include this"}', 403);
            out = products;
          case ('POST', '/inventory/products'):
            final pr = {...body, 'id': id('p'), 'stock': 0, 'valuePaise': 0, 'low': false, 'negative': false, 'expiring': <Object>[], 'avgCostPaise': 0};
            products.add(pr);
            out = pr;
            status = 201;
          case ('GET', '/inventory/locations'):
            out = [];
          case ('GET', '/inventory/suppliers'):
            out = [];
          case ('GET', '/inventory/alerts'):
            out = {'low': [for (final x in products.where((x) => x['low'] == true)) {'id': x['id'], 'sku': x['sku'], 'name': x['name'], 'stock': x['stock'], 'minStock': x['minStock'], 'unit': x['baseUnit']}], 'negative': [], 'expiring': []};
          case ('GET', '/inventory/movements'):
            out = movements;
          case ('GET', '/inventory/requests'):
            out = [];
          case ('GET', '/inventory/valuation'):
            out = {'method': 'Moving weighted-average cost per base unit', 'totalPaise': 12000, 'byCategory': [{'category': 'Grains', 'valuePaise': 12000}], 'thisMonth': [], 'products': []};
          case ('POST', '/inventory/movements'):
            if (failNextMovement > 0) {
              failNextMovement--;
              return http.Response('{"code":"unreachable","message":"Network error"}', 503);
            }
            final dup = movements.where((m) => m['idempotencyKey'] == body['idempotencyKey']).toList();
            if (dup.isEmpty) movements.add({...body, 'id': id('m'), 'productName': 'Basmati rice', 'baseUnit': 'g', 'quantity': 10000, 'valuePaise': 70000, 'createdAt': '2026-10-14T10:00:00Z', 'actorName': 'Demo Owner'});
            out = {'duplicate': dup.isNotEmpty, 'movements': [movements.firstWhere((m) => m['idempotencyKey'] == body['idempotencyKey'])]};
            status = 201;
          case ('GET', '/expenses'):
            final live = expenses.where((e) => e['voidedAt'] == null).toList();
            out = {'totalPaise': live.fold<int>(0, (s, e) => s + (e['amountPaise'] as int)), 'byCategory': [], 'items': expenses, 'categories': ['Rent', 'Utilities', 'Other']};
          case ('POST', '/expenses'):
            final e = {'id': id('e'), ...body, 'createdByName': 'Demo Owner', 'voidedAt': null, 'voidReason': null};
            expenses.add(e);
            out = e;
            status = 201;
          case ('GET', '/imports/templates/menu'):
          case ('GET', '/imports/templates/inventory'):
            return http.Response.bytes([0x50, 0x4b, 3, 4], 200, headers: {'content-type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'});
          case ('POST', '/imports/inventory/validate'):
            importJob = {
              'id': 'stock-job', 'kind': 'inventory', 'mode': body['mode'], 'fileName': body['fileName'], 'status': 'validated',
              'counts': {'productsCreate': 1, 'productsUpdate': 0, 'openingMovements': 1, 'openingValuePaise': 5000, 'suppliersCreate': 0, 'locationsCreate': 0},
              'issues': [], 'canCommit': true, 'canCommitPartially': true,
              'preview': {'products': [{'sku': 'RICE', 'op': 'create', 'data': {'name': 'Rice'}}],
                'opening': [{'sku': 'RICE', 'baseQty': 1000, 'baseUnit': 'g', 'valuePaise': 5000}]},
            };
            out = importJob;
          case ('POST', '/imports/stock-job/commit'):
            importJob = {...importJob!, 'status': 'committed', 'result': {'productsCreated': 1, 'productsUpdated': 0, 'openingMovements': 1, 'skipped': []}};
            out = importJob;
          case ('POST', '/imports/menu/validate'):
            importJob = {
              'id': 'job-1', 'kind': 'menu', 'mode': body['mode'], 'fileName': body['fileName'], 'status': 'invalid',
              'counts': {'itemsCreate': 2, 'itemsUpdate': 0, 'variantsCreate': 3, 'variantsUpdate': 0, 'categoriesCreate': 1, 'recipes': 0},
              'issues': [{'sheet': 'Variants', 'row': 4, 'column': 'selling_price', 'message': 'Use at most 2 decimals (paise)', 'severity': 'error'}],
              'canCommit': false, 'canCommitPartially': true,
              'preview': {
                'categoriesToCreate': ['Soft Drinks'],
                'items': [{'row': 2, 'code': 'COLA', 'op': 'create', 'data': {'name': 'Cola', 'category': 'Soft Drinks'}}],
                'variants': [{'row': 2, 'itemCode': 'COLA', 'code': 'COLA-500', 'op': 'create', 'data': {'name': '500 ml', 'pricePaise': 5000}}],
                'recipes': [],
              },
            };
            out = importJob;
          case ('POST', '/imports/job-1/commit'):
            if (body['partial'] != true) return http.Response('{"code":"import_has_errors","message":"Fix the errors"}', 409);
            importJob = {...importJob!, 'status': 'partially_committed', 'result': {'itemsCreated': 1, 'variantsCreated': 1, 'skipped': [{'sheet': 'Variants', 'row': 4, 'code': 'WATER-1L'}]}};
            out = importJob;
          case ('GET', '/imports/job-1/errors.csv'):
            return http.Response('severity,sheet,row,column,problem', 200, headers: {'content-type': 'text/csv'});
          case ('GET', '/staff/limits'):
            out = {'employeeLimit': null, 'activeEmployees': staff.where((u) => u['status'] == 'active').length - 1, 'staffPortal': true, 'customRoles': true, 'extendedRoles': true, 'planActive': !noPlan};
          case ('GET', '/roles'):
            out = {'builtIn': [], 'custom': customRoles, 'catalog': [], 'customRolesInPlan': true};
          case ('PUT', '/me/pin'):
            staff.firstWhere((x) => x['id'] == me['id'])['hasPin'] = true;
            out = {'id': me['id'], 'hasPin': true};
          default:
            if (req.method == 'PATCH' && path.startsWith('/menu/items/')) {
              final it = items.firstWhere((i) => i['id'] == path.split('/').last);
              it.addAll(body);
              out = it;
            } else if (req.method == 'PATCH' && path.startsWith('/staff/')) {
              final u = staff.firstWhere((x) => x['id'] == path.split('/').last);
              u.addAll({for (final e in body.entries) if (e.key != 'pin') e.key: e.value});
              out = u;
            } else if (path.startsWith('/floors/') && path.endsWith('/layout')) {
              final f = floors.firstWhere((x) => x['id'] == path.split('/')[2]);
              if (req.method == 'PUT') {
                if (body['version'] != (f['version'] ?? 1)) return http.Response('{"code":"layout_changed","message":"Someone else saved this floor"}', 409);
                f['version'] = (f['version'] as int? ?? 1) + 1;
                f['width'] = body['width'];
                f['height'] = body['height'];
                f['tables'] = [for (final t in (body['tables'] as List).cast<Map<String, dynamic>>()) {'id': t['id'] ?? id('t'), 'floorId': f['id'], 'status': 'available', ...t}];
              }
              out = {
                'floor': {'id': f['id'], 'name': f['name'], 'width': f['width'] ?? 1200, 'height': f['height'] ?? 800, 'version': f['version'] ?? 1},
                'tables': [for (final t in (f['tables'] as List).cast<Map<String, dynamic>>()) {...t, 'live': tableLive[t['id']] ?? t['status'] ?? 'available'}],
                'warnings': [],
              };
            } else if (req.method == 'POST' && path.startsWith('/tables/') && path.endsWith('/status')) {
              final tid = path.split('/')[2];
              for (final f in floors) {
                for (final t in (f['tables'] as List).cast<Map<String, dynamic>>()) {
                  if (t['id'] == tid) t['status'] = body['status'];
                }
              }
              out = {'id': tid, 'status': body['status']};
            } else if (req.method == 'POST' && path.startsWith('/expenses/') && path.endsWith('/void')) {
              final e = expenses.firstWhere((x) => x['id'] == path.split('/')[2]);
              e['voidedAt'] = '2026-10-14T10:00:00Z';
              e['voidReason'] = body['reason'];
              out = {'id': e['id'], 'voided': true};
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

Future<FakeRestaurantApi> start(WidgetTester t, {Size size = desktop, Brightness brightness = Brightness.light, void Function(FakeRestaurantApi)? setup}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  t.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
  final fake = FakeRestaurantApi();
  setup?.call(fake);
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
      expect(theme.brightness, Brightness.light, reason: 'the white theme is the default, whatever the device uses');
      expect(theme.scaffoldBackgroundColor, HPColors.white);
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
      await t.tap(find.byKey(const Key('save-dish')));
      await t.pumpAndSettle();
      expect(find.text('Enter a price in rupees for Regular, e.g. 249'), findsOneWidget);
      await t.enterText(find.byKey(const Key('size-name-0')), 'Full plate');
      await t.enterText(find.byKey(const Key('size-price-0')), '249.50');
      await t.ensureVisible(find.byKey(const Key('add-size')));
      await t.tap(find.byKey(const Key('add-size')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('size-name-1')), 'Half plate');
      await t.enterText(find.byKey(const Key('size-price-1')), '150');
      await t.enterText(find.byKey(const Key('size-qty-1')), '1');
      await t.ensureVisible(find.byKey(const Key('save-dish')));
      await t.tap(find.byKey(const Key('save-dish')));
      await t.pumpAndSettle();
      expect(find.text('Give Half plate both a serving quantity and a unit, or neither'), findsOneWidget);
      await t.enterText(find.byKey(const Key('size-qty-1')), '');
      await t.tap(find.byKey(const Key('save-dish')));
      await t.pumpAndSettle();
      final sent = api.last('POST', '/menu/items');
      final sizes = (sent['variants'] as List).cast<Map>();
      expect([for (final v in sizes) (v['name'], v['pricePaise'], v['isDefault'])], [('Full plate', 24950, true), ('Half plate', 15000, false)]);
      expect(find.textContaining('· 2 sizes'), findsOneWidget);
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
      await t.tap(find.byKey(const Key('save-staff')));
      await t.pumpAndSettle();
      expect(find.text('Enter their work email'), findsOneWidget);
      await t.enterText(find.byKey(const Key('staff-email')), 'anita@demo.com');
      await t.ensureVisible(find.byKey(const Key('pin-now')));
      await t.tap(find.byKey(const Key('pin-now')));
      await t.pumpAndSettle();
      for (final (bad, msg) in [('12', 'PIN must be 6 to 8 digits'), ('111111', 'PIN cannot be the same digit repeated'), ('123456', 'PIN cannot be a run of digits like 123456')]) {
        await t.enterText(find.byKey(const Key('staff-pin')), bad);
        await t.tap(find.byKey(const Key('save-staff')));
        await t.pumpAndSettle();
        expect(find.text(msg), findsOneWidget);
      }
      await t.enterText(find.byKey(const Key('staff-pin')), '482913');
      await t.tap(find.byKey(const Key('save-staff')));
      await t.pumpAndSettle();
      expect(api.last('POST', '/staff'), allOf(containsPair('role', 'waiter'), containsPair('pin', '482913'), containsPair('email', 'anita@demo.com')));
      expect(api.last('POST', '/staff').containsKey('sendInvite'), isFalse);
      expect(find.byKey(const Key('staff-Anita')), findsOneWidget);

      await t.tap(find.byKey(const Key('staff-Anita')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('staff-active')));
      await t.tap(find.byKey(const Key('staff-active')));
      await t.tap(find.byKey(const Key('save-staff')));
      await t.pumpAndSettle();
      expect(api.staff.firstWhere((u) => u['name'] == 'Anita')['status'], 'disabled');
    });

    testWidgets('[$tag] staff: invite by email is the default; web access depends on the plan', (t) async {
      final api = await start(t, size: size, brightness: brightness);
      await go(t, 'Staff', size: size);
      await t.tap(find.byKey(const Key('add-staff')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('staff-name')), 'Kunal');
      await t.enterText(find.byKey(const Key('staff-email')), 'kunal@demo.com');
      await t.ensureVisible(find.byKey(const Key('web-access')));
      await t.tap(find.byKey(const Key('web-access')));
      await t.tap(find.byKey(const Key('save-staff')));
      await t.pumpAndSettle();
      expect(api.last('POST', '/staff'), allOf(containsPair('sendInvite', true), containsPair('webAccess', true)));
      expect(api.last('POST', '/staff').containsKey('pin'), isFalse);
      expect(find.textContaining('Invite sent to kunal@demo.com'), findsOneWidget);
    });

    testWidgets('[$tag] staff: an owner with no PIN is told so and sets their own', (t) async {
      final api = await start(t, size: size, brightness: brightness);
      api.staff.first['hasPin'] = false;
      await go(t, 'Staff', size: size);
      expect(find.byKey(const Key('no-pin-banner')), findsOneWidget);
      expect(find.text('No PIN'), findsOneWidget);
      await t.tap(find.byKey(const Key('set-my-pin')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('my-pin')), '246813');
      await t.enterText(find.byKey(const Key('my-pin-again')), '246814');
      await t.tap(find.byKey(const Key('save-my-pin')));
      await t.pumpAndSettle();
      expect(find.text('The two PINs do not match'), findsOneWidget);
      await t.enterText(find.byKey(const Key('my-pin-again')), '246813');
      await t.tap(find.byKey(const Key('save-my-pin')));
      await t.pumpAndSettle();
      expect(api.last('PUT', '/me/pin'), {'pin': '246813'});
      expect(find.byKey(const Key('no-pin-banner')), findsNothing);
      expect(find.text('PIN set'), findsOneWidget);
    });

    testWidgets('[$tag] floors & tables: add a floor and a 6-seat table', (t) async {
      final api = await start(t, size: size, brightness: brightness);
      await go(t, 'Floors & tables', size: size);
      await t.tap(find.byKey(const Key('add-floor')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('ask-field')), 'Ground floor');
      await t.tap(find.widgetWithText(PrimaryButton, 'Save'));
      await t.pumpAndSettle();
      await t.tap(find.text('List'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('add-table')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(ChoiceChip, '6'));
      await t.tap(find.byKey(const Key('save-table')));
      await t.pumpAndSettle();
      expect(api.last('POST', '/tables'), {'floorId': api.floors.single['id'], 'name': '1', 'seats': 6});
      expect(find.byKey(const Key('console-table-1')), findsOneWidget);
    });

    testWidgets('[$tag] floor plan: edit, add, move, rotate, duplicate names refused, overlap warned, save persists', (t) async {
      final api = await start(t, size: size, brightness: brightness);
      api.floors.add({'id': 'f1', 'name': 'Ground', 'branchId': 'b1', 'sortOrder': 0, 'version': 1, 'tables': [
        {'id': 't1', 'name': '1', 'seats': 4, 'floorId': 'f1', 'shape': 'square', 'x': 150, 'y': 150, 'width': 80, 'height': 80, 'rotation': 0, 'chairs': null, 'status': 'available'},
        {'id': 't2', 'name': '2', 'seats': 2, 'floorId': 'f1', 'shape': 'round', 'x': 400, 'y': 150, 'width': 80, 'height': 80, 'rotation': 0, 'chairs': null, 'status': 'available'},
      ]});
      api.tableLive['t2'] = 'occupied';
      await go(t, 'Floors & tables', size: size);
      expect(find.byKey(const Key('table-1')), findsOneWidget);
      expect(find.byKey(const Key('chair-1-3')), findsOneWidget, reason: '4 chairs arranged from the seats');
      await t.tap(find.byKey(const Key('edit-plan')));
      await t.pumpAndSettle();
      // select table 1, rename it to "2": duplicate refused on save
      await t.ensureVisible(find.byKey(const Key('table-1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('table-1')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('rotate-right')));
      await t.tap(find.byKey(const Key('rotate-right')));
      await t.tap(find.byKey(const Key('rotate-right')));
      await t.tap(find.byKey(const Key('seats-plus')));
      await t.pumpAndSettle();
      final nameField = find.descendant(of: find.byType(FloorEditor), matching: find.byType(TextFormField)).first;
      await t.ensureVisible(nameField);
      await t.enterText(nameField, '2');
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('save-plan')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('save-plan')));
      await t.pumpAndSettle();
      expect(find.textContaining('Two tables are called "2"'), findsWidgets);
      await t.enterText(nameField, 'Window');
      await t.pumpAndSettle();
      // drag it onto table 2 → overlap warning (allowed)
      await t.ensureVisible(find.byKey(const Key('table-Window')));
      await t.pumpAndSettle();
      await t.drag(find.byKey(const Key('table-Window')), const Offset(250, 0));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('save-plan')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('save-plan')));
      await t.pumpAndSettle();
      final sent = api.last('PUT', '/layout');
      final win = (sent['tables'] as List).cast<Map>().firstWhere((x) => x['name'] == 'Window');
      expect((win['id'], win['rotation'], win['seats']), ('t1', 30, 5));
      expect(win['x'], isNot(150), reason: 'moved');
      expect(sent['version'], 1);
      expect(api.floors.single['version'], 2);
      expect(find.byKey(const Key('table-Window')), findsOneWidget, reason: 'reloaded from the server');
    });

    testWidgets('[$tag] floor plan: without the plan feature it is a live view; staff mark a table reserved', (t) async {
      final api = await start(t, size: size, brightness: brightness);
      api.features = ['menu', 'tables'];
      api.floors.add({'id': 'f1', 'name': 'Ground', 'branchId': 'b1', 'sortOrder': 0, 'version': 1, 'tables': [
        {'id': 't1', 'name': '1', 'seats': 4, 'floorId': 'f1', 'shape': 'square', 'x': 150, 'y': 150, 'width': 80, 'height': 80, 'rotation': 0, 'chairs': null, 'status': 'available'},
      ]});
      await go(t, 'Floors & tables', size: size);
      expect(find.byKey(const Key('editor-locked')), findsOneWidget);
      expect(find.byKey(const Key('edit-plan')), findsNothing);
      await t.ensureVisible(find.byKey(const Key('table-1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('table-1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('status-reserved')));
      await t.pumpAndSettle();
      expect(api.last('POST', '/status'), {'status': 'reserved'});
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

  group('your look (branding)', () {
    tearDown(() => HPBrand.activate(null)); // the highlight colour and heading style are app-wide

    testWidgets('not in the plan: the card says how to get it and nothing can be saved', (t) async {
      await start(t);
      await go(t, 'Settings', size: desktop);
      await t.scrollUntilVisible(find.byKey(const Key('branding-locked')), 300, scrollable: find.byType(Scrollable).last);
      expect(find.text('Custom branding is not in your plan'), findsOneWidget);
      expect(find.byKey(const Key('save-branding')), findsNothing);
    });

    testWidgets('in the plan: colour, size and heading style are saved and the console switches to them', (t) async {
      final api = await start(t);
      api.brandingInPlan = true;
      await go(t, 'Settings', size: desktop);
      await t.scrollUntilVisible(find.byKey(const Key('save-branding')), 300, scrollable: find.byType(Scrollable).last);
      await t.tap(find.byKey(const Key('swatch-#1A73E8')));
      await t.tap(find.text('Large'));
      await t.tap(find.text('AA'));
      await t.pumpAndSettle();
      expect(find.text('SEND TO KITCHEN'), findsOneWidget); // live preview
      await t.enterText(find.byKey(const Key('brand-hex')), 'blue');
      await t.tap(find.byKey(const Key('save-branding')));
      await t.pumpAndSettle();
      expect(find.text('Use a colour like #1A73E8'), findsOneWidget);
      await t.tap(find.byKey(const Key('swatch-#1A73E8')));
      await t.tap(find.byKey(const Key('save-branding')));
      await t.pumpAndSettle();
      expect(api.last('PUT', '/tenant/branding'), {'color': '#1A73E8', 'textSize': 'large', 'headingWeight': 'bold', 'headingCase': 'upper'});
      expect(find.byKey(const Key('brand-name')), findsOneWidget); // sidebar shows the restaurant, not House Plating
      expect(find.text('DEMO DHABA'), findsWidgets);
      expect(HPColors.saffron, const Color(0xFF1A73E8));
      expect(Theme.of(t.element(find.byType(Scaffold).first)).colorScheme.primary, const Color(0xFF1A73E8));
      expect(MediaQuery.of(t.element(find.byType(Scaffold).first)).textScaler, const TextScaler.linear(1.12));
    });
  });

  group('inventory & expenses', () {
    testWidgets('owner receives stock: kg with a cost; a dropped connection retries with the same key so nothing is added twice', (t) async {
      final api = await start(t);
      await go(t, 'Inventory', size: desktop);
      expect(find.byKey(const Key('stock-RICE-BAS')), findsOneWidget);
      expect(find.text('Low'), findsOneWidget);
      await t.tap(find.byKey(const Key('actions-RICE-BAS')));
      await t.pumpAndSettle();
      expect(find.text('Kitchen use'), findsOneWidget);
      await t.tap(find.text('Receive stock'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('mv-qty')), '10');
      await t.enterText(find.byKey(const Key('mv-cost')), '70');
      api.failNextMovement = 1;
      await t.tap(find.byKey(const Key('save-movement')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('mv-error')), findsOneWidget);
      await t.tap(find.byKey(const Key('save-movement'))); // retry
      await t.pumpAndSettle();
      final sent = api.calls.where((c) => c.method == 'POST' && c.url.path.endsWith('/inventory/movements')).map((c) => jsonDecode(c.body) as Map).toList();
      expect(sent.length, 2);
      expect(sent[0]['idempotencyKey'], sent[1]['idempotencyKey']);
      expect(sent.last, allOf(containsPair('type', 'purchase'), containsPair('quantity', 10), containsPair('unit', 'kg'), containsPair('unitCostPaise', 7000)));
      expect(api.movements, hasLength(1));
    });

    testWidgets('a chef sees only kitchen use and wastage; wastage needs a reason', (t) async {
      final api = await start(t, setup: (f) {
        f.me = {...f.me, 'roles': ['chef'], 'permissions': ['menu.read', 'kds.read', 'inventory.read', 'inventory.consume', 'inventory.request']};
      });
      await go(t, 'Inventory', size: desktop);
      expect(find.byKey(const Key('add-product')), findsNothing);
      await t.tap(find.byKey(const Key('actions-RICE-BAS')));
      await t.pumpAndSettle();
      expect(find.text('Receive stock'), findsNothing);
      expect(find.text('Edit product'), findsNothing);
      await t.tap(find.text('Wastage'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('mv-qty')), '200');
      await t.tap(find.byKey(const Key('save-movement')));
      await t.pumpAndSettle();
      expect(find.text('Give a reason'), findsOneWidget);
      await t.tap(find.text('Burnt / over-cooked'));
      await t.tap(find.byKey(const Key('save-movement')));
      await t.pumpAndSettle();
      expect(api.last('POST', '/inventory/movements'), allOf(containsPair('type', 'wastage'), containsPair('reason', 'Burnt / over-cooked'), containsPair('unit', 'g')));
    });

    testWidgets('without inventory in the plan the page explains it', (t) async {
      await start(t, setup: (f) => f.inventoryInPlan = false);
      await go(t, 'Inventory', size: desktop);
      expect(find.byKey(const Key('inventory-locked')), findsOneWidget);
    });

    testWidgets('expenses: add in rupees (sent as paise), void with a reason', (t) async {
      final api = await start(t);
      await go(t, 'Expenses', size: desktop);
      await t.tap(find.byKey(const Key('add-expense')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('expense-desc')), 'Electricity');
      await t.enterText(find.byKey(const Key('expense-amount')), '12345.50');
      await t.tap(find.byKey(const Key('save-expense')));
      await t.pumpAndSettle();
      expect(api.last('POST', '/expenses'), containsPair('amountPaise', 1234550));
      await t.tap(find.byKey(const Key('void-Electricity')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('void-reason')), 'Entered twice');
      await t.tap(find.byKey(const Key('confirm-void')));
      await t.pumpAndSettle();
      expect(api.expenses.single['voidReason'], 'Entered twice');
    });
  });

  for (final zoom in [.5, 1.0, 2.0]) {
    testWidgets('mouse drags tables at zoom $zoom without panning; saved positions reload', (t) async {
      final api = await start(t);
      api.floors.add({'id': 'f1', 'name': 'Ground', 'branchId': 'b1', 'tables': [
        {'id': 't1', 'name': '1', 'seats': 4, 'shape': 'square', 'x': 150, 'y': 150, 'width': 80, 'height': 80, 'rotation': 0, 'chairs': null},
      ]});
      await go(t, 'Floors & tables', size: desktop);
      await t.tap(find.byKey(const Key('edit-plan')));
      await t.pumpAndSettle();
      final controller = t.widget<InteractiveViewer>(find.byKey(const Key('floor-canvas'))).transformationController!;
      controller.value = Matrix4.identity()..scaleByDouble(zoom, zoom, 1, 1);
      await t.pump();
      final before = controller.value.clone();
      final gesture = await t.startGesture(t.getCenter(find.byKey(const Key('table-1'))), kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 5; i++) {
        await gesture.moveBy(const Offset(10, 5));
        await t.pump();
      }
      await gesture.up();
      await t.pumpAndSettle();
      expect(controller.value, before, reason: 'dragging a table must not pan the floor');
      await t.tap(find.byKey(const Key('save-plan')));
      await t.pumpAndSettle();
      final saved = (api.last('PUT', '/layout')['tables'] as List).single as Map;
      expect(saved['x'], ((150 + 50 / zoom) / 10).round() * 10);
      expect(saved['y'], ((150 + 25 / zoom) / 10).round() * 10);
      expect(find.byKey(const Key('table-1')), findsOneWidget);
    });
  }

  testWidgets('owners can find both Excel imports even when their plan excludes import', (t) async {
    final api = await start(t, setup: (a) => (a.me['permissions'] as List).remove('import.run'));
    for (final entry in [('Menu', 'menu'), ('Inventory', 'inventory')]) {
      await go(t, entry.$1, size: desktop);
      await t.tap(find.byKey(Key('import-${entry.$2}')));
      await t.pumpAndSettle();
      expect(find.textContaining('Excel import is not in your plan'), findsOneWidget);
      expect(find.byType(ImportDialog), findsNothing);
    }
    expect(api.calls.where((c) => c.url.path.contains('/imports/')), isEmpty);
  });

  for (final zoom in [1.0, 2.0]) {
    testWidgets('Move chairs mode: chair moves independently, then table carries all chairs at zoom $zoom', (t) async {
      final api = await start(t);
      api.floors.add({'id': 'f1', 'name': 'Ground', 'branchId': 'b1', 'tables': [
        {'id': 't1', 'name': '1', 'seats': 4, 'shape': 'rect', 'x': 150, 'y': 150, 'width': 100, 'height': 80, 'rotation': 90,
          'chairs': [{'x': 0, 'y': -58, 'rotation': 180}, {'x': 0, 'y': 58, 'rotation': 0}]},
      ]});
      await go(t, 'Floors & tables', size: desktop);
      await t.tap(find.byKey(const Key('edit-plan')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('table-1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('chair-mode')));
      await t.pumpAndSettle();
      final controller = t.widget<InteractiveViewer>(find.byKey(const Key('floor-canvas'))).transformationController!;
      controller.value = Matrix4.identity()..scaleByDouble(zoom, zoom, 1, 1);
      await t.pump();
      final transform = controller.value.clone();
      final table = find.byKey(const Key('table-1'));
      final chair = find.byKey(const Key('chair-1-0'));
      final initialTableCenter = t.getCenter(table);
      final initialChairCenter = t.getCenter(chair);
      final chairDrag = await t.startGesture(initialChairCenter, kind: PointerDeviceKind.mouse);
      await chairDrag.moveBy(Offset(10 * zoom, 0));
      await t.pump();
      await chairDrag.up();
      await t.pumpAndSettle();
      expect(t.getCenter(table), initialTableCenter, reason: 'moving a chair does not move its table');
      expect(t.getCenter(chair).dx, closeTo(initialChairCenter.dx + 10 * zoom, .01));
      final chairCenters = [t.getCenter(chair), t.getCenter(find.byKey(const Key('chair-1-1')))];
      final tableDrag = await t.startGesture(t.getCenter(table), kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 5; i++) {
        await tableDrag.moveBy(Offset(10 * zoom, 4 * zoom));
        await t.pump();
      }
      await tableDrag.up();
      await t.pumpAndSettle();
      expect(t.getCenter(table), initialTableCenter + Offset(50 * zoom, 20 * zoom));
      for (var i = 0; i < 2; i++) {
        expect(t.getCenter(find.byKey(Key('chair-1-$i'))), chairCenters[i] + Offset(50 * zoom, 20 * zoom));
      }
      expect(controller.value, transform, reason: 'neither drag pans the floor');
      await t.tap(find.byKey(const Key('save-plan')));
      await t.pumpAndSettle();
      final saved = (api.last('PUT', '/layout')['tables'] as List).single as Map;
      expect(saved['x'], 200);
      expect(saved['y'], 170);
      expect(saved['chairs'], [{'x': 0, 'y': -68, 'rotation': 180}, {'x': 0, 'y': 58, 'rotation': 0}]);
      expect(t.getCenter(find.byKey(const Key('chair-1-0'))).dx, closeTo(chairCenters[0].dx + 50 * zoom, .01));
    });
  }

  testWidgets('inventory Excel import downloads its template and confirms the opening stock preview', (t) async {
    final api = await start(t);
    xlsxPicker = () async => (name: 'inventory.xlsx', bytes: [0x50, 0x4b, 3, 4]);
    addTearDown(() => xlsxPicker = pickXlsx);
    await go(t, 'Inventory', size: desktop);
    await t.tap(find.byKey(const Key('import-inventory')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('download-template')));
    await t.pumpAndSettle();
    expect(lastSavedFile?.name, 'house-plating-inventory-import-template.xlsx');
    await t.tap(find.byKey(const Key('upload-xlsx')));
    await t.pumpAndSettle();
    expect(api.last('POST', '/imports/inventory/validate')['fileName'], 'inventory.xlsx');
    expect(find.textContaining('Opening stock RICE: +1000 g'), findsOneWidget);
    expect(api.calls.where((c) => c.url.path.endsWith('/commit')), isEmpty);
    await t.tap(find.byKey(const Key('confirm-import')));
    await t.pumpAndSettle();
    expect(api.last('POST', '/imports/stock-job/commit'), {'partial': false});
    expect(find.text('Imported'), findsOneWidget);
  });

  testWidgets('excel import: template, upload, errors by row and column, preview, only-valid-rows confirm, results', (t) async {
    final api = await start(t);
    xlsxPicker = () async => (name: 'menu.xlsx', bytes: [0x50, 0x4b, 3, 4]);
    await go(t, 'Menu', size: desktop);
    await t.tap(find.byKey(const Key('import-menu')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('download-template')));
    await t.pumpAndSettle();
    expect(lastSavedFile?.name, 'house-plating-menu-import-template.xlsx');
    await t.tap(find.byKey(const Key('mode-create')));
    await t.tap(find.byKey(const Key('upload-xlsx')));
    await t.pumpAndSettle();
    expect(api.last('POST', '/imports/menu/validate'), allOf(containsPair('fileName', 'menu.xlsx'), containsPair('mode', 'create'), containsPair('dataBase64', 'UEsDBA==')));
    expect(find.text('1 error to fix'), findsOneWidget);
    expect(find.text('Sheet Variants · row 4 · column selling_price'), findsOneWidget);
    expect(find.textContaining('New size COLA-500'), findsOneWidget);
    final confirm = find.byKey(const Key('confirm-import'));
    expect(t.widget<PrimaryButton>(confirm).onPressed, isNull, reason: 'errors block the import until the person chooses valid rows only');
    await t.tap(find.byKey(const Key('error-report')));
    await t.pumpAndSettle();
    expect(lastSavedFile?.name, 'import-menu-errors.csv');
    await t.tap(find.byKey(const Key('partial')));
    await t.pumpAndSettle();
    await t.tap(confirm);
    await t.pumpAndSettle();
    expect(api.last('POST', '/commit'), {'partial': true});
    expect(find.byKey(const Key('import-done')), findsOneWidget);
    expect(find.textContaining('Variants row 4 (WATER-1L)'), findsOneWidget);
  });

  test('restaurantShortPrefix derives concise short code from restaurant name', () {
    expect(restaurantShortPrefix(name: 'Demo Dhaba'), 'DD-');
    expect(restaurantShortPrefix(name: 'The Spice Route'), 'TSR-');
    expect(restaurantShortPrefix(name: 'Burger King Express'), 'BKE-');
    expect(restaurantShortPrefix(name: 'Chai'), 'CHAI-');
    expect(restaurantShortPrefix(name: "McDonald's"), 'MCD-');
    expect(restaurantShortPrefix(name: 'Subway'), 'SUB-');
    expect(restaurantShortPrefix(name: null, fallbackCode: 'R001'), 'R001-');
    expect(restaurantShortPrefix(name: '', fallbackCode: ''), 'RST-');
  });

  testWidgets('dish SKU code starts with restaurant short name and auto-generates cleanly', (t) async {
    await start(t);
    await go(t, 'Menu', size: desktop);
    await t.tap(find.byKey(const Key('add-dish')));
    await t.pumpAndSettle();

    // Dish 1: Single-word beverage Coke -> SKU: DD-COKE
    await t.enterText(find.byKey(const Key('dish-name')), 'Coke');
    await t.tap(find.byTooltip('Auto-generate SKU'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'DD-COKE'), findsOneWidget);

    // Dish 2: Multi-word item Paneer Tikka -> SKU: DD-PT01
    await t.enterText(find.byKey(const Key('dish-name')), 'Paneer Tikka');
    await t.tap(find.byTooltip('Auto-generate SKU'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'DD-PT01'), findsOneWidget);
  });

  testWidgets('menu pagination: smooth rendering with 24 items per page, page navigation and page sizing', (t) async {
    final api = await start(t);
    // Populate categories, taxes and 60 items in mock api
    api.cats.add({'id': 'cat-1', 'name': 'Mains', 'sortOrder': 0});
    api.taxes.add({'id': 'tx-1', 'name': 'GST 5%', 'rateBp': 500});
    api.items.clear();
    for (var i = 1; i <= 60; i++) {
      api.items.add({
        'id': 'item-$i',
        'code': 'DD-ITEM$i',
        'name': 'Dish $i',
        'categoryId': 'cat-1',
        'taxRuleId': 'tx-1',
        'available': true,
        'variants': [
          {'id': 'v-$i', 'name': 'Regular', 'pricePaise': 15000, 'isDefault': true}
        ],
      });
    }

    await go(t, 'Menu', size: desktop);
    await t.pumpAndSettle();

    // Verify first page renders items 1 to 24 and shows count
    expect(find.text('Showing 1–24 of 60 dishes'), findsNWidgets(2)); // top and bottom bars
    expect(find.byKey(const Key('item-Dish 1')), findsOneWidget);
    expect(find.byKey(const Key('item-Dish 24')), findsOneWidget);
    expect(find.byKey(const Key('item-Dish 25')), findsNothing); // Page 2 item not rendered on page 1

    // Navigate to next page
    await t.tap(find.byKey(const Key('page-next-top')));
    await t.pumpAndSettle();
    expect(find.text('Showing 25–48 of 60 dishes'), findsNWidgets(2));
    expect(find.byKey(const Key('item-Dish 24')), findsNothing);
    expect(find.byKey(const Key('item-Dish 25')), findsOneWidget);
    expect(find.byKey(const Key('item-Dish 48')), findsOneWidget);
    expect(find.byKey(const Key('item-Dish 49')), findsNothing);

    // Navigate to last page via top bar button
    await t.tap(find.byKey(const Key('page-last-top')));
    await t.pumpAndSettle();
    expect(find.text('Showing 49–60 of 60 dishes'), findsNWidgets(2));
    expect(find.byKey(const Key('item-Dish 49')), findsOneWidget);
    expect(find.byKey(const Key('item-Dish 60')), findsOneWidget);

    // Navigate back to first page via top bar button
    await t.tap(find.byKey(const Key('page-first-top')));
    await t.pumpAndSettle();
    expect(find.text('Showing 1–24 of 60 dishes'), findsNWidgets(2));
    expect(find.byKey(const Key('item-Dish 1')), findsOneWidget);
  });

  group('client review (HousePlating.pdf)', () {
    testWidgets('revoked plan: dashboard says "No active plan" (never "No plan plan"); menu and floors explain the lock, no "Something went wrong"', (t) async {
      await start(t, setup: (f) => f.noPlan = true);
      expect(find.textContaining('No active plan'), findsOneWidget);
      expect(find.textContaining('plan plan'), findsNothing);
      expect(find.byKey(const Key('dashboard-no-plan')), findsOneWidget);
      for (final page in ['Menu', 'Floors & tables']) {
        await go(t, page, size: desktop);
        expect(find.byKey(const Key('plan-locked')), findsOneWidget, reason: page);
        expect(find.text('Not in your plan'), findsOneWidget);
        expect(find.text('Something went wrong'), findsNothing);
        expect(find.text('Try again'), findsNothing);
      }
    });

    testWidgets('revoked plan: nobody can be added on the Staff page', (t) async {
      await start(t, setup: (f) => f.noPlan = true);
      await go(t, 'Staff', size: desktop);
      expect(find.byKey(const Key('staff-no-plan')), findsOneWidget);
      expect(t.widget<PrimaryButton>(find.byKey(const Key('add-staff'))).onPressed, isNull);
    });

    testWidgets('standard categories: the confirm button says "Add categories", not "Delete"', (t) async {
      await start(t);
      await go(t, 'Menu', size: desktop);
      await t.tap(find.byKey(const Key('seed-categories')));
      await t.pumpAndSettle();
      expect(find.text('Add the standard categories?'), findsOneWidget);
      expect(find.widgetWithText(PrimaryButton, 'Add categories'), findsOneWidget);
      expect(find.byType(DangerButton), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('a dish added under "Non-Veg Main Course" starts as non-veg', (t) async {
      await start(t, setup: (f) => f.cats.add({'id': 'c-nv', 'name': 'Non-Veg Main Course', 'sortOrder': 0}));
      await go(t, 'Menu', size: desktop);
      await t.tap(find.byKey(const Key('add-dish')));
      await t.pumpAndSettle();
      bool veg() => t.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Vegetarian')).value;
      expect(veg(), isFalse);
      await t.enterText(find.byKey(const Key('dish-name')), 'Butter Chicken');
      await t.pumpAndSettle();
      expect(veg(), isFalse);
    });

    testWidgets('inventory: one "Add category" button; same buy / count unit needs no conversion; stock in hand is recorded as opening stock', (t) async {
      final api = await start(t);
      await go(t, 'Inventory', size: desktop);
      expect(find.text('Category ++'), findsNothing);
      expect(find.text('Add category'), findsOneWidget);
      await t.tap(find.byKey(const Key('add-product')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('product-sku')), 'WHEAT');
      await t.enterText(find.byKey(const Key('product-name')), 'Wheat flour');
      for (final (key, unit) in [('base-unit', 'kg'), ('purchase-unit', 'kg')]) {
        await t.ensureVisible(find.byKey(Key(key)));
        await t.tap(find.byKey(Key(key)));
        await t.pumpAndSettle();
        await t.tap(find.text(unit).last);
        await t.pumpAndSettle();
      }
      expect(find.byKey(const Key('product-factor')), findsNothing);
      expect(find.byKey(const Key('product-factor-same')), findsOneWidget);
      await t.enterText(find.byKey(const Key('product-cost')), '25');
      await t.enterText(find.byKey(const Key('product-opening')), '1000');
      await t.tap(find.byKey(const Key('save-product')));
      await t.pumpAndSettle();
      expect(api.last('POST', '/inventory/products'), allOf(containsPair('conversionFactor', 1.0), containsPair('unitCostPaise', 2500)));
      expect(api.last('POST', '/inventory/movements'), allOf(containsPair('type', 'opening'), containsPair('quantity', 1000.0), containsPair('unit', 'kg')));
    });
  });
}
