import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../hub/hub_api.dart';
import '../hub/hub_mode.dart';

/// How this device reaches its hub. Device tokens are kept in the OS secure store (DPAPI / Android Keystore).
class DeviceSetup {
  const DeviceSetup({required this.hubBaseUrl, required this.deviceToken, this.fingerprint, this.hubConfig});
  final String hubBaseUrl;
  final String deviceToken;
  final String? fingerprint;

  /// Present when this device IS the hub (Hub mode).
  final HubHostConfig? hubConfig;
  bool get isHub => hubConfig != null;

  Map<String, Object?> toJson() => {
        'hubBaseUrl': hubBaseUrl, 'deviceToken': deviceToken, 'fingerprint': fingerprint,
        if (hubConfig != null)
          'hub': {
            'cloudUrl': hubConfig!.cloudUrl, 'cloudDeviceToken': hubConfig!.cloudDeviceToken, 'branchId': hubConfig!.branchId,
            'branchCode': hubConfig!.branchCode, 'licensePublicKey': hubConfig!.licensePublicKey,
          },
      };

  static DeviceSetup fromJson(Map<String, dynamic> j) {
    final h = j['hub'] as Map<String, dynamic>?;
    return DeviceSetup(
      hubBaseUrl: j['hubBaseUrl'] as String,
      deviceToken: j['deviceToken'] as String,
      fingerprint: j['fingerprint'] as String?,
      hubConfig: h == null
          ? null
          : HubHostConfig(cloudUrl: h['cloudUrl'] as String, cloudDeviceToken: h['cloudDeviceToken'] as String, branchId: h['branchId'] as String,
              branchCode: h['branchCode'] as String, licensePublicKey: h['licensePublicKey'] as String),
    );
  }
}

abstract class DeviceStore {
  Future<DeviceSetup?> read();
  Future<void> write(DeviceSetup? s);
}

class SecureDeviceStore implements DeviceStore {
  static const _key = 'rsaas.device.setup';
  final _s = const FlutterSecureStorage();
  @override
  Future<DeviceSetup?> read() async {
    final v = await _s.read(key: _key);
    return v == null ? null : DeviceSetup.fromJson(jsonDecode(v) as Map<String, dynamic>);
  }

  @override
  Future<void> write(DeviceSetup? s) => s == null ? _s.delete(key: _key) : _s.write(key: _key, value: jsonEncode(s.toJson()));
}

class MemoryDeviceStore implements DeviceStore {
  MemoryDeviceStore([this.value]);
  DeviceSetup? value;
  @override
  Future<DeviceSetup?> read() async => value;
  @override
  Future<void> write(DeviceSetup? s) async => value = s;
}

final deviceStoreProvider = Provider<DeviceStore>((ref) => SecureDeviceStore());
final hubHostProvider = Provider<HubHost>((ref) => HubHost());

/// Builds the hub client for a setup; tests override this with a fake.
final hubApiFactoryProvider = Provider<HubApi Function(DeviceSetup)>(
  (ref) => (s) => HttpHubApi(baseUrl: s.hubBaseUrl, deviceToken: s.deviceToken, certFingerprint: s.fingerprint),
);

class SetupNotifier extends AsyncNotifier<DeviceSetup?> {
  @override
  Future<DeviceSetup?> build() async {
    final s = await ref.read(deviceStoreProvider).read();
    if (s != null && s.isHub && HubHost.supported) await ref.read(hubHostProvider).start(s.hubConfig!);
    return s;
  }

  Future<void> save(DeviceSetup s) async {
    await ref.read(deviceStoreProvider).write(s);
    state = AsyncData(s);
  }

  Future<void> reset() async {
    await ref.read(hubHostProvider).stop();
    await ref.read(deviceStoreProvider).write(null);
    state = const AsyncData(null);
  }
}

final setupProvider = AsyncNotifierProvider<SetupNotifier, DeviceSetup?>(SetupNotifier.new);

final hubApiProvider = Provider<HubApi?>((ref) {
  final s = ref.watch(setupProvider).valueOrNull;
  return s == null ? null : ref.watch(hubApiFactoryProvider)(s);
});

/// Signed-in staff member on this terminal.
class StaffSession {
  const StaffSession({required this.userId, required this.name, required this.permissions, this.roles = const []});
  final String userId;
  final String name;
  final Set<String> permissions;
  final List<String> roles;
  bool can(String p) => permissions.contains(p);
  bool get isKitchenOnly => !can('order.write') && can('kds.read');
}

final sessionProvider = StateProvider<StaffSession?>((ref) => null);

/// Live hub events (WebSocket). Screens watch [hubTickProvider] to refetch when anything changes.
final hubEventsProvider = StreamProvider<Json>((ref) {
  final api = ref.watch(hubApiProvider);
  if (api == null) return const Stream.empty();
  return api.events();
});

final hubTickProvider = Provider<int>((ref) {
  ref.watch(hubEventsProvider);
  return DateTime.now().microsecondsSinceEpoch;
});
