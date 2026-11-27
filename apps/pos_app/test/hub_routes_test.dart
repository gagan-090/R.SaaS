import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rsaas_pos/hub/hub_api.dart';
import 'package:rsaas_pos/state/app_state.dart';

const lan1 = 'https://192.168.1.5:8443/hub/v1';
const lan2 = 'https://192.168.2.9:8443/hub/v1';
const relay = 'https://cloud.test/api/v1/relay/b/01900000-0000-7000-8000-000000000b01/hub/v1';

http.Response json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  test('a dead address costs nothing: the hub address that answers is used, and its other routes are learned', () async {
    final seen = <String>[];
    (List<String>, String?)? learned;
    final api = HttpHubApi(
      baseUrl: lan1,
      deviceToken: 'dev',
      certFingerprint: 'AA:BB',
      alternates: const [lan2],
      onRoutes: (l, r) => learned = (l, r),
      scan: () async => const [],
      client: MockClient((r) async {
        seen.add(r.url.toString());
        if (r.url.host == '192.168.1.5') throw http.ClientException('No route to host');
        if (r.url.path.endsWith('/pairing/info')) {
          return json({'certFingerprint': 'AA:BB', 'addresses': ['192.168.2.9', '100.101.1.2'], 'cloudUrl': 'https://cloud.test/api/v1', 'branchId': '01900000-0000-7000-8000-000000000b01'});
        }
        return json({'ok': true});
      }),
    );
    expect(await api.state(), {'ok': true});
    expect(api.activeUrl, lan2);
    expect(seen.where((u) => u.endsWith('/state')), ['$lan2/state']);
    await Future<void>.delayed(Duration.zero);
    expect(learned, isNotNull);
    expect(learned!.$1, [lan2, 'https://100.101.1.2:8443/hub/v1']);
    expect(learned!.$2, relay);
  });

  test('no hub address answers: the request goes through the cloud relay, and photos come from the cloud', () async {
    final seen = <http.BaseRequest>[];
    final api = HttpHubApi(
      baseUrl: lan1,
      deviceToken: 'dev',
      certFingerprint: 'AA:BB',
      relayUrl: relay,
      onRoutes: (_, _) {},
      scan: () async => const [],
      client: MockClient((r) async {
        seen.add(r);
        if (r.url.host != 'cloud.test') throw http.ClientException('Connection refused');
        if (r.url.path.endsWith('/media/m1')) return http.Response.bytes([1, 2, 3], 200);
        return json({'id': 'o1'}, 201);
      }),
    );
    expect(await api.openOrder(type: 'takeaway'), {'id': 'o1'});
    expect(api.viaRelay, isTrue);
    final post = seen.lastWhere((r) => r.method == 'POST');
    expect(post.url.toString(), '$relay/orders');
    expect(post.headers['x-device-token'], 'dev');
    expect(post.headers['x-relay-timeout'], '20');
    expect(await api.media('m1'), [1, 2, 3]);
    expect(seen.last.url.toString(), 'https://cloud.test/api/v1/media/m1');
  });

  test('the relay says the main device is offline: "Kitchen hub offline"', () async {
    final api = HttpHubApi(
      baseUrl: lan1,
      deviceToken: 'dev',
      relayUrl: relay,
      client: MockClient((r) async {
        if (r.url.host != 'cloud.test') throw http.ClientException('Connection refused');
        return json({'statusCode': 503, 'code': 'hub_offline', 'message': 'The main device is offline or has no internet'}, 503);
      }),
    );
    await expectLater(api.state(), throwsA(isA<HubApiException>().having((e) => e.code, 'code', 'hub_offline')));
  });

  test('the main device got a new IP on this Wi-Fi: a scan finds the same certificate and uses it', () async {
    final found = <(List<String>, String?)>[];
    final api = HttpHubApi(
      baseUrl: lan1,
      deviceToken: 'dev',
      certFingerprint: 'AA:BB',
      alternates: const [lan2],
      onRoutes: (l, r) => found.add((l, r)),
      scan: () async => [
        (host: '192.168.1.77', port: 8443, fingerprint: 'CC:DD', info: const <String, dynamic>{}), // another restaurant's hub
        (host: '192.168.1.40', port: 8443, fingerprint: 'AA:BB', info: const <String, dynamic>{}),
      ],
      client: MockClient((r) async {
        if (r.url.host != '192.168.1.40') throw http.ClientException('No route to host');
        return json({'ok': true});
      }),
    );
    await expectLater(api.state(), throwsA(isA<HubApiException>()));
    await Future<void>.delayed(Duration.zero);
    expect(api.activeUrl, 'https://192.168.1.40:8443/hub/v1');
    expect(found.last.$1.first, 'https://192.168.1.40:8443/hub/v1');
    expect(await api.state(), {'ok': true});
  });

  test('live events through the relay: the state first, then each change in order', () async {
    final api = HttpHubApi(
      baseUrl: lan1,
      deviceToken: 'dev',
      relayUrl: relay,
      client: MockClient((r) async {
        if (r.url.host != 'cloud.test') throw http.ClientException('Connection refused');
        if (r.url.path.endsWith('/events')) {
          return switch (r.url.queryParameters['after']) {
            null => json({'seq': 4, 'events': [], 'reset': false}),
            '4' => json({'seq': 6, 'events': [{'type': 'kds.updated', 'n': 5}, {'type': 'order.updated', 'n': 6}], 'reset': false}),
            _ => json({'statusCode': 503, 'code': 'hub_offline'}, 503),
          };
        }
        return json({'openOrders': []});
      }),
    );
    final got = <Map<String, dynamic>>[];
    await expectLater(api.events().forEach(got.add), throwsA(isA<HubApiException>()));
    expect(got.map((e) => e['type']), ['state.snapshot', 'kds.updated', 'order.updated']);
    expect(got.first['data'], {'openOrders': []});
  });

  test('one address and no relay: requests go straight to it, as before', () async {
    final seen = <String>[];
    final api = HttpHubApi(baseUrl: lan1, deviceToken: 'dev', client: MockClient((r) async {
      seen.add(r.url.toString());
      return json({'ok': true});
    }));
    await api.state();
    expect(seen, ['$lan1/state']);
  });

  test('the learned routes are kept with the device setup', () {
    const s = DeviceSetup(hubBaseUrl: lan1, deviceToken: 't', fingerprint: 'AA:BB', altUrls: [lan2], relayUrl: relay);
    final back = DeviceSetup.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(back.altUrls, [lan2]);
    expect(back.relayUrl, relay);
    final old = DeviceSetup.fromJson({'hubBaseUrl': lan1, 'deviceToken': 't'});
    expect(old.altUrls, isEmpty);
    expect(old.relayUrl, isNull);
  });
}
