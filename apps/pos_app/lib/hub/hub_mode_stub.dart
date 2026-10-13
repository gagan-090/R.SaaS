import 'hub_api.dart';

/// Hub mode needs dart:io + SQLite: available on Windows/Android only.
class HubHost {
  static bool get supported => false;
  PairingPayload? pairing;
  String? localDeviceToken;
  String? fingerprint;
  int port = 8443;
  Future<void> start(HubHostConfig c) async => throw UnsupportedError('Hub mode is not available on this platform');
  Future<PairingPayload> newPairingCode() async => throw UnsupportedError('Hub mode is not available on this platform');
  Future<void> stop() async {}
}

class HubHostConfig {
  const HubHostConfig({required this.cloudUrl, required this.cloudDeviceToken, required this.branchId, required this.branchCode, required this.licensePublicKey});
  final String cloudUrl, cloudDeviceToken, branchId, branchCode, licensePublicKey;
}
