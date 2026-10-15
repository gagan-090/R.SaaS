import 'dart:io';

import 'package:rsaas_hub/rsaas_hub.dart';

/// Standalone hub for development (the POS app embeds the same HubServer in Hub mode).
/// Env: HUB_BRANCH_ID, HUB_BRANCH_CODE, LICENSE_PUBLIC_KEY, CLOUD_API_URL, HUB_CLOUD_DEVICE_TOKEN,
///      HUB_DATA_DIR (default ./.hubdata), HUB_PORT (default 8443).
Future<void> main() async {
  String need(String k) => Platform.environment[k] ?? (throw StateError('$k is required (see .env.example)'));
  final dir = Directory(Platform.environment['HUB_DATA_DIR'] ?? '.hubdata')..createSync(recursive: true);
  final db = HubDatabase.file(File('${dir.path}/hub.sqlite'));
  final hub = HubService(db, HubConfig(branchId: need('HUB_BRANCH_ID'), branchCode: need('HUB_BRANCH_CODE'), licensePublicKey: need('LICENSE_PUBLIC_KEY')));

  // TLS: keep one self-signed cert per hub (gitignored *.pem); clients pin its fingerprint.
  final certFile = File('${dir.path}/hub-cert.pem'), keyFile = File('${dir.path}/hub-key.pem');
  final HubTls tls;
  if (certFile.existsSync() && keyFile.existsSync()) {
    tls = HubTls(certFile.readAsStringSync(), keyFile.readAsStringSync());
  } else {
    tls = HubTls.generate();
    certFile.writeAsStringSync(tls.certPem);
    keyFile.writeAsStringSync(tls.keyPem);
  }

  final cloud = CloudClient(need('CLOUD_API_URL'), need('HUB_CLOUD_DEVICE_TOKEN'));
  final worker = SyncWorker(db, hub, cloud);
  try {
    await worker.pullOnce();
  } catch (e) {
    stderr.writeln('initial pull failed (working offline): $e');
  }
  final server = HubServer(hub, hubName: Platform.localHostname, refreshStaff: worker.pullOnce, certFingerprint: tls.fingerprint);
  final port = int.parse(Platform.environment['HUB_PORT'] ?? '8443');
  await server.start(port: port, tls: tls.context());
  worker.start();
  final code = await hub.createPairingCode();
  stdout.writeln('Hub listening on https://0.0.0.0:$port/hub/v1');
  stdout.writeln('Pairing code (10 min): $code   fingerprint: ${tls.fingerprint}');
  ProcessSignal.sigint.watch().listen((_) async {
    worker.stop();
    await server.stop();
    await db.close();
    exit(0);
  });
}
