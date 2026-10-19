import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../api/api_client.dart';
import '../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/labels.dart';

/// P9 Platform admins (direct creation, pending invite activation, roles, deactivate) and P10 MFA reset.
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

  Timer? _statusTimer;
  @override
  void initState() { super.initState(); _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) { if (mounted) _reload(); }); }
  @override
  void dispose() { _statusTimer?.cancel(); super.dispose(); }

  void _reload() => setState(() => _load = _mk());

  Future<List<String>?> _pickRoles(List<dynamic> roles, Set<String> selected, String title) => showDialog<List<String>>(
        barrierDismissible: false,
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
                subtitle: Text(
                  [if ('${r['description'] ?? ''}'.isNotEmpty) '${r['description']}', 'Can: ${(r['permissions'] as List).map(permissionLabel).join(' · ')}'].join('\n'),
                  style: HPType.body(context.hp.muted).copyWith(fontSize: 12),
                ),
                isThreeLine: true,
                onChanged: (v) => set(() => v! ? selected.add(r['id'] as String) : selected.remove(r['id'])),
              ),
          ])),
        ),
      );

  Future<void> _add([Json? pending]) async {
    final ok = await showDialog<bool>(barrierDismissible: false, context: context, builder: (_) => _AdminCredentialsDialog(api: ref.read(apiProvider), pending: pending));
    if (ok != true || !mounted) return;
    _reload();
    showDone(context, 'Admin ${pending == null ? 'created' : 'activated'} — sign in with email and password');
  }

  /// P10: warning → reason → step-up (own password + TOTP) → reset; the server audits and notifies.
  Future<void> _setMfa(Json admin) async {
    final enabled = admin['mfaEnabled'] == false;
    final me = ref.read(authProvider) as SignedIn;
    final reason = await ReasonDialog.show(context, title: '${enabled ? 'Turn on' : 'Turn off'} MFA for ${admin['name']}?', confirmLabel: 'Continue',
      message: enabled ? 'This account will need an authenticator at sign-in. If one is already set up, it will be used. Existing sessions will end.' : 'This account will sign in with email and password without an authenticator code. Existing sessions will end.');
    if (reason == null || !mounted) return;
    final step = await askStepUp(context, mfaRequired: me.me['mfaEnabled'] != false);
    if (step == null || !mounted) return;
    try {
      final api = ref.read(apiProvider);
      final token = await api.stepUp(step.$1, step.$2);
      await api.setAdminMfa(admin['id'] as String, enabled, reason, token);
      if (admin['id'] == me.me['id']) {
        await ref.read(authProvider.notifier).logout();
      } else {
        _reload();
        if (mounted) showDone(context, 'MFA ${enabled ? 'on' : 'off'} for ${admin['name']} — they must sign in again');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Reset an authenticator with identity verification.
  Future<void> _resetMfa(Map<String, dynamic> a) async {
    final reason = await ReasonDialog.show(context,
        title: 'Reset MFA for ${a['name']}',
        confirmLabel: 'Continue',
        message: '${a['email']} will be signed out everywhere and must enrol a new authenticator at next sign-in. They will be notified. Only do this after verifying their identity.');
    if (reason == null || !mounted) return;
    final me = ref.read(authProvider) as SignedIn;
    final step = await askStepUp(context, mfaRequired: me.me['mfaEnabled'] != false);
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
    final isSuperAdmin = auth is SignedIn && auth.roles.contains('Super Admin');
    return AsyncView<(List<dynamic>, List<dynamic>)>(
      load: _load,
      builder: (c, d, _) {
        final (admins, roles) = d;
        return ListView(padding: EdgeInsets.all(isNarrowWeb(c) ? HPSpace.lg : HPSpace.x4), children: [
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, runSpacing: HPSpace.md, children: [
            Text('Platform admins', style: Theme.of(c).textTheme.headlineMedium),
            // actions grouped on the right: refresh sits beside Add admin instead of floating mid-header
            Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(width: 140, child: SecondaryButton(key: const Key('refresh-admins'), label: 'Refresh', icon: Icons.refresh_rounded, height: 52, onPressed: _reload)),
              if (can('platform.admin.invite')) SizedBox(width: 200, child: PrimaryButton(key: const Key('add-platform-admin'), label: 'Add admin', icon: Icons.person_add_alt, height: 52, onPressed: _add)),
            ]),
          ]),
          const SizedBox(height: HPSpace.md),
          Text('Add an admin with a name, email and password. For an Invited account, open its Actions menu and choose Set password & activate.', style: HPType.body(c.hp.muted)),
          const SizedBox(height: HPSpace.x2),
          Card(
            child: Column(children: [
              for (final a in admins.cast<Map<String, dynamic>>())
                ListTile(
                  key: Key('admin-${a['email']}'),
                  title: Text('${a['name']}', style: HPType.label(context.hp.text)),
                  isThreeLine: true,
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${a['email']} · ${(a['roles'] as List).map((r) => r['name']).join(', ')}', overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 6),
                    Wrap(spacing: HPSpace.sm, runSpacing: 4, children: [
                      StatusChip(label: titleCase('${a['status']}'), tone: toneForStatus(a['status'] as String?)),
                      StatusChip(label: a['mfaEnabled'] == false ? 'MFA off' : a['mfaEnrolled'] == true ? 'MFA on' : 'MFA on · Setup needed', tone: a['mfaEnabled'] != false && a['mfaEnrolled'] == true ? HPTone.success : HPTone.saffron),
                    ]),
                  ]),
                  trailing: Wrap(spacing: HPSpace.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    if (a['id'] != myId || isSuperAdmin)
                      PopupMenuButton<String>(
                        tooltip: 'Actions',
                        onSelected: (v) async {
                          if (v == 'mfa-policy') {
                            await _setMfa(a);
                          } else if (v == 'activate') {
                            await _add(a);
                          } else if (v == 'roles') {
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
                          } else if (v == 'delete') {
                            final reason = await ReasonDialog.show(
                              context,
                              title: 'Remove admin ${a['name']}?',
                              confirmLabel: 'Remove admin',
                              message: 'This platform admin will be removed from the platform and their active sessions revoked. A full audit log is recorded.',
                              destructive: true,
                            );
                            if (reason == null || !context.mounted) return;
                            try {
                              await ref.read(apiProvider).deleteAdmin(a['id'] as String, reason);
                              _reload();
                              if (context.mounted) showDone(context, 'Admin ${a['name']} removed');
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          if (isSuperAdmin) PopupMenuItem(value: 'mfa-policy', child: Text(a['mfaEnabled'] == false ? 'Turn MFA on' : 'Turn MFA off')),
                          if (can('platform.admin.invite') && a['status'] == 'invited') const PopupMenuItem(value: 'activate', child: Text('Set password & activate')),
                          if (a['id'] != myId && can('platform.admin.roles')) const PopupMenuItem(value: 'roles', child: Text('Edit roles')),
                          if (a['id'] != myId && can('platform.mfa.reset') && a['mfaEnrolled'] == true) const PopupMenuItem(value: 'mfa', child: Text('Reset MFA…')),
                          if (a['id'] != myId && can('platform.admin.deactivate') && a['status'] == 'active') const PopupMenuItem(value: 'deactivate', child: Text('Deactivate…')),
                          if (a['id'] != myId && (can('platform.admin.deactivate') || isSuperAdmin) && a['status'] != 'deleted')
                            PopupMenuItem(value: 'delete', child: Text('Remove admin (Delete)…', style: TextStyle(color: context.hp.danger))),
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

class _AdminCredentialsDialog extends StatefulWidget {
  const _AdminCredentialsDialog({required this.api, this.pending});
  final ApiClient api;
  final Json? pending;
  @override
  State<_AdminCredentialsDialog> createState() => _AdminCredentialsDialogState();
}

class _AdminCredentialsDialogState extends State<_AdminCredentialsDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.pending?['name'] as String? ?? '');
  late final _email = TextEditingController(text: widget.pending?['email'] as String? ?? '');
  final _password = TextEditingController();
  bool _busy = false, _showPassword = false;
  String? _error;
  bool get _activating => widget.pending != null;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() { _busy = true; _error = null; });
    try {
      if (_activating) {
        await widget.api.activateAdmin(widget.pending!['id'] as String, _password.text);
      } else {
        await widget.api.createAdmin(_email.text.trim(), _name.text.trim(), _password.text);
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Cannot reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => HPDialog(
    title: _activating ? 'Activate platform admin' : 'Add platform admin',
    actions: [
      SecondaryButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
      PrimaryButton(key: const Key('save-platform-admin'), label: _activating ? 'Activate admin' : 'Create admin', height: 56, busy: _busy, onPressed: _save),
    ],
    child: Form(key: _form, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(_activating
          ? 'Set a password to activate this existing account. Its assigned roles are kept.'
          : 'The account is active immediately with the Onboarding Admin role. You can change roles from its Actions menu.', style: HPType.body(context.hp.muted)),
      const SizedBox(height: HPSpace.lg),
      TextFormField(key: const Key('new-admin-name'), controller: _name, readOnly: _activating, enabled: !_busy,
        decoration: const InputDecoration(labelText: 'Name'), maxLength: 120,
        validator: (v) => v == null || v.trim().isEmpty ? 'Enter the admin’s name' : null),
      const SizedBox(height: HPSpace.md),
      TextFormField(key: const Key('new-admin-email'), controller: _email, readOnly: _activating, enabled: !_busy, keyboardType: TextInputType.emailAddress,
        decoration: const InputDecoration(labelText: 'Email'),
        validator: (v) => v == null || !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim()) ? 'Enter a valid email' : null),
      const SizedBox(height: HPSpace.md),
      TextFormField(key: const Key('new-admin-password'), controller: _password, enabled: !_busy, obscureText: !_showPassword, maxLength: 256,
        decoration: InputDecoration(labelText: 'Password', helperText: 'At least 12 characters', suffixIcon: IconButton(tooltip: _showPassword ? 'Hide password' : 'Show password', icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined), onPressed: () => setState(() => _showPassword = !_showPassword))),
        validator: (v) => v == null || v.length < 12 ? 'Use at least 12 characters' : null,
        onFieldSubmitted: (_) => _save()),
      const SizedBox(height: HPSpace.md),
      Text('Share the password with the admin securely. When MFA is on, their first sign-in includes authenticator setup.', style: HPType.body(context.hp.muted)),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: HPSpace.md), child: Text(_error!, key: const Key('admin-create-error'), style: HPType.body(context.hp.danger))),
    ])),
  );
}
