import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../api/api_client.dart';
import '../state/providers.dart';
import '../widgets/common.dart';

/// Feature flags a plan can include (apps/api/src/common/permissions.ts FEATURE_FLAGS), grouped for the editor.
const featureGroups = <(String, List<(String, String)>)>[
  ('Essentials', [
    ('tables', 'Tables & table status'), ('orders.dinein', 'Dine-in orders'), ('orders.takeaway', 'Takeaway orders'),
    ('menu', 'Menu, categories, tax'), ('billing', 'Bills, GST, tips, payments'), ('offline.single', 'Works offline on one device'),
  ]),
  ('Growing restaurant', [
    ('floors', 'Multiple floors'), ('multi_cashier', 'More than one cashier'), ('waiter_app', 'Waiter app on Android'),
    ('lan_hub', 'Pair devices over Wi-Fi'),
  ]),
  ('Premium', [
    ('franchise', 'Multiple branches'), ('roles.extended', 'Chef, IT admin, auditor roles'), ('kds', 'Kitchen display'),
    ('recipes', 'Recipes'), ('menu.approval', 'Chef approval of menu changes'), ('inventory', 'Inventory'), ('shifts', 'Shifts & attendance'),
    ('branding', 'Custom branding (logo, colour, text style)'),
  ]),
  ('Web portal & management', [
    ('staff_portal', 'Staff web portal (email + PIN)'),
    ('roles.custom', 'Custom employee roles'),
    ('floor.editor', 'Visual floor editor (drag tables & chairs)'),
    ('import.excel', 'Excel import (menu & inventory)'),
    ('expenses', 'Expenses & expense logs'),
  ]),
];

const limitKeys = <(String, String)>[
  ('branches', 'Branches'), ('floorsPerBranch', 'Floors per branch'), ('devicesPerBranch', 'Devices per branch'),
  ('concurrentCashiers', 'Cashiers at once'), ('staffPerBranch', 'Staff per branch'),
];

/// P8 Plans: what each plan costs and includes. Super Admins add plans, change prices and features, and archive
/// plans they no longer sell (licenses on an archived plan keep working until changed).
class PlansScreen extends ConsumerStatefulWidget {
  const PlansScreen({super.key});
  @override
  ConsumerState<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends ConsumerState<PlansScreen> {
  bool _archived = false;
  int _reload = 0;

  bool get _canEdit {
    final a = ref.read(authProvider);
    return a is SignedIn && a.can('platform.plan.manage');
  }

  Future<void> _edit([Json? plan]) async {
    final saved = await showDialog<String>(context: context, builder: (_) => PlanEditor(api: ref.read(apiProvider), plan: plan));
    if (saved == null) return;
    ref.invalidate(activePlansProvider);
    setState(() => _reload++);
    if (mounted) showDone(context, saved);
  }

  Future<void> _archive(Json p, bool archived) async {
    final n = p['activeLicenses'] as int? ?? 0;
    if (archived &&
        !await confirm(context,
            title: 'Archive ${p['name']}?',
            message: n == 0
                ? 'It will no longer be offered to new restaurants.'
                : '$n restaurant(s) are on this plan. They keep it until you change their license; new restaurants cannot choose it.',
            confirmLabel: 'Archive')) {
      return;
    }
    try {
      await ref.read(apiProvider).updatePlan(p['id'] as String, {'archived': archived});
      ref.invalidate(activePlansProvider);
      setState(() => _reload++);
      if (mounted) showDone(context, archived ? '${p['name']} archived' : '${p['name']} is on sale again');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final edit = _canEdit;
    return AsyncView<List<dynamic>>(
      key: ValueKey('$_reload-$_archived'),
      load: () => ref.read(apiProvider).plans(includeArchived: _archived),
      builder: (c, data, reload) {
        final plans = data.cast<Json>().toList();
        // Strict ordering: Standard (tier 1) -> Professional (tier 2) -> Premium (tier 3)
        plans.sort((a, b) {
          final tA = (a['tier'] as int?) ?? 999;
          final tB = (b['tier'] as int?) ?? 999;
          if (tA != tB) return tA.compareTo(tB);
          return ((a['pricePaise'] as int?) ?? 0).compareTo((b['pricePaise'] as int?) ?? 0);
        });
        final narrow = isNarrowWeb(context);
        return PageFrame(
          title: 'Plans',
          subtitle: 'Standard, Professional, and Premium subscription plans. Customers can purchase monthly or yearly.',
          actions: [
            FilterChip(label: const Text('Show archived'), selected: _archived, onSelected: (v) => setState(() => _archived = v)),
            if (edit) PrimaryButton(key: const Key('add-plan'), label: 'Add plan', icon: Icons.add_rounded, height: 48, onPressed: () => _edit()),
          ],
          child: plans.isEmpty
              ? const EmptyState(title: 'No plans', icon: Icons.workspace_premium_outlined)
              : LayoutBuilder(builder: (c, box) {
                  final cols = narrow ? 1 : (box.maxWidth / 360).floor().clamp(1, 4);
                  const gap = HPSpace.lg;
                  final w = (box.maxWidth - gap * (cols - 1)) / cols;
                  return Wrap(spacing: gap, runSpacing: gap, children: [
                    for (final p in plans) SizedBox(width: w, child: _PlanCard(plan: p, canEdit: edit, onEdit: () => _edit(p), onArchive: (v) => _archive(p, v))),
                  ]);
                }),
        );
      },
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.canEdit, required this.onEdit, required this.onArchive});
  final Json plan;
  final bool canEdit;
  final VoidCallback onEdit;
  final ValueChanged<bool> onArchive;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final archived = plan['archived'] == true;
    final features = (plan['featureFlags'] as List).cast<String>();
    final limits = (plan['limits'] as Map).cast<String, dynamic>();
    final monthlyPaise = (plan['pricePaise'] as int?) ?? 0;
    final yearlyPaise = (plan['yearlyPricePaise'] as int?) ?? (monthlyPaise * 10);
    final tier = plan['tier'] as int?;
    final tierName = switch (tier) { 1 => 'Bottom Tier', 2 => 'Mid Tier', 3 => 'Top Tier', _ => 'Custom Tier' };
    return Opacity(
      opacity: archived ? .6 : 1,
      child: Card(
        key: Key('plan-${plan['code']}'),
        child: Padding(
          padding: const EdgeInsets.all(HPSpace.x2),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${plan['name']}', style: HPType.titleCard(p.text).copyWith(fontSize: 24), overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text('${plan['code']}', style: HPType.mono(p.faint)),
                        if (tier != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(4)),
                            child: Text('$tierName (Tier $tier)', style: HPType.mono(p.muted).copyWith(fontSize: 11)),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (archived) const Padding(padding: EdgeInsets.only(right: 4), child: StatusChip(label: 'Archived', tone: HPTone.danger)),
              if (canEdit)
                PopupMenuButton<String>(
                  key: Key('plan-menu-${plan['code']}'),
                  tooltip: 'Plan actions',
                  onSelected: (v) => v == 'edit' ? onEdit() : onArchive(!archived),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: ListTile(dense: true, leading: Icon(Icons.edit_outlined), title: Text('Edit price & features'))),
                    PopupMenuItem(value: 'archive', child: ListTile(dense: true, leading: Icon(archived ? Icons.unarchive_outlined : Icons.archive_outlined), title: Text(archived ? 'Put back on sale' : 'Archive'))),
                  ],
                ),
            ]),
            const SizedBox(height: HPSpace.md),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${formatPaise(monthlyPaise).replaceAll('.00', '')} / month',
                  key: Key('plan-price-${plan['code']}'),
                  style: HPType.displayTotal(p.accentInk).copyWith(fontSize: 28),
                ),
                Text(
                  '${formatPaise(yearlyPaise).replaceAll('.00', '')} / year (annual)',
                  style: HPType.label(p.muted).copyWith(fontSize: 15),
                ),
              ],
            ),
            const SizedBox(height: HPSpace.xs),
            Text('${plan['activeLicenses'] ?? 0} restaurant(s) on this plan', style: HPType.body(p.muted)),
            const SizedBox(height: HPSpace.lg),
            Text('INCLUDES', style: HPType.overline(p.muted)),
            const SizedBox(height: HPSpace.sm),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final f in features) Chip(label: Text(_label(f)), visualDensity: VisualDensity.compact),
            ]),
            const SizedBox(height: HPSpace.lg),
            Text('LIMITS', style: HPType.overline(p.muted)),
            const SizedBox(height: HPSpace.xs),
            for (final (k, label) in limitKeys)
              if (limits.containsKey(k))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(child: Text(label, style: HPType.body(p.muted))),
                    Text(limits[k] == null ? 'Unlimited' : '${limits[k]}', style: HPType.label(p.text)),
                  ]),
                ),
            if (canEdit) ...[
              const SizedBox(height: HPSpace.lg),
              SecondaryButton(label: 'Edit', icon: Icons.edit_outlined, height: 44, onPressed: onEdit),
            ],
          ]),
        ),
      ),
    );
  }

  static String _label(String flag) {
    for (final (_, items) in featureGroups) {
      for (final (k, l) in items) {
        if (k == flag) return l;
      }
    }
    return flag;
  }
}

/// Add / edit a plan: name, price in rupees, billing cycle, features and limits.
class PlanEditor extends StatefulWidget {
  const PlanEditor({super.key, required this.api, this.plan});
  final ApiClient api;
  final Json? plan;
  @override
  State<PlanEditor> createState() => _PlanEditorState();
}

class _PlanEditorState extends State<PlanEditor> {
  late final _name = TextEditingController(text: widget.plan?['name'] as String? ?? '');
  late final _code = TextEditingController(text: widget.plan?['code'] as String? ?? '');
  late final _price = TextEditingController(text: widget.plan == null ? '' : _plain(widget.plan!['pricePaise'] as int));
  late final _yearlyPrice = TextEditingController(text: widget.plan == null ? '' : _plain(widget.plan!['yearlyPricePaise'] as int? ?? ((widget.plan!['pricePaise'] as int) * 10)));
  late int _tier = (widget.plan?['tier'] as int?) ?? (widget.plan?['code'] == 'standard' ? 1 : widget.plan?['code'] == 'professional' ? 2 : widget.plan?['code'] == 'premium' ? 3 : 1);
  late String _cycle = widget.plan?['billingCycle'] as String? ?? 'monthly';
  late final Set<String> _features = {...((widget.plan?['featureFlags'] as List?) ?? const ['tables', 'orders.dinein', 'orders.takeaway', 'menu', 'billing', 'offline.single']).cast<String>()};
  late final Map<String, TextEditingController> _limits = {
    for (final (k, _) in limitKeys) k: TextEditingController(text: _limitText(((widget.plan?['limits'] as Map?) ?? const {'branches': 1})[k])),
  };
  bool _busy = false;
  String? _error;

  bool get _isNew => widget.plan == null;
  static String _plain(int paise) => paise % 100 == 0 ? '${paise ~/ 100}' : (paise / 100).toStringAsFixed(2);
  static String _limitText(Object? v) => v == null ? '' : '$v';

  void _autoCode(String name) {
    if (!_isNew) return;
    final c = name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    _code.text = c.isEmpty || !RegExp('^[a-z]').hasMatch(c) ? '' : (c.length > 30 ? c.substring(0, 30) : c);
    if (c.contains('standard')) _tier = 1;
    if (c.contains('prof')) _tier = 2;
    if (c.contains('prem')) _tier = 3;
  }

  void _autoYearly(String val) {
    if (!_isNew) return;
    final m = double.tryParse(val.trim().replaceAll(',', ''));
    if (m != null && m > 0 && (_yearlyPrice.text.isEmpty || _yearlyPrice.text == '${(m * 10).round()}')) {
      _yearlyPrice.text = '${(m * 10).round()}';
    }
  }

  Future<void> _save() async {
    final rupees = double.tryParse(_price.text.trim().replaceAll(',', ''));
    if (_name.text.trim().isEmpty) return setState(() => _error = 'Give the plan a name');
    if (rupees == null || rupees < 0) return setState(() => _error = 'Enter the price in rupees, e.g. 999');
    if (_isNew && !RegExp(r'^[a-z][a-z0-9_]{2,30}$').hasMatch(_code.text.trim())) {
      return setState(() => _error = 'Code: 3–31 lowercase letters, digits or _, starting with a letter');
    }
    final limits = <String, int?>{};
    for (final (k, label) in limitKeys) {
      final t = _limits[k]!.text.trim();
      if (t.isEmpty) {
        limits[k] = null; // unlimited
      } else if (int.tryParse(t) == null || int.parse(t) < 0) {
        return setState(() => _error = '$label must be a whole number (blank = unlimited)');
      } else {
        limits[k] = int.parse(t);
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final body = {
      'name': _name.text.trim(),
      'pricePaise': (rupees * 100).round(),
      'yearlyPricePaise': (rupees * 1000).round(),
      'tier': _tier,
      'billingCycle': _cycle,
      'featureFlags': _features.toList(),
      'limits': limits,
    };
    try {
      var n = 0;
      if (_isNew) {
        await widget.api.createPlan({...body, 'code': _code.text.trim()});
      } else {
        n = ((await widget.api.updatePlan(widget.plan!['id'] as String, body))['licensesUpdated'] as int?) ?? 0;
      }
      if (mounted) {
        Navigator.pop(context, _isNew ? '${body['name']} added' : '${body['name']} saved${n > 0 ? ' — $n restaurant${n == 1 ? '' : 's'} on this plan updated now' : ''}');
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
    return HPDialog(
      title: _isNew ? 'Add a plan' : 'Edit ${widget.plan!['name']}',
      actions: [
        SecondaryButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        PrimaryButton(key: const Key('save-plan'), label: 'Save', busy: _busy, height: 56, onPressed: _save),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(key: const Key('plan-name'), controller: _name, onChanged: _autoCode, decoration: const InputDecoration(labelText: 'Plan name', hintText: 'e.g. Standard, Professional, Premium')),
        if (_isNew) ...[
          const SizedBox(height: HPSpace.md),
          TextField(key: const Key('plan-code'), controller: _code, decoration: const InputDecoration(labelText: 'Code (cannot change later)', helperText: 'Used in licenses, e.g. standard')),
        ],
        const SizedBox(height: HPSpace.md),
        TextField(
          key: const Key('plan-price'),
          controller: _price,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
          decoration: const InputDecoration(labelText: 'Price', prefixText: '₹ ', helperText: 'Per billing period, before GST'),
        ),
        const SizedBox(height: HPSpace.md),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [ButtonSegment(value: 'monthly', label: Text('Monthly')), ButtonSegment(value: 'yearly', label: Text('Yearly'))],
          selected: {_cycle},
          onSelectionChanged: (v) => setState(() => _cycle = v.first),
        ),
        const SizedBox(height: HPSpace.lg),
        Text('Feature changes apply to restaurants already on this plan. Restaurant users should sign in again to refresh their available actions.', style: HPType.body(p.muted)),
        const SizedBox(height: HPSpace.md),
        for (final (group, items) in featureGroups) ...[
          Text(group.toUpperCase(), style: HPType.overline(p.muted)),
          const SizedBox(height: HPSpace.xs),
          Wrap(spacing: HPSpace.xs, runSpacing: HPSpace.xs, children: [
            for (final (k, label) in items)
              FilterChip(
                key: Key('feature-$k'),
                label: Text(label),
                selected: _features.contains(k),
                onSelected: (v) => setState(() => v ? _features.add(k) : _features.remove(k)),
              ),
          ]),
          const SizedBox(height: HPSpace.md),
        ],
        Text('LIMITS · BLANK = UNLIMITED', style: HPType.overline(p.muted)),
        const SizedBox(height: HPSpace.sm),
        Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
          for (final (k, label) in limitKeys)
            SizedBox(width: 180, child: TextField(controller: _limits[k], keyboardType: TextInputType.number, decoration: InputDecoration(labelText: label, isDense: true))),
        ]),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: HPSpace.md), child: Text(_error!, key: const Key('plan-error'), style: HPType.body(p.danger))),
      ]),
    );
  }
}
