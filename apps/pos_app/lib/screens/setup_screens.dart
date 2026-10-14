import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';
import '../hub/hub_mode.dart';
import '../state/app_state.dart';
import '../ui/common.dart';
import '../ui/media.dart';
import '../ui/shell.dart';

/// Pairs with a hub: overridable so tests do not open sockets.
final pairFnProvider = Provider<Future<String> Function(PairingPayload, String name, String platform)>(
  (ref) => (p, name, platform) => claimPairing(p, deviceName: name, platform: platform),
);

class _Brand extends StatelessWidget {
  const _Brand();
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: HPColors.saffron, shape: BoxShape.circle),
          child: Icon(Icons.restaurant_rounded, color: HPColors.onSaffron, size: 22),
        ),
        const SizedBox(width: HPSpace.sm),
        Text('HOUSE PLATING', style: HPType.overline(context.hp.accentInk)),
      ]);
}

/// S1 Device setup: make this device the branch hub (signs in to the cloud once) or join an existing hub.
class DeviceSetupScreen extends ConsumerStatefulWidget {
  const DeviceSetupScreen({super.key});
  @override
  ConsumerState<DeviceSetupScreen> createState() => _DeviceSetupScreenState();
}

class _DeviceSetupScreenState extends ConsumerState<DeviceSetupScreen> {
  final _payload = TextEditingController(), _ip = TextEditingController(), _port = TextEditingController(text: '8443'),
      _code = TextEditingController(), _fp = TextEditingController(), _name = TextEditingController(text: 'Cashier terminal');
  final _cloud = TextEditingController(text: const String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:3000/api/v1')),
      _email = TextEditingController(), _password = TextEditingController(), _mfa = TextEditingController(),
      _newPin = TextEditingController(), _newPinAgain = TextEditingController();
  bool _busy = false, _needMfa = false, _needPin = false, _manual = false, _showPassword = false;
  String? _access; // kept while the owner chooses a PIN, so they do not sign in twice
  late bool _asHub = HubHost.supported;
  String? _challenge, _error;

  String get _platform => Theme.of(context).platform == TargetPlatform.windows ? 'windows' : 'android';

  Future<void> _pair() async {
    final p = PairingPayload.tryParse(_payload.text) ??
        (int.tryParse(_port.text) == null || _ip.text.trim().isEmpty || _code.text.trim().isEmpty
            ? null
            : PairingPayload(host: _ip.text.trim(), port: int.parse(_port.text), code: _code.text.trim(), fingerprint: _fp.text.trim().isEmpty ? null : _fp.text.trim().toUpperCase()));
    if (p == null) return setState(() => _error = 'Paste the pairing text shown on the hub, or enter its IP address and 6-digit code');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await ref.read(pairFnProvider)(p, _name.text.trim(), _platform);
      await ref.read(setupProvider.notifier).save(DeviceSetup(hubBaseUrl: p.baseUrl, deviceToken: token, fingerprint: p.fingerprint));
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Hub mode: owner signs in to the cloud once; the cloud registers this device as the branch hub.
  Future<void> _becomeHub() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final base = _cloud.text.trim().replaceAll(RegExp(r'/$'), '');
    Future<Map<String, dynamic>> call(String method, String path, {Object? body, String? bearer}) async {
      final http.Response r;
      try {
        final headers = {'content-type': 'application/json', if (bearer != null) 'authorization': 'Bearer $bearer'};
        final uri = Uri.parse('$base$path');
        r = await (switch (method) {
          'GET' => http.get(uri, headers: headers),
          'PUT' => http.put(uri, headers: headers, body: jsonEncode(body)),
          _ => http.post(uri, headers: headers, body: jsonEncode(body)),
        })
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        throw HubApiException(0, 'unreachable', 'Cannot reach $base — check the address and that this device is on the same Wi-Fi');
      }
      final j = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode >= 400) throw HubApiException(r.statusCode, '${j['code']}', '${j['message']}');
      return j;
    }

    Future<Map<String, dynamic>> post(String path, Object body, {String? bearer}) => call('POST', path, body: body, bearer: bearer);

    try {
      var access = _access;
      if (access == null) {
        if (_needMfa) {
          access = (await post('/auth/mfa/verify', {'challengeToken': _challenge, 'code': _mfa.text.trim()}))['accessToken'] as String;
        } else {
          final l = await post('/auth/login', {'email': _email.text.trim(), 'password': _password.text});
          if (l['status'] == 'mfa_required') {
            setState(() {
              _needMfa = true;
              _challenge = l['challengeToken'] as String;
            });
            return;
          }
          access = l['accessToken'] as String;
        }
      }
      if (!_needPin) {
        // The POS signs everyone in with a PIN. An owner who signed up on the web has none yet: choose it now.
        final me = await call('GET', '/me', bearer: access);
        if (me['hasPin'] == false) {
          setState(() {
            _access = access;
            _needPin = true;
          });
          return;
        }
      } else {
        final pin = _newPin.text.trim();
        if (!RegExp(r'^\d{4,8}$').hasMatch(pin)) throw HubApiException(400, 'pin', 'PIN must be 4–8 digits');
        if (pin != _newPinAgain.text.trim()) throw HubApiException(400, 'pin', 'The two PINs do not match');
        await call('PUT', '/me/pin', body: {'pin': pin}, bearer: access);
      }
      final reg = await post('/devices/register-hub', {'name': _name.text.trim(), 'platform': _platform}, bearer: access);
      final cfg = HubHostConfig(cloudUrl: base, cloudDeviceToken: reg['deviceToken'] as String, branchId: reg['branchId'] as String,
          branchCode: reg['branchCode'] as String, licensePublicKey: reg['licensePublicKey'] as String);
      final host = ref.read(hubHostProvider);
      await host.start(cfg);
      await ref.read(setupProvider.notifier).save(DeviceSetup(
          hubBaseUrl: 'https://127.0.0.1:${host.port}/hub/v1', deviceToken: host.localDeviceToken!, fingerprint: host.fingerprint, hubConfig: cfg));
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(HPSpace.x2),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    const _Brand(),
                    const Spacer(),
                    ThemeModeSwitch(compact: true, value: ref.watch(themeModeProvider), onChanged: ref.read(themeModeProvider.notifier).set),
                  ]),
                  const SizedBox(height: HPSpace.x2),
                  Text('Set up this device', style: HPType.titleScreen(p.text)),
                  const SizedBox(height: HPSpace.xs),
                  Text('Do this once. Afterwards staff only need their PIN.', style: HPType.body(p.muted).copyWith(fontSize: 15)),
                  const SizedBox(height: HPSpace.x2),
                  if (HubHost.supported)
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: true, label: Text('Main device'), icon: Icon(Icons.router_rounded)),
                        ButtonSegment(value: false, label: Text('Join a hub'), icon: Icon(Icons.link_rounded)),
                      ],
                      selected: {_asHub},
                      onSelectionChanged: (v) => setState(() {
                        _asHub = v.first;
                        _error = null;
                      }),
                    ),
                  const SizedBox(height: HPSpace.lg),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: KeyedSubtree(key: ValueKey(_asHub), child: _asHub ? _hubForm(p) : _pairForm(p)),
                  ),
                  if (_error != null)
                    Container(
                      margin: const EdgeInsets.only(top: HPSpace.md),
                      padding: const EdgeInsets.all(HPSpace.md),
                      decoration: BoxDecoration(color: p.danger.withValues(alpha: .12), borderRadius: BorderRadius.circular(12)),
                      child: Row(children: [
                        Icon(Icons.error_outline_rounded, color: p.danger),
                        const SizedBox(width: HPSpace.sm),
                        Expanded(child: Text(_error!, key: const Key('setup-error'), style: HPType.body(p.text))),
                      ]),
                    ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hubForm(HPPalette p) => Card(
        child: Padding(
          padding: const EdgeInsets.all(HPSpace.x2),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('This device runs the restaurant', style: HPType.titleCard(p.text)),
            const SizedBox(height: 4),
            Text('Use the main cashier device. Billing keeps working when the internet is down; keep it charged.', style: HPType.body(p.muted)),
            const SizedBox(height: HPSpace.lg),
            TextField(controller: _cloud, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Server address', prefixIcon: Icon(Icons.cloud_outlined))),
            const SizedBox(height: HPSpace.md),
            TextField(
              key: const Key('hub-email'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Owner or IT admin email', prefixIcon: Icon(Icons.alternate_email_rounded)),
            ),
            const SizedBox(height: HPSpace.md),
            TextField(
              key: const Key('hub-password'),
              controller: _password,
              obscureText: !_showPassword,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  tooltip: _showPassword ? 'Hide password' : 'Show password',
                  icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: () => setState(() => _showPassword = !_showPassword),
                ),
              ),
              onSubmitted: (_) => _becomeHub(),
            ),
            if (_needPin) ...[
              const SizedBox(height: HPSpace.lg),
              Container(
                key: const Key('choose-pin'),
                padding: const EdgeInsets.all(HPSpace.md),
                decoration: BoxDecoration(color: HPColors.saffron.withValues(alpha: .14), borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('Choose your POS PIN', style: HPType.titleCard(p.text)),
                  const SizedBox(height: 2),
                  Text('You have no PIN yet. Everyone signs in on this device with a PIN, 4 to 8 digits.', style: HPType.body(p.muted)),
                  const SizedBox(height: HPSpace.md),
                  TextField(key: const Key('new-pin'), controller: _newPin, autofocus: true, obscureText: true, maxLength: 8, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'New PIN', counterText: '', prefixIcon: Icon(Icons.pin_outlined))),
                  const SizedBox(height: HPSpace.sm),
                  TextField(key: const Key('new-pin-again'), controller: _newPinAgain, obscureText: true, maxLength: 8, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'Type it again', counterText: '', prefixIcon: Icon(Icons.pin_outlined)), onSubmitted: (_) => _becomeHub()),
                ]),
              ),
            ],
            if (_needMfa) ...[
              const SizedBox(height: HPSpace.md),
              TextField(controller: _mfa, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Authenticator code', prefixIcon: Icon(Icons.verified_user_outlined))),
            ],
            const SizedBox(height: HPSpace.md),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name of this device', prefixIcon: Icon(Icons.devices_rounded))),
            const SizedBox(height: HPSpace.x2),
            PrimaryButton(key: const Key('make-hub'), label: _needPin ? 'Save PIN and make this the hub' : 'Make this the hub', icon: Icons.power_settings_new_rounded, busy: _busy, onPressed: _becomeHub),
          ]),
        ),
      );

  Widget _pairForm(HPPalette p) => Card(
        child: Padding(
          padding: const EdgeInsets.all(HPSpace.x2),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Join the restaurant\'s hub', style: HPType.titleCard(p.text)),
            const SizedBox(height: 4),
            Text('On the hub open More → Hub & devices. Copy the pairing text here, or type its address and code.', style: HPType.body(p.muted)),
            const SizedBox(height: HPSpace.lg),
            TextField(key: const Key('pair-payload'), controller: _payload, decoration: const InputDecoration(labelText: 'Pairing text from the hub', prefixIcon: Icon(Icons.link_rounded))),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: () => setState(() => _manual = !_manual), icon: Icon(_manual ? Icons.expand_less_rounded : Icons.expand_more_rounded), label: const Text('Enter the address by hand')),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              child: !_manual
                  ? const SizedBox(width: double.infinity)
                  : Column(children: [
                      Row(children: [
                        Expanded(flex: 3, child: TextField(controller: _ip, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Hub IP'))),
                        const SizedBox(width: HPSpace.sm),
                        Expanded(flex: 2, child: TextField(controller: _port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port'))),
                      ]),
                      const SizedBox(height: HPSpace.sm),
                      TextField(controller: _code, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '6-digit code')),
                      const SizedBox(height: HPSpace.sm),
                      TextField(controller: _fp, decoration: const InputDecoration(labelText: 'Security fingerprint (from the hub screen)')),
                    ]),
            ),
            const SizedBox(height: HPSpace.md),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name of this device', prefixIcon: Icon(Icons.devices_rounded))),
            const SizedBox(height: HPSpace.x2),
            PrimaryButton(label: 'Pair', icon: Icons.link_rounded, busy: _busy, onPressed: _pair),
          ]),
        ),
      );
}

/// S2 Hub & devices (on the hub): pairing code + QR for new terminals, sync health, reset.
class HubStatusScreen extends ConsumerStatefulWidget {
  const HubStatusScreen({super.key});
  @override
  ConsumerState<HubStatusScreen> createState() => _HubStatusScreenState();
}

class _HubStatusScreenState extends ConsumerState<HubStatusScreen> {
  Future<void> _changeServer(BuildContext context) async {
    final ctl = TextEditingController(text: ref.read(setupProvider).valueOrNull?.hubConfig?.cloudUrl ?? '');
    final url = await showDialog<String>(
      context: context,
      builder: (c) => HPDialog(
        title: 'Change server address',
        actions: [SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c)), PrimaryButton(key: const Key('save-server'), label: 'Save', height: 56, onPressed: () => Navigator.pop(c, ctl.text))],
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Use this when the server moved, for example its Wi-Fi IP changed. Staff stay signed in.', style: HPType.body(c.hp.muted)),
          const SizedBox(height: HPSpace.md),
          TextField(key: const Key('server-url'), controller: ctl, autofocus: true, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Server address', hintText: 'http://10.0.0.5:3000/api/v1')),
        ]),
      ),
    );
    if (url == null || !context.mounted) return;
    try {
      await ref.read(setupProvider.notifier).changeServer(url);
      if (context.mounted) toast(context, 'Server address saved — syncing with it now');
    } catch (e) {
      if (context.mounted) toast(context, e is FormatException ? e.message : '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = ref.read(hubHostProvider);
    final api = ref.watch(hubApiProvider);
    ref.watch(hubTickProvider);
    final pairing = host.pairing;
    final p = context.hp;
    return Scaffold(
      body: Column(children: [
        const PosTopBar(title: 'Hub & devices'),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(padding: const EdgeInsets.all(HPSpace.lg), children: [
                if (pairing != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(HPSpace.x2),
                      child: Column(children: [
                        Text('Pair another device', style: HPType.titleCard(p.text)),
                        const SizedBox(height: 4),
                        Text('On the new device choose "Join a hub" and use this code. It works once, for 10 minutes.', textAlign: TextAlign.center, style: HPType.body(p.muted)),
                        const SizedBox(height: HPSpace.lg),
                        Container(
                          padding: const EdgeInsets.all(HPSpace.md),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(HPRadius.card)),
                          child: QrImageView(data: pairing.encode(), size: 200),
                        ),
                        const SizedBox(height: HPSpace.lg),
                        Text(pairing.code.split('').join(' '), style: HPType.displayTotal(p.text).copyWith(fontSize: 36, letterSpacing: 4)),
                        Text('${pairing.host}:${pairing.port}', style: HPType.mono(p.muted)),
                        const SizedBox(height: HPSpace.md),
                        Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, alignment: WrapAlignment.center, children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            label: const Text('Copy pairing text'),
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: pairing.encode()));
                              if (context.mounted) toast(context, 'Pairing text copied');
                            },
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: const Text('New code'),
                            onPressed: () async {
                              await host.newPairingCode();
                              setState(() {});
                            },
                          ),
                        ]),
                      ]),
                    ),
                  )
                else
                  const EmptyState(title: 'Paired to a hub', message: 'This device works with the hub on your restaurant Wi-Fi.', icon: Icons.link_rounded),
                const SizedBox(height: HPSpace.lg),
                if (api != null)
                  FutureBuilder<Json>(
                    future: api.syncStatus(),
                    builder: (c, s) => s.hasData
                        ? Card(
                            child: Padding(
                              padding: const EdgeInsets.all(HPSpace.lg),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('CLOUD SYNC', style: HPType.overline(p.muted)),
                                const SizedBox(height: HPSpace.sm),
                                Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
                                  StatusChip(label: '${s.data!['pending']} waiting', tone: (s.data!['pending'] as int) > 0 ? HPTone.saffron : HPTone.success),
                                  StatusChip(label: '${s.data!['failed']} failed', tone: (s.data!['failed'] as int) > 0 ? HPTone.danger : HPTone.neutral),
                                  StatusChip(label: '${s.data!['pushed']} synced', tone: HPTone.success),
                                ]),
                              ]),
                            ),
                          )
                        : const SkeletonBox(height: 80),
                  ),
                if ((ref.watch(sessionProvider)?.can('device.manage') ?? false) && ref.watch(setupProvider).valueOrNull?.hubConfig != null) ...[
                  const SizedBox(height: HPSpace.lg),
                  Card(
                    child: ListTile(
                      key: const Key('server-address'),
                      contentPadding: const EdgeInsets.symmetric(horizontal: HPSpace.lg, vertical: HPSpace.xs),
                      leading: const Icon(Icons.cloud_outlined),
                      title: Text('Server address', style: HPType.label(p.text)),
                      subtitle: Text(ref.watch(setupProvider).valueOrNull!.hubConfig!.cloudUrl, style: HPType.mono(p.muted)),
                      trailing: TextButton(onPressed: () => _changeServer(context), child: const Text('Change')),
                    ),
                  ),
                ],
                if (ref.watch(sessionProvider)?.can('device.manage') ?? false) ...[
                  const SizedBox(height: HPSpace.x2),
                  DangerButton(
                    label: 'Reset this device',
                    icon: Icons.restart_alt_rounded,
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => HPDialog(
                          title: 'Reset this device?',
                          actions: [
                            SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c)),
                            DangerButton(label: 'Reset', onPressed: () => Navigator.pop(c, true)),
                          ],
                          child: const Text('It forgets its hub pairing and must be set up again. Bills already on the hub are kept.'),
                        ),
                      );
                      if (ok != true || !context.mounted) return;
                      switchUser(context, ref);
                      await ref.read(setupProvider.notifier).reset();
                    },
                  ),
                ],
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// S3 Staff login: who is working (tiles with role colours) → PIN pad. A wrong PIN shakes the dots.
class StaffLoginScreen extends ConsumerStatefulWidget {
  const StaffLoginScreen({super.key});
  @override
  ConsumerState<StaffLoginScreen> createState() => _StaffLoginScreenState();
}

class _StaffLoginScreenState extends ConsumerState<StaffLoginScreen> with SingleTickerProviderStateMixin {
  Json? _user;
  String _pin = '';
  String? _error;
  bool _busy = false;
  late final AnimationController _shake;
  Future<List<Json>>? _staff;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final api = ref.read(hubApiProvider)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await api.login(_user!['id'] as String, _pin);
      final user = r['user'] as Map;
      HapticFeedback.lightImpact();
      ref.read(sessionProvider.notifier).state = StaffSession(
        userId: user['id'] as String,
        name: '${user['name']}'.split(' (').first,
        permissions: (r['permissions'] as List).cast<String>().toSet(),
        roles: ((user['roles'] as List?) ?? (_user!['roles'] as List? ?? const [])).map((e) => '$e').toList(),
      );
    } catch (e) {
      HapticFeedback.heavyImpact();
      _shake.forward(from: 0);
      if (mounted) {
        setState(() {
          _error = errText(e);
          _pin = '';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Someone without a PIN cannot use the pad: re-check (the hub pulls new PINs about every minute) and explain.
  Future<void> _pick(Json u) async {
    HapticFeedback.selectionClick();
    var user = u;
    if (u['hasPin'] == false) {
      final fresh = await ref.read(hubApiProvider)!.staff();
      user = fresh.firstWhere((x) => x['id'] == u['id'], orElse: () => u);
      if (mounted) {
        setState(() {
          _staff = Future.value(fresh);
        });
      }
      if (user['hasPin'] == false) {
        if (!mounted) return;
        final owner = (user['roles'] as List).contains('owner');
        await showDialog<void>(
          context: context,
          builder: (d) => HPDialog(
            title: '${'${user['name']}'.split(' (').first} has no PIN yet',
            actions: [PrimaryButton(label: 'OK', height: 56, onPressed: () => Navigator.pop(d))],
            child: Text(
              owner
                  ? 'Open the web console → Staff and tap "Set my PIN". This device gets it in about a minute; then tap your name again.'
                  : 'Ask the owner to set a PIN for you in the web console → Staff. This device gets it in about a minute.',
              key: const Key('no-pin-help'),
              style: HPType.body(context.hp.text),
            ),
          ),
        );
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _user = user;
      _pin = '';
      _error = null;
    });
  }

  void _key(String d) {
    if (_pin.length >= 8) return;
    setState(() {
      _pin += d;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(hubApiProvider)!;
    _staff ??= api.staff();
    // pull-down-to-refresh: new staff and new PINs from the hub
    ref.listen(refreshTickProvider, (_, _) => setState(() {
          _staff = api.staff();
        }));
    final p = context.hp;
    final narrow = isNarrow(context);
    return Scaffold(
      body: Column(children: [
        PosTopBar(title: _user == null ? 'Sign in' : 'Enter your PIN', showUser: false),
        Expanded(
          child: FutureBuilder<List<Json>>(
            future: _staff,
            builder: (c, s) {
              if (s.hasError) return ErrorState(message: errText(s.error!), onRetry: () => setState(() => _staff = api.staff()));
              if (!s.hasData) return const LoadingState(label: 'Loading staff…');
              return Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(narrow ? HPSpace.lg : HPSpace.x2),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: _user == null ? _pickUser(s.data!, p, narrow) : _pinPad(p),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }

  Widget _pickUser(List<Json> staff, HPPalette p, bool narrow) => Column(key: const ValueKey('pick'), children: [
        const BrandLogo(height: 72, maxWidth: 220),
        if (ref.watch(posLookProvider).valueOrNull case (:final name, :final brand) when brand != null && name.isNotEmpty) ...[
          const SizedBox(height: HPSpace.sm),
          Text(HPType.heading(name), key: const Key('brand-name'), style: HPType.titleCard(p.accentInk), textAlign: TextAlign.center),
        ],
        const SizedBox(height: HPSpace.md),
        Text(HPType.heading('Who is working?'), style: HPType.titleScreen(p.text), textAlign: TextAlign.center),
        const SizedBox(height: HPSpace.xs),
        Text('Tap your name, then enter your PIN', style: HPType.body(p.muted)),
        SizedBox(height: narrow ? HPSpace.lg : HPSpace.x2),
        if (staff.isEmpty) const EmptyState(title: 'No staff yet', message: 'The owner adds staff and PINs in the web console. They arrive here within a minute.', icon: Icons.badge_outlined),
        Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, alignment: WrapAlignment.center, children: [
          for (final u in staff)
            SizedBox(
              width: narrow ? 100 : 140,
              child: Material(
                color: p.surface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HPRadius.card), side: BorderSide(color: p.line)),
                child: InkWell(
                  key: Key('staff-${'${u['name']}'.split(' (').first}'),
                  borderRadius: BorderRadius.circular(HPRadius.card),
                  onTap: () => _pick(u),
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: narrow ? HPSpace.md : HPSpace.lg, horizontal: HPSpace.sm),
                    child: Column(children: [
                      _Avatar(name: '${u['name']}', role: (u['roles'] as List).isEmpty ? null : '${(u['roles'] as List).first}', radius: narrow ? 22 : 28),
                      const SizedBox(height: HPSpace.sm),
                      Text('${u['name']}'.split(' (').first, style: HPType.label(p.text), overflow: TextOverflow.ellipsis),
                      Text(roleLabel(u['roles'] as List), style: HPType.body(p.muted).copyWith(fontSize: 12), overflow: TextOverflow.ellipsis),
                      if (u['hasPin'] == false) Text('No PIN yet', style: HPType.body(p.danger).copyWith(fontSize: 12, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      ]);

  Widget _pinPad(HPPalette p) {
    final name = '${_user!['name']}'.split(' (').first;
    return SizedBox(
      key: const ValueKey('pin'),
      width: 340,
      child: Column(children: [
        _Avatar(name: name, role: (_user!['roles'] as List).isEmpty ? null : '${(_user!['roles'] as List).first}', radius: 34),
        const SizedBox(height: HPSpace.md),
        Text('Hello, $name', style: HPType.titleScreen(p.text).copyWith(fontSize: 26), textAlign: TextAlign.center),
        const SizedBox(height: HPSpace.lg),
        AnimatedBuilder(
          animation: _shake,
          builder: (c, child) => Transform.translate(offset: Offset(math.sin(_shake.value * math.pi * 6) * 10 * (1 - _shake.value), 0), child: child),
          child: Row(
            key: const Key('pin-dots'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < math.max(4, _pin.length); i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: i < _pin.length ? (_error != null ? p.danger : HPColors.saffron) : Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(color: _error != null ? p.danger : p.outline, width: 2),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(height: 32, child: Center(child: _error == null ? null : Text(_error!, style: HPType.body(p.danger)))),
        NumericKeypad(onKey: _key, onBackspace: () => setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1)), onClear: () => setState(() => _pin = '')),
        const SizedBox(height: HPSpace.lg),
        PrimaryButton(label: 'Sign in', busy: _busy, onPressed: _pin.length >= 4 ? _submit : null),
        TextButton(
          key: const Key('not-you'),
          // back to the names, refreshed: new staff and new PINs arrive from the hub
          onPressed: () => setState(() {
            _user = null;
            _staff = ref.read(hubApiProvider)!.staff();
          }),
          child: const Text('Not you?'),
        ),
      ]),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.role, this.radius = 28});
  final String name;
  final String? role;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final c = roleColor(context, role);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c, width: 2)),
      child: CircleAvatar(
        radius: radius,
        backgroundColor: c.withValues(alpha: .18),
        child: Text(name.characters.first.toUpperCase(), style: HPType.titleCard(context.hp.text).copyWith(fontSize: radius * .8)),
      ),
    );
  }
}
