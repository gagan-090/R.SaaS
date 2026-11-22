import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_pos/hub/hub_api.dart';

void main() {
  test('a typed main-device address that does not answer says why instead of "no main device found"', () async {
    // nothing listens on port 1 here: connection refused
    final e = await findAndJoinHub(email: 'w@x.test', pin: '1234', deviceName: 'W', platform: 'ios', host: '127.0.0.1:1')
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(e, isA<HubApiException>().having((x) => x.code, 'code', 'hub_unreachable'));
    expect('$e', contains('BhojMitra is not running there'));
  });

  test('hints name the problem; iPhone gets the Local Network setting', () {
    expect(unreachableHint('192.168.1.44', 8443, 'SocketException: No route to host (OS Error: errno = 65)'), contains('same Wi-Fi'));
    expect(unreachableHint('192.168.1.44', 8443, 'TimeoutException'), contains('No answer from 192.168.1.44:8443'));
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(unreachableHint('192.168.1.44', 8443, null), contains('"Local Network"'));
    debugDefaultTargetPlatformOverride = null;
  });
}
