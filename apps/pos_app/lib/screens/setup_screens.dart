import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';
import '../hub/hub_mode.dart';
import '../state/app_state.dart';

void toast(BuildContext c, String msg, {bool error = false}) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(msg), backgroundColor: error ? HPColors.chili : HPColors.emberRaised));

String errText(Object e) => e is HubApiException ? e.message : '$e';

/// Pairs with a hub: overridable so tests do not open sockets.
final pairFnProvider = Provider<Future<String> Function(PairingPayload, String name, String platform)>(
  (ref) => (p, name, platform) => claimPairing(p, deviceName: name, platform: platform),
);

/// S1 Device setup: pair with the branch hub, or make this device the hub.
class DeviceSetupScreen extends ConsumerStatefulWidget {
  const DeviceSetupScreen({super.key});
  @override
  ConsumerState<DeviceSetupScreen> createState() => _DeviceSetupScreenState();
}

class _DeviceSetupScreenState extends ConsumerState<DeviceSetupScreen> {
  final _payload = TextEditingController(), _ip = TextEditingController(), _port = TextEditingController(text: '8443'),
      _code = TextEditingController(), _fp = TextEditingController(), _name = TextEditingController(text: 'Cashier terminal');
  final _cloud = TextEditingController(text: const String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:3000/api/v1')),
      _email = TextEditingController(), _password = TextEditingController(), _mfa = TextEditingController();
  bool _busy = false, _needMfa = false;
  String? _challenge;

  String get _platform => Theme.of(context).platform == TargetPlatform.windows ? 'windows' : 'android';

  Future<void> _pair() async {
    final p = PairingPayload.tryParse(_payload.text) ??
        (int.tryParse(_port.text) == null || _ip.text.trim().isEmpty || _code.text.trim().isEmpty
            ? null
            : PairingPayload(host: _ip.text.trim(), port: int.parse(_port.text), code: _code.text.trim(), fingerprint: _fp.text.trim().isEmpty ? null : _fp.text.trim().toUpperCase()));
    if (p == null) return toast(context, 'Scan the hub QR or enter IP, port and code', error: true);
    setState(() => _busy = true);
    try {
      final token = await ref.read(pairFnProvider)(p, _name.text.trim(), _platform);
      await ref.read(setupProvider.notifier).save(DeviceSetup(hubBaseUrl: p.baseUrl, deviceToken: token, fingerprint: p.fingerprint));
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Hub mode: owner signs in to the cloud once; the cloud registers this device as the branch hub.
  Future<void> _becomeHub() async {
    setState(() => _busy = true);
    final base = _cloud.text.trim().replaceAll(RegExp(r'/$'), '');
    Future<Map<String, dynamic>> post(String path, Object body, {String? bearer}) async {
      final r = await http.post(Uri.parse('$base$path'),
          headers: {'content-type': 'application/json', if (bearer != null) 'authorization': 'Bearer $bearer'}, body: jsonEncode(body));
      final j = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode >= 400) throw HubApiException(r.statusCode, '${j['code']}', '${j['message']}');
      return j;
    }

    try {
      String access;
      if (_needMfa) {
        access = (await post('/auth/mfa/verify', {'challengeToken': _challenge, 'code': _mfa.text.trim()}))['accessToken'] as String;
      } else {
        final l = await post('/auth/login', {'email': _email.text.trim(), 'password': _password.text});
        if (l['status'] == 'mfa_required') {
          setState(() { _needMfa = true; _challenge = l['challengeToken'] as String; });
          return;
        }
        access = l['accessToken'] as String;
      }
      final reg = await post('/devices/register-hub', {'name': _name.text.trim(), 'platform': _platform}, bearer: access);
      final cfg = HubHostConfig(cloudUrl: base, cloudDeviceToken: reg['deviceToken'] as String, branchId: reg['branchId'] as String,
          branchCode: reg['branchCode'] as String, licensePublicKey: reg['licensePublicKey'] as String);
      final host = ref.read(hubHostProvider);
      await host.start(cfg);
      await ref.read(setupProvider.notifier).save(DeviceSetup(
          hubBaseUrl: 'https://127.0.0.1:${host.port}/hub/v1', deviceToken: host.localDeviceToken!, fingerprint: host.fingerprint, hubConfig: cfg));
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(HPSpace.x2),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('SET UP THIS DEVICE', style: HPType.overline(HPColors.saffron)),
                  const SizedBox(height: HPSpace.sm),
                  Text('Pair with the kitchen hub', style: HPType.titleScreen(HPColors.ghee)),
                  const SizedBox(height: HPSpace.x2),
                  TextField(controller: _name, decoration: const InputDecoration(labelText: 'Device name')),
                  const SizedBox(height: HPSpace.lg),
                  Wrap(spacing: HPSpace.lg, runSpacing: HPSpace.lg, children: [
                    SizedBox(width: 460, child: _card('Pair with a hub', Icons.qr_code_scanner_rounded, [
                      TextField(key: const Key('pair-payload'), controller: _payload, decoration: const InputDecoration(labelText: 'Scan QR (or paste its text)', helperText: 'Camera scanning: see MORNING.md')),
                      const SizedBox(height: HPSpace.md),
                      Text('or enter it by hand', style: HPType.body(HPColors.husk)),
                      const SizedBox(height: HPSpace.sm),
                      Row(children: [
                        Expanded(flex: 3, child: TextField(controller: _ip, decoration: const InputDecoration(labelText: 'Hub IP'))),
                        const SizedBox(width: HPSpace.sm),
                        Expanded(flex: 2, child: TextField(controller: _port, decoration: const InputDecoration(labelText: 'Port'))),
                      ]),
                      const SizedBox(height: HPSpace.sm),
                      TextField(controller: _code, decoration: const InputDecoration(labelText: '6-digit code')),
                      const SizedBox(height: HPSpace.sm),
                      TextField(controller: _fp, decoration: const InputDecoration(labelText: 'Certificate fingerprint (from the hub screen)')),
                      const SizedBox(height: HPSpace.lg),
                      PrimaryButton(label: 'Pair', busy: _busy, onPressed: _pair),
                    ])),
                    if (HubHost.supported)
                      SizedBox(width: 460, child: _card('This device is the hub', Icons.router_rounded, [
                        Text('Use the main cashier PC. It keeps working when the internet is down; keep it on a UPS.', style: HPType.body(HPColors.husk)),
                        const SizedBox(height: HPSpace.md),
                        TextField(controller: _cloud, decoration: const InputDecoration(labelText: 'Cloud API URL')),
                        const SizedBox(height: HPSpace.sm),
                        TextField(controller: _email, decoration: const InputDecoration(labelText: 'Owner / IT admin email')),
                        const SizedBox(height: HPSpace.sm),
                        TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
                        if (_needMfa) ...[const SizedBox(height: HPSpace.sm), TextField(controller: _mfa, decoration: const InputDecoration(labelText: 'Authenticator code'))],
                        const SizedBox(height: HPSpace.lg),
                        SecondaryButton(label: 'Make this the hub', icon: Icons.power_settings_new_rounded, onPressed: _busy ? null : _becomeHub),
                      ])),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      );

  Widget _card(String title, IconData icon, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(HPSpace.x2),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [Icon(icon, color: HPColors.saffron), const SizedBox(width: HPSpace.sm), Expanded(child: Text(title, style: HPType.titleCard(HPColors.ghee), overflow: TextOverflow.ellipsis))]),
            const SizedBox(height: HPSpace.lg),
            ...children,
          ]),
        ),
      );
}

/// S2 Hub status (hub device): pairing QR + sync counts.
class HubStatusScreen extends ConsumerStatefulWidget {
  const HubStatusScreen({super.key});
  @override
  ConsumerState<HubStatusScreen> createState() => _HubStatusScreenState();
}

class _HubStatusScreenState extends ConsumerState<HubStatusScreen> {
  @override
  Widget build(BuildContext context) {
    final host = ref.read(hubHostProvider);
    final api = ref.watch(hubApiProvider);
    ref.watch(hubTickProvider);
    final p = host.pairing;
    return Scaffold(
      appBar: AppBar(title: const Text('Hub status')),
      body: ListView(padding: const EdgeInsets.all(HPSpace.x2), children: [
        if (p != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(HPSpace.x2),
              child: Column(children: [
                Text('Scan to pair a device', style: HPType.titleCard(HPColors.ghee)),
                const SizedBox(height: HPSpace.lg),
                QrImageView(data: p.encode(), size: 220, backgroundColor: Colors.white),
                const SizedBox(height: HPSpace.md),
                SelectableText('IP ${p.host}:${p.port} · code ${p.code}\n${p.fingerprint}', textAlign: TextAlign.center, style: HPType.mono(HPColors.husk)),
                const SizedBox(height: HPSpace.md),
                SecondaryButton(label: 'New code', icon: Icons.refresh, onPressed: () async {
                  await host.newPairingCode();
                  setState(() {});
                }),
              ]),
            ),
          )
        else
          const EmptyState(title: 'Not running as hub', message: 'This device is paired to another hub.'),
        const SizedBox(height: HPSpace.lg),
        if (api != null)
          FutureBuilder<Json>(
            future: api.syncStatus(),
            builder: (c, s) => s.hasData
                ? Wrap(spacing: HPSpace.sm, children: [
                    StatusChip(label: '${s.data!['pending']} waiting to sync', tone: (s.data!['pending'] as int) > 0 ? HPTone.saffron : HPTone.success),
                    StatusChip(label: '${s.data!['failed']} failed', tone: (s.data!['failed'] as int) > 0 ? HPTone.danger : HPTone.neutral),
                    StatusChip(label: '${s.data!['pushed']} synced', tone: HPTone.success),
                  ])
                : const LoadingState(),
          ),
      ]),
    );
  }
}

/// S3 Staff login: user tiles + PIN pad.
class StaffLoginScreen extends ConsumerStatefulWidget {
  const StaffLoginScreen({super.key});
  @override
  ConsumerState<StaffLoginScreen> createState() => _StaffLoginScreenState();
}

class _StaffLoginScreenState extends ConsumerState<StaffLoginScreen> {
  Json? _user;
  String _pin = '';
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    final api = ref.read(hubApiProvider)!;
    setState(() { _busy = true; _error = null; });
    try {
      final r = await api.login(_user!['id'] as String, _pin);
      ref.read(sessionProvider.notifier).state = StaffSession(
        userId: (r['user'] as Map)['id'] as String,
        name: (r['user'] as Map)['name'] as String,
        permissions: (r['permissions'] as List).cast<String>().toSet(),
      );
    } catch (e) {
      setState(() { _error = errText(e); _pin = ''; });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(hubApiProvider)!;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const StatusBar(showUser: false),
          Expanded(
            child: FutureBuilder<List<Json>>(
              future: api.staff(),
              builder: (c, s) {
                if (s.hasError) return ErrorState(message: errText(s.error!), onRetry: () => setState(() {}));
                if (!s.hasData) return const LoadingState();
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(HPSpace.x2),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: Column(children: [
                        Text(_user == null ? 'Who is working?' : 'Hello, ${_user!['name']}', style: HPType.titleScreen(HPColors.ghee)),
                        const SizedBox(height: HPSpace.x2),
                        if (_user == null)
                          Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, alignment: WrapAlignment.center, children: [
                            for (final u in s.data!)
                              SizedBox(
                                width: 160,
                                child: Card(
                                  child: InkWell(
                                    key: Key('staff-${u['name']}'),
                                    borderRadius: BorderRadius.circular(HPRadius.card),
                                    onTap: () => setState(() => _user = u),
                                    child: Padding(
                                      padding: const EdgeInsets.all(HPSpace.lg),
                                      child: Column(children: [
                                        CircleAvatar(radius: 26, backgroundColor: HPColors.emberRaised, child: Text('${u['name']}'[0], style: HPType.titleCard(HPColors.saffron))),
                                        const SizedBox(height: HPSpace.sm),
                                        Text('${u['name']}', style: HPType.label(HPColors.ghee), overflow: TextOverflow.ellipsis),
                                        Text((u['roles'] as List).join(', '), style: HPType.body(HPColors.husk).copyWith(fontSize: 12)),
                                      ]),
                                    ),
                                  ),
                                ),
                              ),
                          ])
                        else
                          SizedBox(
                            width: 320,
                            child: Column(children: [
                              Text('•' * _pin.length + '○' * (4 - _pin.length).clamp(0, 4), key: const Key('pin-dots'), style: HPType.displayTotal(HPColors.saffron).copyWith(letterSpacing: 12)),
                              if (_error != null) Text(_error!, style: HPType.body(HPColors.chili)),
                              const SizedBox(height: HPSpace.lg),
                              NumericKeypad(
                                onKey: (d) => setState(() => _pin = _pin.length < 8 ? _pin + d : _pin),
                                onBackspace: () => setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1)),
                                onClear: () => setState(() => _pin = ''),
                              ),
                              const SizedBox(height: HPSpace.lg),
                              PrimaryButton(label: 'Sign in', busy: _busy, onPressed: _pin.length >= 4 ? _submit : null),
                              TextButton(onPressed: () => setState(() { _user = null; _pin = ''; _error = null; }), child: const Text('Not you?')),
                            ]),
                          ),
                      ]),
                    ),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

/// S4 Status bar on every screen: hub online/offline, sync counts, signed-in user.
class StatusBar extends ConsumerWidget {
  const StatusBar({super.key, this.showUser = true, this.title});
  final bool showUser;
  final String? title;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ev = ref.watch(hubEventsProvider);
    final session = ref.watch(sessionProvider);
    final setup = ref.watch(setupProvider).valueOrNull;
    final online = !ev.hasError;
    return Column(children: [
      Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: HPSpace.lg),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: HPColors.clayLine))),
        child: Row(children: [
          Text(title ?? 'House Plating', style: HPType.titleCard(HPColors.ghee)),
          const SizedBox(width: HPSpace.lg),
          StatusChip(label: online ? 'Hub online' : 'Hub offline', tone: online ? HPTone.success : HPTone.danger, icon: online ? Icons.wifi_rounded : Icons.wifi_off_rounded),
          const SizedBox(width: HPSpace.sm),
          const _SyncChip(),
          const Spacer(),
          if (setup?.isHub ?? false)
            IconButton(tooltip: 'Hub status', icon: const Icon(Icons.router_rounded), onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HubStatusScreen()))),
          if (showUser && session != null) ...[
            Text(session.name, style: HPType.label(HPColors.ghee)),
            IconButton(tooltip: 'Switch user', icon: const Icon(Icons.logout_rounded), onPressed: () {
              ref.read(hubApiProvider)?.sessionToken = null;
              ref.read(sessionProvider.notifier).state = null;
              Navigator.of(context).popUntil((r) => r.isFirst);
            }),
          ],
        ]),
      ),
      if (!online) const OfflineBanner(message: 'Kitchen hub offline — orders paused until it is back'),
    ]);
  }
}

class _SyncChip extends ConsumerWidget {
  const _SyncChip();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(hubTickProvider);
    final api = ref.watch(hubApiProvider);
    if (api == null) return const SizedBox.shrink();
    return FutureBuilder<Json>(
      future: api.syncStatus(),
      builder: (c, s) {
        if (!s.hasData) return const SizedBox.shrink();
        final pending = s.data!['pending'] as int, failed = s.data!['failed'] as int;
        if (failed > 0) return StatusChip(label: '$failed failed to sync', tone: HPTone.danger);
        return StatusChip(label: pending > 0 ? '$pending waiting to sync' : 'All synced', tone: pending > 0 ? HPTone.saffron : HPTone.neutral, icon: Icons.cloud_sync_rounded);
      },
    );
  }
}
