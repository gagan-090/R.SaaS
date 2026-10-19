import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'staff_screen.dart' show roleInfo;

/// Areas for grouping permissions in the role editor (key prefix → heading).
const _areas = <(String, String)>[
  ('restaurant', 'Restaurant & plan'), ('license', 'Restaurant & plan'), ('staff', 'Employees'), ('roles', 'Employees'),
  ('device', 'Devices'), ('floor', 'Floors & tables'), ('menu', 'Menu'), ('recipe', 'Menu'), ('order', 'Orders'),
  ('discount', 'Billing'), ('payment', 'Billing'), ('bill', 'Billing'), ('kds', 'Kitchen'), ('inventory', 'Inventory'),
  ('expense', 'Expenses'), ('import', 'Imports'), ('shift', 'Shifts'), ('clock', 'Shifts'), ('reports', 'Reports & logs'), ('audit', 'Reports & logs'),
];
String _area(String key) => _areas.firstWhere((a) => key.startsWith(a.$1), orElse: () => ('', 'Other')).$2;

/// Roles: what each built-in role can do, and the owner's custom roles (plan feature "roles.custom").
class RolesScreen extends ConsumerStatefulWidget {
  const RolesScreen({super.key});
  @override
  ConsumerState<RolesScreen> createState() => _RolesScreenState();
}

class _RolesScreenState extends ConsumerState<RolesScreen> {
  Json? _data;
  Object? _error;

  ApiClient get _api => ref.read(apiProvider);
  bool get _canManage {
    final a = ref.read(authProvider);
    return a is SignedIn && a.can('roles.manage');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _api.restaurantRoles();
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<String, String> get _describe => {for (final c in (_data!['catalog'] as List).cast<Json>()) '${c['key']}': '${c['description']}'};

  Future<void> _edit([Json? role]) async {
    final saved = await showDialog<String>(barrierDismissible: false, context: context, builder: (_) => _RoleEditor(api: _api, role: role, catalog: (_data!['catalog'] as List).cast<Json>()));
    if (saved != null) {
      await _load();
      if (mounted) showDone(context, saved);
    }
  }

  Future<void> _delete(Json role) async {
    if (!await confirm(context, title: 'Delete ${role['name']}?', message: 'Employees must be moved to another role first.')) return;
    try {
      await _api.deleteRole(role['id'] as String);
      await _load();
      if (mounted) showDone(context, '${role['name']} deleted');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return loadErrorView(_error!, page: 'Roles', onRetry: _load);
    if (_data == null) return const LoadingState();
    final p = context.hp;
    final inPlan = _data!['customRolesInPlan'] == true;
    final custom = (_data!['custom'] as List).cast<Json>();
    final describe = _describe;
    Widget perms(List perms) => Wrap(spacing: HPSpace.xs, runSpacing: HPSpace.xs, children: [
          for (final k in perms.cast<String>()) Chip(label: Text(describe[k] ?? k, style: HPType.body(p.text).copyWith(fontSize: 12)), visualDensity: VisualDensity.compact),
        ]);
    return PageFrame(
      title: 'Roles',
      subtitle: 'What each role can do. Plan features limit every role.',
      actions: [if (_canManage && inPlan) PrimaryButton(key: const Key('add-role'), label: 'New custom role', icon: Icons.add_rounded, height: 48, onPressed: () => _edit())],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionCard(
          title: 'Custom roles',
          child: !inPlan
              ? Row(key: const Key('roles-locked'), children: [
                  Icon(Icons.lock_outline_rounded, color: p.muted),
                  const SizedBox(width: HPSpace.md),
                  Expanded(child: Text('Custom roles are not in your plan. Ask House Plating to switch on "Custom roles" for your plan.', style: HPType.body(p.muted))),
                ])
              : custom.isEmpty
                  ? Text('None yet. A custom role is a name plus the exact permissions you choose — for example a "Floor manager" who arranges tables but cannot take payments.', style: HPType.body(p.muted))
                  : Column(children: [
                      for (final r in custom)
                        ExpansionTile(
                          key: Key('custom-${r['name']}'),
                          tilePadding: EdgeInsets.zero,
                          title: Text('${r['name']}', style: HPType.label(p.text)),
                          subtitle: Text('${(r['permissions'] as List).length} permissions · ${r['members']} ${r['members'] == 1 ? 'person' : 'people'}', style: HPType.body(p.muted)),
                          childrenPadding: const EdgeInsets.only(bottom: HPSpace.md),
                          children: [
                            Align(alignment: Alignment.centerLeft, child: perms(r['permissions'] as List)),
                            if (_canManage)
                              Align(
                                alignment: Alignment.centerRight,
                                child: Wrap(spacing: HPSpace.sm, children: [
                                  TextButton(onPressed: () => _edit(r), child: const Text('Edit')),
                                  TextButton(onPressed: () => _delete(r), child: Text('Delete', style: TextStyle(color: p.danger))),
                                ]),
                              ),
                          ],
                        ),
                    ]),
        ),
        const SizedBox(height: HPSpace.lg),
        SectionCard(
          title: 'Built-in roles',
          child: Column(children: [
            for (final r in (_data!['builtIn'] as List).cast<Json>())
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                leading: Icon(roleInfo['${r['role']}']?.$2),
                title: Text(roleInfo['${r['role']}']?.$1 ?? '${r['role']}', style: HPType.label(p.text)),
                subtitle: Text(roleInfo['${r['role']}']?.$3 ?? '', style: HPType.body(p.muted)),
                childrenPadding: const EdgeInsets.only(bottom: HPSpace.md),
                children: [Align(alignment: Alignment.centerLeft, child: perms(r['permissions'] as List))],
              ),
          ]),
        ),
      ]),
    );
  }
}

class _RoleEditor extends StatefulWidget {
  const _RoleEditor({required this.api, required this.role, required this.catalog});
  final ApiClient api;
  final Json? role;
  final List<Json> catalog;
  @override
  State<_RoleEditor> createState() => _RoleEditorState();
}

class _RoleEditorState extends State<_RoleEditor> {
  late final _name = TextEditingController(text: widget.role?['name'] as String? ?? '');
  late final _desc = TextEditingController(text: widget.role?['description'] as String? ?? '');
  late final Set<String> _perms = {...((widget.role?['permissions'] as List?) ?? const []).cast<String>()};
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    if (_name.text.trim().length < 2) return setState(() => _error = 'Give the role a name');
    if (_perms.isEmpty) return setState(() => _error = 'Choose at least one permission');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = {'name': _name.text.trim(), 'description': _desc.text.trim().isEmpty ? null : _desc.text.trim(), 'permissions': _perms.toList()}..removeWhere((_, v) => v == null);
      if (widget.role == null) {
        await widget.api.createRole(body);
      } else {
        await widget.api.updateRole(widget.role!['id'] as String, body);
      }
      if (mounted) Navigator.pop(context, '${_name.text.trim()} saved');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final groups = <String, List<Json>>{};
    for (final c in widget.catalog) {
      groups.putIfAbsent(_area('${c['key']}'), () => []).add(c);
    }
    return HPDialog(
      title: widget.role == null ? 'New custom role' : 'Edit ${widget.role!['name']}',
      actions: [
        SecondaryButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        PrimaryButton(key: const Key('save-role'), label: 'Save', busy: _busy, height: 56, onPressed: _save),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(key: const Key('role-name'), controller: _name, decoration: const InputDecoration(labelText: 'Role name', hintText: 'Floor manager')),
        const SizedBox(height: HPSpace.md),
        TextField(controller: _desc, decoration: const InputDecoration(labelText: 'What they do (optional)')),
        const SizedBox(height: HPSpace.md),
        Text('Greyed-out permissions are not in your plan or are beyond your own access.', style: HPType.body(p.muted).copyWith(fontSize: 12)),
        for (final g in groups.entries) ...[
          Padding(padding: const EdgeInsets.only(top: HPSpace.md), child: Text(g.key.toUpperCase(), style: HPType.overline(p.muted))),
          for (final c in g.value)
            CheckboxListTile(
              key: Key('perm-${c['key']}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _perms.contains(c['key']),
              onChanged: c['grantable'] == true ? (v) => setState(() => v! ? _perms.add('${c['key']}') : _perms.remove('${c['key']}')) : null,
              title: Text('${c['description']}', style: HPType.body(c['grantable'] == true ? p.text : p.faint)),
            ),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: HPSpace.sm), child: Text(_error!, key: const Key('role-error'), style: HPType.body(p.danger))),
      ]),
    );
  }
}
