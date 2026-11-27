import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rsaas_hub/rsaas_hub.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;
  setUp(() async => h = await Harness.start());
  tearDown(() => h.close());

  RelayClient relay([http.Client? c]) => RelayClient('https://cloud.test/api/v1', 'hub-cloud-token', h.server.handler, client: c);

  test('a relayed request runs through the hub with the same device checks', () async {
    final ok = await relay().handle({'id': 'r1', 'method': 'GET', 'path': 'whoami', 'headers': {'x-device-token': h.deviceToken}});
    expect(ok['status'], 200);
    expect(ok['headers'], {'content-type': 'application/json'});
    expect(jsonDecode(utf8.decode(base64Decode(ok['bodyB64']! as String))), containsPair('deviceId', isA<String>()));
    expect((await relay().handle({'id': 'r2', 'method': 'GET', 'path': 'whoami', 'headers': {'x-device-token': 'nope'}}))['status'], 401);
    final login = await relay().handle({'id': 'r3', 'method': 'POST', 'path': 'session/login', 'headers': {'x-device-token': h.deviceToken, 'content-type': 'application/json'},
        'body': jsonEncode({'userId': Harness.cashier, 'pin': Harness.pins[Harness.cashier]})});
    expect(login['status'], 200);
  });

  test('joining with email + PIN is refused through the relay, even if the device sends the marker itself', () async {
    final body = jsonEncode({'email': 'ravi@demo.test', 'pin': Harness.pins[Harness.cashier], 'deviceName': 'x', 'platform': 'android'});
    final r = await relay().handle({'id': 'r1', 'method': 'POST', 'path': 'pairing/staff-claim', 'headers': {'content-type': 'application/json', 'x-rsaas-relay': ''}, 'body': body});
    expect(r['status'], 403);
    expect(jsonDecode(utf8.decode(base64Decode(r['bodyB64']! as String)))['code'], 'not_relayed');
    // nor a one-time pairing code
    final code = await h.hub.createPairingCode();
    final claim = await relay().handle({'id': 'r2', 'method': 'POST', 'path': 'pairing/claim', 'headers': {'content-type': 'application/json'},
        'body': jsonEncode({'code': code, 'deviceName': 'x', 'platform': 'android'})});
    expect(claim['status'], 403);
    expect((await h.post('/pairing/claim', body: {'code': code, 'deviceName': 'x', 'platform': 'android'})).status, 201); // code still unused
    // on the Wi-Fi it still works
    expect((await h.post('/pairing/staff-claim', body: jsonDecode(body) as Map<String, Object?>)).status, 201);
  });

  test('pairing info lists every address and the cloud relay', () async {
    final s = HubServer(h.hub, hubName: 'x', cloudUrl: 'https://cloud.test/api/v1', addresses: () async => ['192.168.1.5', '100.101.1.2']);
    final res = await s.handler(Request('GET', Uri.parse('http://hub/hub/v1/pairing/info')));
    final j = jsonDecode(await res.readAsString()) as Map;
    expect(j['addresses'], ['192.168.1.5', '100.101.1.2']);
    expect(j['cloudUrl'], 'https://cloud.test/api/v1');
    expect(j['branchId'], Harness.branchId);
  });

  test('polls the cloud, answers each request and posts the answer back', () async {
    var polls = 0;
    final replied = Completer<Map<String, Object?>>();
    final client = MockClient((r) async {
      expect(r.headers['x-device-token'], 'hub-cloud-token');
      if (r.url.path.endsWith('/relay/hub/poll')) {
        polls++;
        if (polls > 1) await Future<void>.delayed(const Duration(seconds: 5));
        return http.Response(jsonEncode({'requests': polls == 1 ? [{'id': 'q1', 'method': 'GET', 'path': 'health', 'headers': {}}] : [], 'listeners': false}), 200);
      }
      if (r.url.path.endsWith('/relay/hub/reply')) replied.complete(jsonDecode(r.body) as Map<String, Object?>);
      return http.Response('{"ok":true}', 200);
    });
    final c = relay(client)..start();
    final body = await replied.future.timeout(const Duration(seconds: 5));
    c.stop();
    final answer = (body['responses']! as List).single as Map;
    expect(answer['id'], 'q1');
    expect(answer['status'], 200);
    expect(jsonDecode(utf8.decode(base64Decode(answer['bodyB64'] as String)))['status'], 'ok');
  });
}
