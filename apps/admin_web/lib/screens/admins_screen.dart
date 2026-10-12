import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../state/providers.dart';
import '../widgets/common.dart';

/// P9 Platform admins (invite, roles, deactivate) and P10 MFA reset with step-up.
class AdminsScreen extends ConsumerStatefulWidget {
  const AdminsScreen({super.key});
  @override
  ConsumerState<AdminsScreen> createState() => _AdminsScreenState();
}

class _AdminsScreenState extends ConsumerState<AdminsScreen> {
  late Future<(List<dynamic>, List<dynamic>)> Function() _load = _mk();
  Future<(List<dynamic>, List<dynamic>)> Function() _mk() {
    final api = ref.read(apiProvider);
    return () async => (await api.admins(), await api.roles());
  }

  void _reload() => setState(() => _load = _mk());

  Future<List<String>?> _pickRoles(List<dynamic> roles, Set<String> selected, String title) => showDialog<List<String>>(
        context: context,
        builder: (c) => StatefulBuilder(
          builder: (c, set) => HPDialog(title: title, actions: [
            SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c)),
            PrimaryButton(label: 'Save', height: 56, onPressed: selected.isEmpty ? null : () => Navigator.pop(c, selected.toList())),
          ], child: Column(children: [
            for (final r in roles.cast<Map<String, dynamic>>())
              CheckboxListTile(
                value: selected.contains(r['id']),
                title: Text('${r['name']}'),
                subtitle: Text('${r['description'] ?? ''}\n${(r['permissions'] as List).join(', ')}', style: HPType.body(HPColors.inkMuted).copyWith(fontSize: 12)),
                isThreeLine: true,
                onChanged: (v) => set(() => v! ? selected.add(r['id'] as String) : selected.remove(r['id'])),
              ),
          ])),
        ),
      );

  Future<void> _invite(List<dynamic> roles) async {
    final email = TextEditingController(), name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => HPDialog(title: 'Invite platform admin', actions: [
        SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c)),
        PrimaryButton(label: 'Next: roles', height: 56, onPressed: () => Navigator.pop(c, true)),
      ], child: Column(children: [
        TextField(controller: email, decoration: const InputDecoration(labelText: 'Email')),
        const SizedBox(height: HPSpace.md),
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
      ])),
    );
    if (ok != true || !mounted) return;
    final picked = await _pickRoles(roles, {}, 'Roles for ${email.text.trim()}');
    if (picked == null || !mounted) return;
    try {
      await ref.read(apiProvider).invite(email.text.trim(), name.text.trim(), picked);
      if (mounted) showDone(context, 'Invite sent to ${email.text.trim()}');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// P10: warning → reason → step-up (own password + TOTP) → reset; the server audits and notifies.
  Future<void> _resetMfa(Map<String, dynamic> a) async {
    final reason = await ReasonDialog.show(context,
        title: 'Reset MFA for ${a['name']}',
        confirmLabel: 'Continue',
        message: '${a['email']} will be signed out everywhere and must enrol a new authenticator at next sign-in. They will be notified. Only do this after verifying their identity.');
    if (reason == null || !mounted) return;
    final step = await askStepUp(context);
    if (step == null || !mounted) return;
    final api = ref.read(apiProvider);
    try {
      final token = await api.stepUp(step.$1, step.$2);
      final r = await api.resetMfa(a['id'] as String, reason, token);
      if (mounted) showDone(context, 'MFA reset — notification sent to ${r['notified']}');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    bool can(String p) => auth is SignedIn && auth.can(p);
    final myId = auth is SignedIn ? auth.me['id'] : null;
    return AsyncView<(List<dynamic>, List<dynamic>)>(
      load: _load,
      builder: (c, d, _) {
        final (admins, roles) = d;
        return ListView(padding: const EdgeInsets.all(HPSpace.x4), children: [
          Row(children: [
            Expanded(child: Text('Platform admins', style: Theme.of(c).textTheme.headlineMedium)),
            if (can('platform.admin.invite')) SizedBox(width: 200, child: PrimaryButton(label: 'Invite admin', icon: Icons.person_add_alt, height: 52, onPressed: () => _invite(roles))),
          ]),
          const SizedBox(height: HPSpace.x2),
          Card(
            child: Column(children: [
              for (final a in admins.cast<Map<String, dynamic>>())
                ListTile(
                  key: Key('admin-${a['email']}'),
                  title: Text('${a['name']}  ·  ${a['email']}', style: HPType.label(HPColors.ink)),
                  subtitle: Text((a['roles'] as List).map((r) => r['name']).join(', ')),
                  trailing: Wrap(spacing: HPSpace.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    StatusChip(label: '${a['status']}', tone: toneForStatus(a['status'] as String?)),
                    StatusChip(label: a['mfaEnrolled'] == true ? 'MFA on' : 'MFA not set', tone: a['mfaEnrolled'] == true ? HPTone.success : HPTone.saffron),
                    if (a['id'] != myId)
                      PopupMenuButton<String>(
                        tooltip: 'Actions',
                        onSelected: (v) async {
                          if (v == 'roles') {
                            final picked = await _pickRoles(roles, {for (final r in a['roles'] as List) r['id'] as String}, 'Roles for ${a['name']}');
                            if (picked == null || !context.mounted) return;
                            try {
                              await ref.read(apiProvider).setRoles(a['id'] as String, picked);
                              _reload();
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          } else if (v == 'mfa') {
                            await _resetMfa(a);
                          } else if (v == 'deactivate') {
                            final reason = await ReasonDialog.show(context, title: 'Deactivate ${a['name']}', confirmLabel: 'Deactivate');
                            if (reason == null || !context.mounted) return;
                            try {
                              await ref.read(apiProvider).deactivate(a['id'] as String, reason);
                              _reload();
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          if (can('platform.admin.roles')) const PopupMenuItem(value: 'roles', child: Text('Edit roles')),
                          if (can('platform.mfa.reset') && a['mfaEnrolled'] == true) const PopupMenuItem(value: 'mfa', child: Text('Reset MFA…')),
                          if (can('platform.admin.deactivate') && a['status'] == 'active') const PopupMenuItem(value: 'deactivate', child: Text('Deactivate…')),
                        ],
                      ),
                  ]),
                ),
            ]),
          ),
        ]);
      },
    );
  }
}
