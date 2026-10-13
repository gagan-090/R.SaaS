import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

const roleInfo = {
  'owner': ('Owner', Icons.workspace_premium_outlined, 'Everything, including approvals and corrections'),
  'cashier': ('Cashier', Icons.point_of_sale_rounded, 'Orders, bills, payments, tips'),
  'waiter': ('Waiter', Icons.room_service_outlined, 'Takes orders and sends them to the kitchen'),
  'chef': ('Chef', Icons.soup_kitchen_outlined, 'Kitchen display: start, ready, served'),
  'it_admin': ('IT admin', Icons.settings_suggest_outlined, 'Printers, devices, menu and staff setup'),
  'auditor': ('Auditor', Icons.fact_check_outlined, 'Read-only access to orders, bills and audit'),
};

/// O5 Staff: who works here, their role and a POS PIN. The hub gets changes on its next pull (about a minute).
class StaffScreen extends ConsumerStatefulWidget {
  const StaffScreen({super.key});
  @override
  ConsumerState<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends ConsumerState<StaffScreen> {
  List<Json>? _staff;
  List<String> _features = const [];
  Object? _error;
  bool _showDisabled = false;

  ApiClient get _api => ref.read(apiProvider);
  SignedIn? get _me => ref.read(authProvider) is SignedIn ? ref.read(authProvider) as SignedIn : null;
  bool get _canEdit => _me?.can('staff.manage') ?? false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([_api.staff(), _api.overview()]);
      if (!mounted) return;
      setState(() {
        _staff = (r[0] as List).cast<Json>();
        _features = (((r[1] as Json)['license'] as Json)['features'] as List).cast<String>();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  List<String> get _roles {
    final extended = _features.contains('roles.extended');
    final isOwner = _me?.roles.contains('owner') ?? false;
    return ['cashier', 'waiter', if (extended) 'chef', if (extended && isOwner) 'it_admin', if (extended) 'auditor'];
  }

  Future<void> _edit([Json? u]) async {
    final saved = await showDialog<String>(context: context, builder: (_) => _StaffEditor(api: _api, user: u, roles: _roles, extended: _features.contains('roles.extended')));
    if (saved != null) {
      await _load();
      if (mounted) showDone(context, saved);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return ErrorState(message: '$_error', onRetry: _load);
    if (_staff == null) return const Center(child: SizedBox(width: 600, child: Column(mainAxisSize: MainAxisSize.min, children: [SkeletonBox(height: 72), SizedBox(height: 12), SkeletonBox(height: 72), SizedBox(height: 12), SkeletonBox(height: 72)])));
    final p = context.hp;
    final active = _staff!.where((u) => u['status'] == 'active').toList();
    final disabled = _staff!.where((u) => u['status'] != 'active').toList();
    final byRole = <String, int>{};
    for (final u in active) {
      byRole['${u['role']}'] = (byRole['${u['role']}'] ?? 0) + 1;
    }
    return PageFrame(
      title: 'Staff',
      subtitle: '${active.length} people can sign in on the POS with their PIN',
      actions: [if (_canEdit) PrimaryButton(key: const Key('add-staff'), label: 'Add person', icon: Icons.person_add_alt_1_rounded, height: 48, onPressed: () => _edit())],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
          for (final e in byRole.entries) StatusChip(label: '${e.value} ${roleInfo[e.key]?.$1.toLowerCase() ?? e.key}${e.value == 1 ? '' : 's'}', icon: roleInfo[e.key]?.$2),
        ]),
        if (!_features.contains('roles.extended'))
          Padding(
            padding: const EdgeInsets.only(top: HPSpace.md),
            child: Text('Chef, IT admin and auditor roles come with the Premium plan.', style: HPType.body(p.muted)),
          ),
        const SizedBox(height: HPSpace.lg),
        Card(
          child: Column(children: [
            for (final (i, u) in active.indexed) ...[
              if (i > 0) const Divider(indent: 72),
              _StaffRow(user: u, onTap: _canEdit && u['role'] != 'owner' ? () => _edit(u) : null),
            ],
          ]),
        ),
        if (disabled.isNotEmpty) ...[
          const SizedBox(height: HPSpace.lg),
          TextButton.icon(
            onPressed: () => setState(() => _showDisabled = !_showDisabled),
            icon: Icon(_showDisabled ? Icons.expand_less_rounded : Icons.expand_more_rounded),
            label: Text('${disabled.length} turned off'),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: !_showDisabled
                ? const SizedBox(width: double.infinity)
                : Card(child: Column(children: [for (final u in disabled) _StaffRow(user: u, onTap: _canEdit ? () => _edit(u) : null)])),
          ),
        ],
      ]),
    );
  }
}

class _StaffRow extends StatelessWidget {
  const _StaffRow({required this.user, this.onTap});
  final Json user;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final info = roleInfo['${user['role']}'];
    final off = user['status'] != 'active';
    return ListTile(
      key: Key('staff-${user['name']}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: HPSpace.lg, vertical: HPSpace.xs),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: off ? p.raised : HPColors.saffron.withValues(alpha: .2),
        child: Text('${user['name']}'.characters.first.toUpperCase(), style: HPType.titleCard(off ? p.faint : p.accentInk).copyWith(fontSize: 18)),
      ),
      title: Text('${user['name']}', style: HPType.label(off ? p.faint : p.text)),
      subtitle: Text(
        [info?.$1 ?? '${user['role']}', if (user['email'] != null) '${user['email']}', if (user['canDiscount'] == true) 'can give discounts'].join(' · '),
        style: HPType.body(p.muted),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (off) const StatusChip(label: 'Off', tone: HPTone.danger) else if (user['hasPin'] == true) const StatusChip(label: 'PIN set', tone: HPTone.success) else const StatusChip(label: 'No PIN', tone: HPTone.saffron),
        if (onTap != null) const Icon(Icons.chevron_right_rounded),
      ]),
      onTap: onTap,
    );
  }
}

class _StaffEditor extends StatefulWidget {
  const _StaffEditor({required this.api, required this.user, required this.roles, required this.extended});
  final ApiClient api;
  final Json? user;
  final List<String> roles;
  final bool extended;
  @override
  State<_StaffEditor> createState() => _StaffEditorState();
}

class _StaffEditorState extends State<_StaffEditor> {
  late final _name = TextEditingController(text: widget.user?['name'] as String? ?? '');
  final _pin = TextEditingController(), _email = TextEditingController(), _password = TextEditingController();
  late final _phone = TextEditingController(text: widget.user?['phone'] as String? ?? '');
  late String _role = widget.user?['role'] as String? ?? 'waiter';
  late bool _canDiscount = widget.user?['canDiscount'] as bool? ?? false;
  bool _consoleLogin = false, _busy = false;
  String? _error;

  bool get _isNew => widget.user == null;

  Future<void> _save({String? status}) async {
    final pin = _pin.text.trim();
    if (_name.text.trim().isEmpty) return setState(() => _error = 'Enter a name');
    if ((_isNew || pin.isNotEmpty) && !RegExp(r'^\d{4,8}$').hasMatch(pin)) return setState(() => _error = 'PIN must be 4–8 digits');
    if (_consoleLogin && (!_email.text.contains('@') || _password.text.length < 8)) return setState(() => _error = 'Console sign-in needs an email and a password of 8+ characters');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_isNew) {
        await widget.api.createStaff({
          'name': _name.text.trim(), 'role': _role, 'pin': pin, 'canDiscount': _role == 'cashier' && _canDiscount,
          if (_phone.text.trim().isNotEmpty) 'phone': _phone.text.trim(),
          if (_consoleLogin) 'email': _email.text.trim(),
          if (_consoleLogin) 'password': _password.text,
        });
      } else {
        await widget.api.updateStaff(widget.user!['id'] as String, {
          'name': _name.text.trim(), 'role': _role, 'canDiscount': _role == 'cashier' && _canDiscount, 'phone': _phone.text.trim().isEmpty ? null : _phone.text.trim(),
          if (pin.isNotEmpty) 'pin': pin,
          'status': ?status,
        });
      }
      if (mounted) {
        Navigator.pop(context, _isNew ? '${_name.text.trim()} added — they can sign in on the POS in about a minute' : (status == 'disabled' ? '${_name.text.trim()} turned off' : status == 'active' ? '${_name.text.trim()} turned on' : 'Saved'));
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final off = widget.user?['status'] == 'disabled';
    final roles = {...widget.roles, if (!_isNew) _role}.toList();
    return HPDialog(
      title: _isNew ? 'Add a person' : 'Edit ${widget.user!['name']}',
      actions: [
        if (!_isNew)
          off
              ? SecondaryButton(label: 'Turn on', onPressed: _busy ? null : () => _save(status: 'active'))
              : DangerButton(label: 'Turn off', onPressed: _busy ? null : () => _save(status: 'disabled')),
        SecondaryButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        PrimaryButton(key: const Key('save-staff'), label: 'Save', busy: _busy, height: 56, onPressed: () => _save()),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(key: const Key('staff-name'), controller: _name, autofocus: _isNew, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Name')),
        const SizedBox(height: HPSpace.lg),
        Text('ROLE', style: HPType.overline(p.muted)),
        const SizedBox(height: HPSpace.sm),
        RadioGroup<String>(
          groupValue: _role,
          onChanged: (v) => setState(() => _role = v!),
          child: Column(children: [
            for (final r in roles)
              RadioListTile<String>(
                key: Key('role-$r'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: r,
                secondary: Icon(roleInfo[r]?.$2),
                title: Text(roleInfo[r]?.$1 ?? r, style: HPType.label(p.text)),
                subtitle: Text(roleInfo[r]?.$3 ?? '', style: HPType.body(p.muted).copyWith(fontSize: 12)),
              ),
          ]),
        ),
        if (_role == 'cashier')
          SwitchListTile(contentPadding: EdgeInsets.zero, value: _canDiscount, onChanged: (v) => setState(() => _canDiscount = v), title: const Text('Can give discounts'), subtitle: const Text('Above 10% still needs a reason')),
        const SizedBox(height: HPSpace.sm),
        TextField(
          key: const Key('staff-pin'),
          controller: _pin,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 8,
          decoration: InputDecoration(labelText: _isNew ? 'POS PIN (4–8 digits)' : 'New PIN (leave empty to keep)', counterText: '', prefixIcon: const Icon(Icons.pin_outlined)),
        ),
        const SizedBox(height: HPSpace.md),
        TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone (optional)')),
        if (_isNew && (_role == 'it_admin' || _role == 'auditor')) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _consoleLogin,
            onChanged: (v) => setState(() => _consoleLogin = v),
            title: const Text('Can sign in to this web console'),
          ),
          if (_consoleLogin) ...[
            TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
            const SizedBox(height: HPSpace.md),
            TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password (8+ characters)')),
          ],
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: HPSpace.sm), child: Text(_error!, key: const Key('staff-error'), style: HPType.body(p.danger))),
      ]),
    );
  }
}
