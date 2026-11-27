import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:rsaas_hub/rsaas_hub.dart';

import 'hub_api.dart';

class HubHostConfig {
  const HubHostConfig({required this.cloudUrl, required this.cloudDeviceToken, required this.branchId, required this.branchCode, required this.licensePublicKey});
  final String cloudUrl, cloudDeviceToken, branchId, branchCode, licensePublicKey;
}

/// Hub mode: this device runs the branch hub (packages/hub_server) in-process — SQLite on disk,
/// HTTPS + WebSocket on the LAN with a self-signed pinned certificate, and the cloud sync worker.
/// Not on iOS: it suspends backgrounded apps, which would take the branch LAN server down.
class HubHost {
  static bool get supported => !Platform.isIOS;

  HubDatabase? _db;
  HubService? _hub;
  HubServer? _server;
  SyncWorker? _worker;
  RelayClient? _relay;
  PairingPayload? pairing;
  String? localDeviceToken;
  String? fingerprint;
  int port = 8443;

  /// [localToken]: this device's own POS token from an earlier start (kept in the device setup), so a restart does not
  /// add another "This hub" device.
  Future<void> start(HubHostConfig c, {String? localToken}) async {
    localDeviceToken ??= localToken;
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/hub')..createSync(recursive: true);
    _db = HubDatabase.file(File('${dir.path}/hub.sqlite'));
    _hub = HubService(_db!, HubConfig(branchId: c.branchId, branchCode: c.branchCode, licensePublicKey: c.licensePublicKey));
    final certF = File('${dir.path}/hub-cert.pem'), keyF = File('${dir.path}/hub-key.pem');
    final HubTls tls;
    if (certF.existsSync() && keyF.existsSync()) {
      tls = HubTls(certF.readAsStringSync(), keyF.readAsStringSync());
    } else {
      tls = HubTls.generate();
      certF.writeAsStringSync(tls.certPem);
      keyF.writeAsStringSync(tls.keyPem);
    }
    fingerprint = tls.fingerprint;
    final cloud = CloudClient(c.cloudUrl, c.cloudDeviceToken);
    _worker = SyncWorker(_db!, _hub!, cloud);
    // First start: wait for the menu, staff and license. After that never wait for the internet: the device opens at
    // once with what it has (billing works offline) and the sync worker pulls changes and bill history in the background.
    if (await _db!.getMeta('config_cursor') == null) {
      try {
        await _worker!.pullOnce();
      } catch (_) {
        // offline first start: the setup screen explains; the worker keeps trying
      }
    }
    _server = HubServer(_hub!, hubName: Platform.localHostname, refreshStaff: _worker!.pullOnce, addStaff: cloud.addStaff, consoleSession: cloud.consoleSession,
        certFingerprint: fingerprint, cloudUrl: c.cloudUrl, addresses: addresses);
    await _server!.start(port: port, tls: tls.context());
    _worker!.start();
    // devices on another floor / router / ISP reach this hub through the cloud (needs internet on both sides)
    _relay = RelayClient(c.cloudUrl, c.cloudDeviceToken, _server!.handler, events: _hub!.events, branchId: c.branchId)..start();
    if (localDeviceToken == null) {
      localDeviceToken = await _hub!.registerSelf('This hub (${Platform.localHostname})', Platform.isWindows ? 'windows' : 'android');
    } else {
      await _hub!.markSelf(localDeviceToken!);
    }
    await newPairingCode();
  }

  /// A fresh one-time pairing code (10 minutes) for the QR on the hub screen.
  Future<PairingPayload> newPairingCode() async {
    final code = await _hub!.createPairingCode();
    final all = await addresses();
    return pairing = PairingPayload(host: all.isEmpty ? '127.0.0.1' : all.first, port: port, code: code, fingerprint: fingerprint);
  }

  /// Every address other terminals can reach this device on, best first: private Wi-Fi / Ethernet addresses, then
  /// a VPN such as Tailscale (100.64.0.0/10), then the rest; never mobile data (rmnet/ccmni on Android phones).
  static Future<List<String>> addresses() async {
    bool private(String ip) {
      final p = ip.split('.').map(int.parse).toList();
      return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] >= 16 && p[1] <= 31);
    }

    bool vpn(String ip) {
      final p = ip.split('.').map(int.parse).toList();
      return p[0] == 100 && p[1] >= 64 && p[1] <= 127; // carrier-grade NAT range used by Tailscale / ZeroTier-style VPNs
    }

    int score(NetworkInterface ni, InternetAddress a) {
      final n = ni.name.toLowerCase();
      if (vpn(a.address)) return 5; // after the Wi-Fi / Ethernet addresses (a VPN on Android is a tun interface)
      var s = 0;
      if (private(a.address)) s += 10;
      if (n.startsWith('wlan') || n.startsWith('wi-fi') || n.startsWith('en') || n.startsWith('eth') || n.contains('wireless')) s += 5;
      if (n.startsWith('rmnet') || n.startsWith('ccmni') || n.startsWith('pdp') || n.startsWith('tun')) s -= 20;
      return s;
    }

    final candidates = [
      for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4))
        for (final a in ni.addresses)
          if (!a.isLoopback && !a.isLinkLocal) (ni, a),
    ]..sort((x, y) => score(y.$1, y.$2).compareTo(score(x.$1, x.$2)));
    final good = [
      for (final c in candidates)
        if (score(c.$1, c.$2) > 0) c.$2.address,
    ];
    return good.isNotEmpty ? good : [for (final c in candidates) c.$2.address];
  }

  Future<void> stop() async {
    _relay?.stop();
    _relay = null;
    _worker?.stop();
    await _server?.stop();
    await _db?.close();
  }
}
