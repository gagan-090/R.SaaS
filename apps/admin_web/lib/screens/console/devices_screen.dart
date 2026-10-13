import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/labels.dart';

String ago(Object? iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  if (d == null) return 'never';
  final m = DateTime.now().difference(d).inMinutes;
  if (m < 1) return 'just now';
  if (m < 60) return '$m min ago';
  if (m < 60 * 24) return '${m ~/ 60} h ago';
  return shortDate(iso);
}

/// T1 Hubs & devices: the branch hub (the cashier device that keeps working offline) and every paired terminal.
/// A hub is added from the POS app itself ("This device is the hub"); this page shows how, and lets you revoke.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});
  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  int _reload = 0;

  @override
  Widget build(BuildContext context) {
    final api = ref.read(apiProvider);
    final me = ref.watch(authProvider);
    final email = me is SignedIn ? '${me.me['email'] ?? ''}' : '';
    return AsyncView<List<dynamic>>(
      key: ValueKey(_reload),
      load: api.devices,
      builder: (c, data, reload) {
        final devices = data.cast<Json>();
        final active = devices.where((d) => d['revokedAt'] == null).toList();
        final revoked = devices.where((d) => d['revokedAt'] != null).toList();
        final hub = active.where((d) => d['isHub'] == true).firstOrNull;
        final howTo = _HowTo(apiUrl: api.baseUrl, email: email, hasHub: hub != null);
        return PageFrame(
          title: 'Hubs & devices',
          subtitle: hub == null ? 'No hub yet — set one up below' : 'Hub: ${hub['name']} · ${hub['online'] == true ? 'online' : 'last seen ${ago(hub['lastSeenAt'])}'}',
          actions: [IconButton(tooltip: 'Refresh', onPressed: () => setState(() => _reload++), icon: const Icon(Icons.refresh_rounded))],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // with a hub in place the device list comes first; a new restaurant sees the setup steps first
            if (hub == null) ...[howTo, const SizedBox(height: HPSpace.lg)],
            if (active.isNotEmpty)
              Card(
                child: Column(children: [
                  for (final (i, d) in active.indexed) ...[
                    if (i > 0) const Divider(indent: 72),
                    _DeviceRow(
                      device: d,
                      onRevoke: () async {
                        final reason = await ReasonDialog.show(context,
                            title: 'Revoke ${d['name']}?', confirmLabel: 'Revoke', message: 'It stops syncing immediately. To use it again, set it up from the POS app.');
                        if (reason == null) return;
                        try {
                          await api.revokeDevice(d['id'] as String, reason);
                          if (context.mounted) showDone(context, '${d['name']} revoked');
                          setState(() => _reload++);
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                    ),
                  ],
                ]),
              ),
            if (hub != null) ...[const SizedBox(height: HPSpace.lg), howTo],
            if (revoked.isNotEmpty) ...[
              const SizedBox(height: HPSpace.lg),
              SectionHeader('Revoked · ${revoked.length}'),
              Card(child: Column(children: [for (final d in revoked) _DeviceRow(device: d)])),
            ],
          ]),
        );
      },
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, this.onRevoke});
  final Json device;
  final VoidCallback? onRevoke;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final revoked = device['revokedAt'] != null;
    final online = device['online'] == true;
    return ListTile(
      key: Key('device-${device['name']}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: HPSpace.lg, vertical: HPSpace.xs),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(12)),
        child: Icon(device['isHub'] == true ? Icons.router_rounded : (device['platform'] == 'windows' ? Icons.desktop_windows_outlined : Icons.phone_android_rounded), color: revoked ? p.faint : p.text),
      ),
      title: Wrap(spacing: HPSpace.sm, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('${device['name']}', style: HPType.label(revoked ? p.faint : p.text), overflow: TextOverflow.ellipsis),
        if (device['isHub'] == true) const StatusChip(label: 'Hub', tone: HPTone.saffron),
        if (!revoked) StatusChip(label: online ? 'Online' : 'Offline', tone: online ? HPTone.success : HPTone.neutral),
      ]),
      subtitle: Text(
        revoked ? 'Revoked ${shortDate(device['revokedAt'])}' : '${titleCase('${device['platform']}')} · ${(device['branch'] as Map?)?['name'] ?? ''} · paired ${shortDate(device['pairedAt'])} · seen ${ago(device['lastSeenAt'])}',
        style: HPType.body(p.muted),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: revoked || onRevoke == null ? null : IconButton(tooltip: 'Revoke', icon: const Icon(Icons.link_off_rounded), onPressed: onRevoke),
    );
  }
}

class _HowTo extends StatelessWidget {
  const _HowTo({required this.apiUrl, required this.email, required this.hasHub});
  final String apiUrl, email;
  final bool hasHub;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    Widget step(int n, String title, Widget body) => Padding(
          padding: const EdgeInsets.only(bottom: HPSpace.lg),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(radius: 14, backgroundColor: HPColors.saffron, child: Text('$n', style: HPType.label(HPColors.onSaffron).copyWith(fontSize: 13))),
            const SizedBox(width: HPSpace.md),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: HPType.label(p.text)), const SizedBox(height: 4), body])),
          ]),
        );
    return SectionCard(
      title: hasHub ? 'Add another terminal or replace the hub' : 'Set up your hub',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
          'The hub is the main cashier device (Windows PC or Android). It keeps billing running when the internet drops and syncs to the cloud when it is back. Other phones and tablets pair with it over Wi-Fi.',
          style: HPType.body(p.muted),
        ),
        const SizedBox(height: HPSpace.lg),
        step(1, 'Install House Plating POS on the cashier device', Text('Android: install the APK. Windows: run the installer.', style: HPType.body(p.muted))),
        step(
          2,
          'Open it and choose "This device is the hub"',
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Enter this server address:', style: HPType.body(p.muted)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.fromLTRB(HPSpace.md, 4, 4, 4),
              decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Expanded(child: SelectableText(apiUrl, key: const Key('hub-api-url'), style: HPType.mono(p.text))),
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: apiUrl));
                    if (context.mounted) showDone(context, 'Address copied');
                  },
                ),
              ]),
            ),
          ]),
        ),
        step(3, 'Sign in as the owner or IT admin', Text(email.isEmpty ? 'Use your console email and password.' : 'For example $email and your console password.', style: HPType.body(p.muted))),
        step(4, 'Staff sign in with their PIN', Text('Menu, tables and staff arrive automatically. Pair more devices from the hub: Menu → Hub & devices → scan the code.', style: HPType.body(p.muted))),
      ]),
    );
  }
}
