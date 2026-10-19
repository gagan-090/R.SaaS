import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../util/pin_policy.dart';

const roleInfo = {
  'owner': ('Owner', Icons.workspace_premium_outlined, 'Everything, including approvals and corrections'),
  'it_admin': ('Restaurant admin', Icons.settings_suggest_outlined, 'Employees, menu, layout, inventory, devices and reports'),
  'cashier': ('Cashier', Icons.point_of_sale_rounded, 'Orders, bills, payments, tips'),
  'waiter': ('Waiter', Icons.room_service_outlined, 'Takes orders and sends them to the kitchen'),
  'chef': ('Chef', Icons.soup_kitchen_outlined, 'Kitchen orders, stock, consumption, wastage, replenishment'),
  'auditor': ('Auditor', Icons.fact_check_outlined, 'Read-only access to records, reports and logs'),
  'custom': ('Custom role', Icons.tune_rounded, 'Exactly the permissions you chose for it'),
};

String roleLabel(Json u) => u['role'] == 'custom' ? '${u['customRoleName'] ?? 'Custom role'}' : (roleInfo['${u['role']}']?.$1 ?? '${u['role']}');

/// O5 Staff: who works here, their role, PIN and web portal access. The hub gets changes on its next pull (about a minute).
class StaffScreen extends ConsumerStatefulWidget {
  const StaffScreen({super.key});
  @override
  ConsumerState<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends ConsumerState<StaffScreen> {
  List<Json>? _staff;
  Json? _limits;
  List<Json> _customRoles = const [];
  Object? _error;
  bool _showDisabled = false;

  ApiClient get _api => ref.read(apiProvider);
  SignedIn? get _me => ref.read(authProvider) is SignedIn ? ref.read(authProvider) as SignedIn : null;
  bool get _canEdit => _me?.can('staff.manage') ?? false;
  bool get _isOwner => _me?.roles.contains('owner') ?? false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([_api.staff(), _api.staffLimits(), _api.restaurantRoles()]);
      if (!mounted) return;
      setState(() {
        _staff = (r[0] as List).cast<Json>();
        _limits = r[1] as Json;
        _customRoles = (((r[2] as Json)['custom'] as List?) ?? const []).cast<Json>();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Roles this person may hand out (the server checks again): admins never create admins.
  List<String> get _roles {
    final extended = _limits?['extendedRoles'] == true;
    return [
      'cashier', 'waiter',
      if (extended) 'chef',
      if (extended && _isOwner) 'it_admin',
      if (extended) 'auditor',
      if (_limits?['customRoles'] == true && _customRoles.isNotEmpty) 'custom',
    ];
  }

  Future<void> _edit([Json? u]) async {
    final saved = await showDialog<String>(
      barrierDismissible: false,
      context: context,
      builder: (_) => _StaffEditor(api: _api, user: u, roles: _roles, customRoles: _customRoles, limits: _limits!),
    );
    if (saved != null) {
      await _load();
      if (mounted) showDone(context, saved);
    }
  }

  Future<void> _setMyPin() async {
    final ok = await showDialog<bool>(barrierDismissible: false, context: context, builder: (_) => _MyPinDialog(api: _api));
    if (ok == true) {
      await _load();
      if (mounted) showDone(context, 'PIN saved — use it on the POS in about a minute');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return loadErrorView(_error!, page: 'Staff', onRetry: _load);
    if (_staff == null) return const Center(child: SizedBox(width: 600, child: Column(mainAxisSize: MainAxisSize.min, children: [SkeletonBox(height: 72), SizedBox(height: 12), SkeletonBox(height: 72)])));
    final p = context.hp;
    final active = _staff!.where((u) => u['status'] == 'active').toList();
    final disabled = _staff!.where((u) => u['status'] != 'active').toList();
    final byRole = <String, int>{};
    for (final u in active) {
      final k = roleLabel(u);
      byRole[k] = (byRole[k] ?? 0) + 1;
    }
    final myId = _me?.me['id'];
    final mine = active.where((u) => u['id'] == myId).firstOrNull;
    final limit = _limits?['employeeLimit'] as int?;
    final used = _limits?['activeEmployees'] as int? ?? 0;
    final full = limit != null && used >= limit;
    final noPlan = _limits?['planActive'] == false;
    return PageFrame(
      title: 'Staff',
      subtitle: '${active.length} ${active.length == 1 ? 'person' : 'people'} on the team${limit != null ? ' · $used of $limit employees in your plan' : ''}',
      actions: [
        if (_canEdit) PrimaryButton(key: const Key('add-staff'), label: 'Add person', icon: Icons.person_add_alt_1_rounded, height: 48, onPressed: full || noPlan ? null : () => _edit()),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
          for (final e in byRole.entries) StatusChip(label: '${e.value} · ${e.key}'),
        ]),
        if (noPlan && _canEdit)
          _Notice(key: const Key('staff-no-plan'), icon: Icons.lock_outline_rounded, title: 'No active plan',
              text: 'People cannot be added or changed until your restaurant has an active plan. ${_isOwner ? 'Ask House Plating to issue or renew your plan' : 'Ask the owner to renew the plan'}.'),
        if (full && !noPlan && _canEdit)
          _Notice(key: const Key('limit-reached'), icon: Icons.group_off_outlined, title: 'Employee limit reached',
              text: 'Your plan allows $limit active employees. Turn someone off, or ${_isOwner ? 'ask House Plating for a bigger plan' : 'ask the owner about a bigger plan'}.'),
        if (_limits?['staffPortal'] != true)
          _Notice(icon: Icons.lock_outline_rounded, title: 'Employee web portal is not in your plan',
              text: 'Employees can use the POS with their PIN. For email + PIN web sign-in, ${_isOwner ? 'ask the Super Admin to enable "Staff web portal (email + PIN)" in Plans, then sign in again' : 'ask the owner to enable a plan with the staff web portal'}.'),
        if (_limits?['staffPortal'] == true && _canEdit)
          _Notice(key: const Key('staff-portal-ready'), icon: Icons.login_rounded, title: 'Employee web sign-in',
              text: 'Add an email and turn on web access for each employee. They use that email and their PIN to sign in to their role’s web portal.',
              action: SecondaryButton(key: const Key('copy-staff-login'), label: 'Copy sign-in link', icon: Icons.copy_rounded, onPressed: () async {
                await Clipboard.setData(ClipboardData(text: Uri.base.replace(query: '', fragment: '/login?mode=employee').toString()));
                if (context.mounted) showDone(context, 'Employee sign-in link copied');
              })),
        if (mine != null && mine['hasPin'] != true)
          _Notice(
            key: const Key('no-pin-banner'),
            icon: Icons.pin_outlined,
            title: 'You have no POS PIN yet',
            text: 'The POS asks everyone, including the owner, for a PIN. Set yours to sign in there.',
            action: PrimaryButton(key: const Key('set-my-pin'), label: 'Set my PIN', icon: Icons.pin_rounded, height: 48, onPressed: _setMyPin),
          ),
        const SizedBox(height: HPSpace.lg),
        Card(
          child: Column(children: [
            for (final (i, u) in active.indexed) ...[
              if (i > 0) const Divider(indent: 72),
              _StaffRow(user: u, onTap: u['id'] == myId ? _setMyPin : _canEdit && u['role'] != 'owner' && (u['role'] != 'it_admin' || _isOwner) ? () => _edit(u) : null),
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
        Padding(
          padding: const EdgeInsets.only(top: HPSpace.lg),
          child: Text('PINs: 6 to 8 digits, not one digit repeated and not a run like 123456. Five wrong tries lock the account for 15 minutes.',
              style: HPType.body(p.muted).copyWith(fontSize: 12)),
        ),
      ]),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.icon, required this.title, required this.text, this.action});
  final IconData icon;
  final String title, text;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return Padding(
      padding: const EdgeInsets.only(top: HPSpace.lg),
      child: Card(
        color: HPColors.amber.withValues(alpha: .12),
        child: Padding(
          padding: const EdgeInsets.all(HPSpace.lg),
          child: Wrap(spacing: HPSpace.lg, runSpacing: HPSpace.md, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Icon(icon, color: p.accentInk),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: HPType.titleCard(p.text)),
                const SizedBox(height: 2),
                Text(text, style: HPType.body(p.muted)),
              ]),
            ),
            ?action,
          ]),
        ),
      ),
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
        [roleLabel(user), if (user['email'] != null) '${user['email']}', if (user['canDiscount'] == true) 'can give discounts'].join(' · '),
        style: HPType.body(p.muted),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Wrap(spacing: HPSpace.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (user['locked'] == true) const StatusChip(label: 'Locked', tone: HPTone.danger, icon: Icons.lock_clock_outlined),
        if (!off && user['webAccess'] == true) const StatusChip(label: 'Web', icon: Icons.language_rounded),
        if (off)
          const StatusChip(label: 'Off', tone: HPTone.danger)
        else if (user['hasPin'] == true)
          const StatusChip(label: 'PIN set', tone: HPTone.success)
        else
          const StatusChip(label: 'No PIN', tone: HPTone.saffron),
        if (onTap != null) const Icon(Icons.chevron_right_rounded),
      ]),
      onTap: onTap,
    );
  }
}

class _StaffEditor extends StatefulWidget {
  const _StaffEditor({required this.api, required this.user, required this.roles, required this.customRoles, required this.limits});
  final ApiClient api;
  final Json? user;
  final List<String> roles;
  final List<Json> customRoles;
  final Json limits;
  @override
  State<_StaffEditor> createState() => _StaffEditorState();
}

class _StaffEditorState extends State<_StaffEditor> {
  late final _name = TextEditingController(text: widget.user?['name'] as String? ?? '');
  late final _email = TextEditingController(text: widget.user?['email'] as String? ?? '');
  late final _phone = TextEditingController(text: widget.user?['phone'] as String? ?? '');
  final _pin = TextEditingController(), _password = TextEditingController();
  late String _role = widget.user?['role'] as String? ?? 'waiter';
  late String? _customRoleId = widget.user?['customRoleId'] as String? ?? widget.customRoles.firstOrNull?['id'] as String?;
  late bool _canDiscount = widget.user?['canDiscount'] as bool? ?? false;
  late bool _webAccess = widget.user?['webAccess'] as bool? ?? false;
  late bool _active = widget.user == null || widget.user!['status'] == 'active';
  bool _invite = true, _consoleLogin = false, _busy = false;
  String? _error;

  bool get _isNew => widget.user == null;
  bool get _portalInPlan => widget.limits['staffPortal'] == true;

  Future<void> _save() async {
    final pin = _pin.text.trim();
    if (_name.text.trim().isEmpty) return setState(() => _error = 'Enter a name');
    if (!_email.text.trim().contains('@')) return setState(() => _error = 'Enter their work email');
    final setPinNow = !_isNew || !_invite;
    if (setPinNow && (pin.isNotEmpty || _isNew)) {
      final problem = pinProblem(pin);
      if (problem != null) return setState(() => _error = problem);
    }
    if (_consoleLogin && _password.text.length < 8) return setState(() => _error = 'Console password needs 8+ characters');
    if (_role == 'custom' && _customRoleId == null) return setState(() => _error = 'Choose the custom role');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      String done;
      if (_isNew) {
        final r = await widget.api.createStaff({
          'name': _name.text.trim(), 'email': _email.text.trim(), 'role': _role, 'canDiscount': _role == 'cashier' && _canDiscount,
          'status': _active ? 'active' : 'disabled', 'webAccess': _webAccess,
          if (_role == 'custom') 'customRoleId': _customRoleId,
          if (_phone.text.trim().isNotEmpty) 'phone': _phone.text.trim(),
          if (_invite) 'sendInvite': true else 'pin': pin,
          if (_consoleLogin) 'password': _password.text,
        });
        final inv = r['invite'] as Json?;
        done = inv == null
            ? '${_name.text.trim()} added — they can use the POS in about a minute'
            : inv['emailSent'] == true
                ? 'Invite sent to ${_email.text.trim()} — they choose their own PIN'
                : 'Added, but the email failed. Send them this link: ${inv['url']}';
      } else {
        await widget.api.updateStaff(widget.user!['id'] as String, {
          'name': _name.text.trim(), 'email': _email.text.trim(), 'phone': _phone.text.trim().isEmpty ? null : _phone.text.trim(),
          if (widget.user!['role'] != 'owner') ...{
            'role': _role, 'canDiscount': _role == 'cashier' && _canDiscount, 'webAccess': _webAccess, 'status': _active ? 'active' : 'disabled',
            if (_role == 'custom') 'customRoleId': _customRoleId,
          },
          if (pin.isNotEmpty) 'pin': pin,
        });
        done = 'Saved';
      }
      if (mounted) Navigator.pop(context, done);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendLink() async {
    setState(() => _busy = true);
    try {
      final r = await widget.api.staffPinLink(widget.user!['id'] as String);
      if (mounted) Navigator.pop(context, r['emailSent'] == true ? 'PIN link emailed to ${widget.user!['email']}' : 'Email failed. Send them this link: ${r['url']}');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlock() async {
    try {
      await widget.api.staffUnlock(widget.user!['id'] as String);
      if (mounted) Navigator.pop(context, '${widget.user!['name']} can sign in again');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final roles = {...widget.roles, if (!_isNew) _role}.toList();
    return HPDialog(
      title: _isNew ? 'Add a person' : 'Edit ${widget.user!['name']}',
      actions: [
        SecondaryButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        PrimaryButton(key: const Key('save-staff'), label: _isNew && _invite ? 'Add & send invite' : 'Save', busy: _busy, height: 56, onPressed: _save),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(key: const Key('staff-name'), controller: _name, autofocus: _isNew, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Full name')),
        const SizedBox(height: HPSpace.md),
        TextField(key: const Key('staff-email'), controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Work email')),
        const SizedBox(height: HPSpace.md),
        TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone (optional)')),
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
        if (_role == 'custom')
          DropdownButtonFormField<String>(
            key: const Key('custom-role'),
            initialValue: _customRoleId,
            decoration: const InputDecoration(labelText: 'Which custom role'),
            items: [for (final r in widget.customRoles) DropdownMenuItem(value: r['id'] as String, child: Text('${r['name']}'))],
            onChanged: (v) => setState(() => _customRoleId = v),
          ),
        if (_role == 'cashier')
          SwitchListTile(contentPadding: EdgeInsets.zero, value: _canDiscount, onChanged: (v) => setState(() => _canDiscount = v), title: const Text('Can give discounts')),
        const SizedBox(height: HPSpace.md),
        Text('PIN', style: HPType.overline(p.muted)),
        if (_isNew)
          RadioGroup<bool>(
            groupValue: _invite,
            onChanged: (v) => setState(() => _invite = v!),
            child: Column(children: const [
              RadioListTile<bool>(key: Key('pin-invite'), contentPadding: EdgeInsets.zero, dense: true, value: true, title: Text('Email an invite — they choose their own PIN (recommended)')),
              RadioListTile<bool>(key: Key('pin-now'), contentPadding: EdgeInsets.zero, dense: true, value: false, title: Text('Set a PIN now and tell them in person')),
            ]),
          ),
        if (!_isNew || !_invite)
          TextField(
            key: const Key('staff-pin'),
            controller: _pin,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            obscureText: true,
            maxLength: 8,
            decoration: InputDecoration(labelText: _isNew ? 'PIN (6 to 8 digits, e.g. 246813)' : 'New PIN (leave empty to keep)', counterText: '', prefixIcon: const Icon(Icons.pin_outlined)),
          ),
        if (!_isNew && widget.user!['email'] != null)
          Wrap(spacing: HPSpace.sm, children: [
            TextButton.icon(key: const Key('send-pin-link'), onPressed: _busy ? null : _sendLink, icon: const Icon(Icons.mark_email_read_outlined, size: 18), label: const Text('Email a PIN reset link')),
            if (widget.user!['locked'] == true) TextButton.icon(key: const Key('unlock'), onPressed: _unlock, icon: const Icon(Icons.lock_open_rounded, size: 18), label: const Text('Unlock')),
          ]),
        const SizedBox(height: HPSpace.sm),
        if (widget.user?['role'] != 'owner') ...[
          SwitchListTile(
            key: const Key('web-access'),
            contentPadding: EdgeInsets.zero,
            value: _webAccess && _portalInPlan,
            onChanged: _portalInPlan ? (v) => setState(() => _webAccess = v) : null,
            title: const Text('Can sign in to the web portal'),
            subtitle: Text(_portalInPlan ? 'With their work email and PIN' : 'Not in your plan'),
          ),
          SwitchListTile(
            key: const Key('staff-active'),
            contentPadding: EdgeInsets.zero,
            value: _active,
            onChanged: (v) => setState(() => _active = v),
            title: const Text('Active'),
            subtitle: const Text('Turned-off people cannot sign in anywhere'),
          ),
        ],
        if (_isNew && _role == 'it_admin') ...[
          SwitchListTile(contentPadding: EdgeInsets.zero, value: _consoleLogin, onChanged: (v) => setState(() => _consoleLogin = v), title: const Text('Also a console password')),
          if (_consoleLogin) TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password (8+ characters)')),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: HPSpace.sm), child: Text(_error!, key: const Key('staff-error'), style: HPType.body(p.danger))),
      ]),
    );
  }
}

class _MyPinDialog extends StatefulWidget {
  const _MyPinDialog({required this.api});
  final ApiClient api;
  @override
  State<_MyPinDialog> createState() => _MyPinDialogState();
}

class _MyPinDialogState extends State<_MyPinDialog> {
  final _pin = TextEditingController(), _again = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    final pin = _pin.text.trim();
    final problem = pinProblem(pin);
    if (problem != null) return setState(() => _error = problem);
    if (pin != _again.text.trim()) return setState(() => _error = 'The two PINs do not match');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.setMyPin(pin);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    InputDecoration deco(String label) => InputDecoration(labelText: label, counterText: '');
    return HPDialog(
      title: 'Your POS PIN',
      actions: [SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(context)), PrimaryButton(key: const Key('save-my-pin'), label: 'Save PIN', busy: _busy, height: 56, onPressed: _save)],
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('6 to 8 digits. You enter it on the POS after tapping your name.', style: HPType.body(p.muted)),
        const SizedBox(height: HPSpace.md),
        TextField(key: const Key('my-pin'), controller: _pin, autofocus: true, obscureText: true, maxLength: 8, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: deco('New PIN')),
        const SizedBox(height: HPSpace.sm),
        TextField(key: const Key('my-pin-again'), controller: _again, obscureText: true, maxLength: 8, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: deco('Type it again'), onSubmitted: (_) => _save()),
        if (_error != null) ...[const SizedBox(height: HPSpace.sm), Text(_error!, style: HPType.body(p.danger))],
      ]),
    );
  }
}
