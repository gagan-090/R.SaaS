import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../hub/hub_api.dart';
import '../hub/hub_mode.dart';

/// How this device reaches its hub. Device tokens are kept in the OS secure store (DPAPI / Android Keystore).
class DeviceSetup {
  const DeviceSetup({required this.hubBaseUrl, required this.deviceToken, this.fingerprint, this.hubConfig, this.altUrls = const [], this.relayUrl});
  final String hubBaseUrl;
  final String deviceToken;
  final String? fingerprint;

  /// The hub's other addresses (another Wi-Fi interface, a VPN such as Tailscale, a new IP found by a scan).
  final List<String> altUrls;

  /// The hub through the cloud relay, for when none of its addresses can be reached (another floor / ISP).
  final String? relayUrl;

  /// Present when this device IS the hub (Hub mode).
  final HubHostConfig? hubConfig;
  bool get isHub => hubConfig != null;

  Map<String, Object?> toJson() => {
        'hubBaseUrl': hubBaseUrl, 'deviceToken': deviceToken, 'fingerprint': fingerprint,
        if (altUrls.isNotEmpty) 'altUrls': altUrls,
        'relayUrl': ?relayUrl,
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
      altUrls: [for (final u in (j['altUrls'] as List? ?? const [])) '$u'],
      relayUrl: j['relayUrl'] as String?,
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
  SecureDeviceStore([FlutterSecureStorage? storage]) : _s = storage ?? const FlutterSecureStorage();
  static const _key = 'rsaas.device.setup';
  final FlutterSecureStorage _s;

  /// Saved setup that can no longer be decrypted (Android lost the key — e.g. the app was reinstalled and old data came
  /// back from a backup) is wiped: the device starts at the setup sign-in instead of an error screen it cannot leave.
  @override
  Future<DeviceSetup?> read() async {
    try {
      final v = await _s.read(key: _key);
      return v == null ? null : DeviceSetup.fromJson(jsonDecode(v) as Map<String, dynamic>);
    } catch (_) {
      await _wipe();
      return null;
    }
  }

  @override
  Future<void> write(DeviceSetup? s) async {
    Future<void> once() => s == null ? _s.delete(key: _key) : _s.write(key: _key, value: jsonEncode(s.toJson()));
    try {
      await once();
    } catch (_) {
      await _wipe(); // same unreadable leftovers: clear them and save again
      await once();
    }
  }

  Future<void> _wipe() async {
    try {
      await _s.deleteAll();
    } catch (_) {
      // nothing more to do: the next write starts a fresh store
    }
  }
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
  (ref) => (s) => HttpHubApi(baseUrl: s.hubBaseUrl, deviceToken: s.deviceToken, certFingerprint: s.fingerprint, alternates: s.altUrls, relayUrl: s.relayUrl,
      // the main device itself always reaches its own hub on this device
      onRoutes: s.isHub ? null : (lan, relay) => ref.read(setupProvider.notifier).saveRoutes(lan, relay)),
);

class SetupNotifier extends AsyncNotifier<DeviceSetup?> {
  @override
  Future<DeviceSetup?> build() async {
    final s = await ref.read(deviceStoreProvider).read();
    if (s != null && s.isHub && HubHost.supported) await ref.read(hubHostProvider).start(s.hubConfig!, localToken: s.deviceToken);
    return s;
  }

  Future<void> save(DeviceSetup s) async {
    await ref.read(deviceStoreProvider).write(s);
    state = AsyncData(s);
  }

  /// Remembers the hub routes a connection learned (no reconnect: staff stay signed in).
  Future<void> saveRoutes(List<String> altUrls, String? relayUrl) async {
    final s = state.valueOrNull;
    if (s == null || s.isHub) return;
    await save(DeviceSetup(hubBaseUrl: s.hubBaseUrl, deviceToken: s.deviceToken, fingerprint: s.fingerprint, altUrls: altUrls, relayUrl: relayUrl));
  }

  /// Main device only: point the hub's cloud sync at a new server address (e.g. the server's Wi-Fi IP changed).
  /// The address is checked first; staff stay signed in and the LAN pairing is unchanged.
  Future<void> changeServer(String url) async {
    final s = state.valueOrNull;
    if (s == null || !s.isHub) throw StateError('Only the main device (hub) syncs with the server');
    final base = url.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(base);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) throw const FormatException('Enter an address like http://10.0.0.5:3000/api/v1');
    try {
      await http.get(Uri.parse('$base/me')).timeout(const Duration(seconds: 8)); // any answer (401) means the API is there
    } catch (_) {
      throw FormatException('Cannot reach $base. Check the address and that this device is on the same Wi-Fi.');
    }
    final c = s.hubConfig!;
    final next = DeviceSetup(
      hubBaseUrl: s.hubBaseUrl, deviceToken: s.deviceToken, fingerprint: s.fingerprint,
      hubConfig: HubHostConfig(cloudUrl: base, cloudDeviceToken: c.cloudDeviceToken, branchId: c.branchId, branchCode: c.branchCode, licensePublicKey: c.licensePublicKey),
    );
    final host = ref.read(hubHostProvider);
    await host.stop();
    await host.start(next.hubConfig!, localToken: s.deviceToken);
    await save(next);
  }

  /// The owner made this Wi-Fi terminal the main device in the console: claim the role with the one-time code from
  /// the current hub, start this device's own hub and switch to it (staff sign in again here).
  Future<void> becomeMainDevice(Json offer) async {
    final cloudUrl = '${offer['cloudUrl']}';
    final platform = switch (defaultTargetPlatform) { TargetPlatform.windows => 'windows', TargetPlatform.iOS => 'ios', _ => 'android' };
    final res = await ref.read(promotionHttpProvider).post(Uri.parse('$cloudUrl/sync/promotion/claim'),
        headers: {'content-type': 'application/json'}, body: jsonEncode({'code': offer['code'], 'platform': platform})).timeout(const Duration(seconds: 75));
    final j = res.body.isEmpty ? const <String, dynamic>{} : jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 201) throw HubApiException(res.statusCode, '${j['code'] ?? 'error'}', '${j['message'] ?? 'Could not become the main device'}');
    final cfg = HubHostConfig(cloudUrl: cloudUrl, cloudDeviceToken: j['deviceToken'] as String, branchId: j['branchId'] as String,
        branchCode: j['branchCode'] as String, licensePublicKey: j['licensePublicKey'] as String);
    final host = ref.read(hubHostProvider);
    await host.start(cfg);
    ref.read(sessionProvider.notifier).state = null;
    await save(DeviceSetup(hubBaseUrl: 'https://127.0.0.1:${host.port}/hub/v1', deviceToken: host.localDeviceToken!, fingerprint: host.fingerprint, hubConfig: cfg));
  }

  Future<void> reset() async {
    await ref.read(hubHostProvider).stop();
    await ref.read(deviceStoreProvider).write(null);
    state = const AsyncData(null);
  }
}

final setupProvider = AsyncNotifierProvider<SetupNotifier, DeviceSetup?>(SetupNotifier.new);

final promotionHttpProvider = Provider<http.Client>((ref) => http.Client());

/// What this device is doing about becoming the main device (shown as a banner), null when nothing.
final promotionStatusProvider = StateProvider<String?>((ref) => null);

/// On a terminal joined to the main device: when the owner picks it in the console as the new main device, the hub
/// says so (event "device.promote") and this device takes over by itself. Also checked once when it connects.
final promotionWatcherProvider = Provider<void>((ref) {
  final setup = ref.watch(setupProvider).valueOrNull;
  final api = ref.watch(hubApiProvider);
  if (setup == null || setup.isHub || api == null || !HubHost.supported) return;
  var busy = false;
  // taken now: switching over rebuilds this provider, and the result still has to reach the banner
  final status = ref.read(promotionStatusProvider.notifier);
  final setupNotifier = ref.read(setupProvider.notifier);
  Future<void> check() async {
    if (busy) return;
    busy = true;
    try {
      final offer = await api.promotion();
      if (offer['pending'] != true) return;
      status.state = 'The owner made this the main device — switching over…';
      await setupNotifier.becomeMainDevice(offer);
      status.state = null;
    } catch (e) {
      if (status.state != null) status.state = 'Could not become the main device: $e';
    } finally {
      busy = false;
    }
  }

  ref.listen<AsyncValue<Json>>(hubEventsProvider, (_, next) {
    if (next.valueOrNull?['type'] == 'device.promote') check();
  });
  Future.microtask(check);
});

final hubApiProvider = Provider<HubApi?>((ref) {
  // only the LAN connection matters here: changing the cloud server address must not sign staff out
  ref.watch(setupProvider.select((a) => (a.valueOrNull?.hubBaseUrl, a.valueOrNull?.deviceToken, a.valueOrNull?.fingerprint)));
  final s = ref.read(setupProvider).valueOrNull;
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
/// A dropped connection (Wi-Fi switched, internet gone, app paused) reconnects by itself: 1 s, 2 s … up to 15 s apart.
final hubEventsProvider = StreamProvider<Json>((ref) {
  final api = ref.watch(hubApiProvider);
  if (api == null) return const Stream.empty();
  return reconnecting(api.events);
});

/// Re-opens [connect] whenever its stream ends; errors are passed on (the "hub offline" banner) until it is back.
Stream<T> reconnecting<T>(Stream<T> Function() connect, {Duration first = const Duration(seconds: 1), Duration max = const Duration(seconds: 15)}) {
  late final StreamController<T> out;
  StreamSubscription<T>? sub;
  Timer? retry;
  var wait = first;
  var closed = false;
  void open() {
    if (closed) return;
    try {
      sub = connect().listen(
        (e) {
          wait = first;
          out.add(e);
        },
        onError: out.addError,
        onDone: () {
          if (closed) return;
          retry = Timer(wait, open);
          wait = wait * 2 > max ? max : wait * 2;
        },
      );
    } catch (e, st) {
      out.addError(e, st);
      retry = Timer(wait, open);
      wait = wait * 2 > max ? max : wait * 2;
    }
  }

  out = StreamController<T>(
    onListen: open,
    onCancel: () async {
      closed = true;
      retry?.cancel();
      await sub?.cancel();
    },
  );
  return out.stream;
}

/// Bumped by pull-down-to-refresh (anywhere in the app): screens reload their data and photos.
final refreshTickProvider = StateProvider<int>((ref) => 0);

final hubTickProvider = Provider<int>((ref) {
  ref.watch(hubEventsProvider);
  ref.watch(refreshTickProvider);
  return DateTime.now().microsecondsSinceEpoch;
});

/// Light / dark / follow the device. Remembered on this device (browser storage on the web).
class ThemeModeNotifier extends Notifier<ThemeMode> {
  // v2: the white (Light) theme became the default on 13 Oct 2026, so earlier "Auto" choices start over
  static const _key = 'appearance.v2';

  @override
  ThemeMode build() {
    _load();
    return ThemeMode.light;
  }

  Future<void> _load() async {
    try {
      final v = (await SharedPreferences.getInstance()).getString(_key);
      if (v != null) state = ThemeMode.values.firstWhere((m) => m.name == v, orElse: () => ThemeMode.light);
    } catch (_) {
      // storage unavailable (private window, tests): stay on the white theme
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    try {
      await (await SharedPreferences.getInstance()).setString(_key, mode.name);
    } catch (_) {}
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

/// The restaurant's name and look from the hub (plan feature "branding", set in the web console). `brand` is null
/// for the BhojMitra look. Checked again every minute and on pull-down-to-refresh; the hub pulls it from the cloud.
typedef PosLook = ({String name, HPBrand? brand});
final posLookProvider = FutureProvider<PosLook?>((ref) async {
  ref.watch(refreshTickProvider);
  final api = ref.watch(hubApiProvider);
  if (api == null) return null;
  final again = Timer(const Duration(seconds: 60), ref.invalidateSelf);
  ref.onDispose(again.cancel);
  try {
    final tenant = (await api.branch())['tenant'] as Map?;
    return (name: '${tenant?['name'] ?? ''}', brand: HPBrand.fromJson(tenant?['branding']));
  } catch (_) {
    return null; // hub unreachable: keep the BhojMitra look
  }
});
