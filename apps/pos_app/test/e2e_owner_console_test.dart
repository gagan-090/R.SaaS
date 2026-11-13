@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_hub/rsaas_hub.dart';
import 'package:rsaas_pos/hub/hub_api.dart';

/// The owner console from the POS PIN, end to end with nothing faked: the real cloud API, the real main-device server
/// and cloud link (as apps/pos_app/lib/hub/hub_mode_io.dart wires them), the POS's real hub client, and the console's
/// real API client.
///
///   E2E_API_URL=http://localhost:3999/api/v1 E2E_OWNER_EMAIL=owner@demo-dhaba.example E2E_OWNER_PASSWORD=… \
///     flutter test test/e2e_owner_console_test.dart
///
/// Needs the demo seed (one user per role, all PIN 1234). Run it against a throwaway database, never production.
void main() {
  final env = Platform.environment;
  final api = env['E2E_API_URL'];
  final skip = api == null || env['E2E_OWNER_EMAIL'] == null || env['E2E_OWNER_PASSWORD'] == null
      ? 'set E2E_API_URL, E2E_OWNER_EMAIL and E2E_OWNER_PASSWORD to run against a live API'
      : false;

  test('owner PIN on the POS → owner console signed in, through the main device; renewed when it runs out', () async {
    Future<Map<String, dynamic>> cloud(String method, String path, {Object? body, String? bearer}) async {
      final req = http.Request(method, Uri.parse('$api$path'))
        ..headers.addAll({'content-type': 'application/json', if (bearer != null) 'authorization': 'Bearer $bearer'});
      if (body != null) req.body = jsonEncode(body);
      final res = await http.Response.fromStream(await req.send());
      expect(res.statusCode, lessThan(300), reason: '$method $path → ${res.statusCode} ${res.body}');
      return jsonDecode(res.body) as Map<String, dynamic>;
    }

    // 1. the owner's first device signs in with the password and becomes the main device
    final login = await cloud('POST', '/auth/login', body: {'email': env['E2E_OWNER_EMAIL'], 'password': env['E2E_OWNER_PASSWORD']});
    expect(login['status'], 'ok');
    final reg = await cloud('POST', '/devices/register-hub', body: {'name': 'E2E main device', 'platform': 'android', 'replace': true}, bearer: login['accessToken'] as String);

    // 2. main device: hub + cloud link + server, wired like hub_mode_io.dart
    final db = HubDatabase.memory();
    final hub = HubService(db, HubConfig(branchId: reg['branchId'] as String, branchCode: reg['branchCode'] as String, licensePublicKey: reg['licensePublicKey'] as String));
    final link = CloudClient(api!, reg['deviceToken'] as String);
    final worker = SyncWorker(db, hub, link);
    await worker.pullOnce();
    final server = HubServer(hub, hubName: 'e2e', refreshStaff: worker.pullOnce, addStaff: link.addStaff, consoleSession: link.consoleSession);
    final s = await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    addTearDown(() async {
      await server.stop();
      await hub.close();
      await db.close();
    });
    final base = 'http://127.0.0.1:${s.port}/hub/v1';
    final deviceToken = await hub.registerSelf('This hub', 'android');

    // 3. the POS on that device: staff sign in with their PIN (no password anywhere from here on)
    final staff = await HttpHubApi(baseUrl: base, deviceToken: deviceToken).staff();
    String idOf(String name) => staff.firstWhere((u) => u['name'] == name)['id'] as String;
    Future<HttpHubApi> pinIn(String name) async {
      final pos = HttpHubApi(baseUrl: base, deviceToken: deviceToken);
      await pos.login(idOf(name), '1234');
      return pos;
    }

    final owner = await pinIn('Demo Owner');

    // 4. More → Owner console: the main device gets the console session from the cloud
    final cs = await owner.consoleSession();
    expect(cs['status'], 'ok');
    var kept = cs['refreshToken'] as String?;
    expect(kept, isNotNull);

    // 5. the console signs in with it (exactly what EmbeddedAdminConsole does) — no email, no password
    final console = ApiClient(baseUrl: api, sessionReader: () => kept, sessionWriter: (v) => kept = v, renewSession: () async => (await owner.consoleSession())['refreshToken'] as String?);
    expect(await console.restoreSession(), isTrue);
    final me = await console.me();
    expect(me['email'], env['E2E_OWNER_EMAIL']);
    expect(me['roles'], contains('owner'));
    // owner powers work with it (menu, floors, staff — every action still checked by the server)
    await console.categories();
    await console.floors();
    await console.staff();

    // 6. the session ends on the server (signed out elsewhere / expired): the console renews through the main
    //    device by itself instead of showing the sign-in page
    final dead = kept;
    await console.logout(); // the server revokes this session
    final reopened = ApiClient(baseUrl: api, sessionReader: () => dead, sessionWriter: (v) => kept = v, renewSession: () async => (await owner.consoleSession())['refreshToken'] as String?);
    expect(await reopened.restoreSession(), isTrue);
    expect((await reopened.me())['email'], env['E2E_OWNER_EMAIL']);

    // 7. Restaurant Admin also gets in; a cashier cannot (server refuses, no console)
    final itAdmin = await pinIn('Imran (IT Admin)');
    expect((await itAdmin.consoleSession())['refreshToken'], isA<String>());
    final cashier = await pinIn(staff.firstWhere((u) => (u['roles'] as List).contains('cashier'))['name'] as String);
    await expectLater(cashier.consoleSession(), throwsA(isA<HubApiException>().having((e) => e.status, 'status', 403)));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
