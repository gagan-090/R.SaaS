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
class HubHost {
  static bool get supported => true;

  HubDatabase? _db;
  HubService? _hub;
  HubServer? _server;
  SyncWorker? _worker;
  PairingPayload? pairing;
  String? localDeviceToken;
  String? fingerprint;
  int port = 8443;

  Future<void> start(HubHostConfig c) async {
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
    _worker = SyncWorker(_db!, _hub!, CloudClient(c.cloudUrl, c.cloudDeviceToken));
    try {
      await _worker!.pullOnce();
    } catch (_) {
      // offline start: keep serving the LAN with the last pulled config
    }
    _server = HubServer(_hub!, hubName: Platform.localHostname, certFingerprint: fingerprint);
    await _server!.start(port: port, tls: tls.context());
    _worker!.start();
    localDeviceToken ??= await _hub!.registerSelf('This hub (${Platform.localHostname})', Platform.isWindows ? 'windows' : 'android');
    await newPairingCode();
  }

  /// A fresh one-time pairing code (10 minutes) for the QR on the hub screen.
  Future<PairingPayload> newPairingCode() async {
    final code = await _hub!.createPairingCode();
    final ip = await _lanAddress();
    return pairing = PairingPayload(host: ip, port: port, code: code, fingerprint: fingerprint);
  }

  /// The address other terminals on the restaurant Wi-Fi can reach: a private LAN address, preferring Wi-Fi /
  /// Ethernet interfaces over mobile data (rmnet/ccmni on Android phones).
  static Future<String> _lanAddress() async {
    bool private(String ip) {
      final p = ip.split('.').map(int.parse).toList();
      return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] >= 16 && p[1] <= 31);
    }

    int score(NetworkInterface ni, InternetAddress a) {
      final n = ni.name.toLowerCase();
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
    return candidates.isEmpty ? '127.0.0.1' : candidates.first.$2.address;
  }

  Future<void> stop() async {
    _worker?.stop();
    await _server?.stop();
    await _db?.close();
  }
}
