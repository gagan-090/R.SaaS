import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../api/api_client.dart';
import '../state/providers.dart';
import '../widgets/common.dart';

/// P3 Dashboard: counts + recent audit events.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiProvider);
    Future<Map<String, dynamic>> load() async {
      final in30 = DateTime.now().add(const Duration(days: 30)).toUtc().toIso8601String();
      final r = await Future.wait([
        api.restaurants(status: 'active'),
        api.restaurants(status: 'suspended'),
        api.restaurants(status: 'blocked'),
        api.restaurants(expiresBefore: in30),
        api.audit(),
      ]);
      return {'active': r[0]['total'], 'suspended': r[1]['total'], 'blocked': r[2]['total'], 'expiring': r[3]['total'], 'audit': r[4]['items']};
    }

    return AsyncView<Map<String, dynamic>>(
      load: load,
      builder: (c, d, _) => ListView(padding: const EdgeInsets.all(HPSpace.x4), children: [
        Text('Dashboard', style: Theme.of(c).textTheme.headlineMedium),
        const SizedBox(height: HPSpace.x2),
        Wrap(spacing: HPSpace.lg, runSpacing: HPSpace.lg, children: [
          _Kpi('Active', d['active'], HPTone.success, () => c.go('/restaurants?status=active')),
          _Kpi('Suspended', d['suspended'], HPTone.saffron, () => c.go('/restaurants?status=suspended')),
          _Kpi('Blocked', d['blocked'], HPTone.danger, () => c.go('/restaurants?status=blocked')),
          _Kpi('Expiring in 30 days', d['expiring'], HPTone.pending, () => c.go('/restaurants')),
        ]),
        const SizedBox(height: HPSpace.x2),
        SectionCard(
          title: 'Recent audit events',
          actions: [TextButton(onPressed: () => c.go('/audit'), child: const Text('Open audit log'))],
          child: Column(children: [for (final e in (d['audit'] as List).take(8)) _AuditRow(e as Map<String, dynamic>)]),
        ),
      ]),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, this.tone, this.onTap);
  final String label;
  final Object? value;
  final HPTone tone;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 220,
        child: Card(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(HPRadius.card),
            child: Padding(
              padding: const EdgeInsets.all(HPSpace.x2),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                StatusChip(label: label, tone: tone),
                const SizedBox(height: HPSpace.md),
                Text('${value ?? 0}', style: HPType.displayTotal(context.hp.text)),
              ]),
            ),
          ),
        ),
      );
}

class _AuditRow extends StatelessWidget {
  const _AuditRow(this.e);
  final Map<String, dynamic> e;
  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text('${e['action']}', style: HPType.label(context.hp.text)),
        subtitle: Text('${e['actorType'] ?? 'system'} ${e['actorId'] ?? ''} · ${e['reason'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Text(shortDate(e['at'])),
      );
}

/// P4 Restaurants list with search, filters and pagination; P5 register from here.
class RestaurantsScreen extends ConsumerStatefulWidget {
  const RestaurantsScreen({super.key, this.initialStatus});
  final String? initialStatus;
  @override
  ConsumerState<RestaurantsScreen> createState() => _RestaurantsScreenState();
}

class _RestaurantsScreenState extends ConsumerState<RestaurantsScreen> {
  final _q = TextEditingController(), _owner = TextEditingController();
  late String? _status = widget.initialStatus;
  String? _plan;
  int _page = 1;
  late Future<Map<String, dynamic>> Function() _load = _makeLoad();

  Future<Map<String, dynamic>> Function() _makeLoad() {
    final api = ref.read(apiProvider);
    final (q, owner, status, plan, page) = (_q.text, _owner.text, _status, _plan, _page);
    return () => api.restaurants(q: q, owner: owner, status: status, plan: plan, page: page);
  }

  void _apply({bool resetPage = true}) => setState(() {
        if (resetPage) _page = 1;
        _load = _makeLoad();
      });

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canCreate = auth is SignedIn && auth.can('platform.restaurant.create');
    return Padding(
      padding: const EdgeInsets.all(HPSpace.x4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Restaurants', style: Theme.of(context).textTheme.headlineMedium)),
          if (canCreate)
            SizedBox(width: 240, child: PrimaryButton(label: 'Register restaurant', icon: Icons.add_rounded, height: 52, onPressed: () async {
              if (await showDialog<bool>(context: context, builder: (_) => const RegisterRestaurantDialog()) == true) _apply();
            })),
        ]),
        const SizedBox(height: HPSpace.x2),
        Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: 260, child: TextField(key: const Key('search'), controller: _q, decoration: const InputDecoration(labelText: 'Search name or code', prefixIcon: Icon(Icons.search)), onSubmitted: (_) => _apply())),
          SizedBox(width: 220, child: TextField(controller: _owner, decoration: const InputDecoration(labelText: 'Owner email'), onSubmitted: (_) => _apply())),
          _Drop(label: 'Status', value: _status, items: const ['pending', 'active', 'suspended', 'blocked'], onChanged: (v) {
            _status = v;
            _apply();
          }),
          _Drop(label: 'Plan', value: _plan, items: [for (final p in ref.watch(activePlansProvider).valueOrNull ?? const <Json>[]) p['code'] as String], onChanged: (v) {
            _plan = v;
            _apply();
          }),
          SecondaryButton(label: 'Apply', icon: Icons.filter_alt_outlined, height: 48, onPressed: _apply),
        ]),
        const SizedBox(height: HPSpace.lg),
        Expanded(
          child: AsyncView<Map<String, dynamic>>(
            load: _load,
            isEmpty: (d) => (d['items'] as List).isEmpty,
            emptyTitle: 'No restaurants match these filters',
            builder: (c, d, reload) {
              final items = (d['items'] as List).cast<Map<String, dynamic>>();
              final total = d['total'] as int;
              return Card(
                child: Column(children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          showCheckboxColumn: false,
                          columns: const [
                            DataColumn(label: Text('Name')), DataColumn(label: Text('Code')), DataColumn(label: Text('Owner')),
                            DataColumn(label: Text('Plan')), DataColumn(label: Text('Status')), DataColumn(label: Text('License ends')), DataColumn(label: Text('Branches'), numeric: true),
                          ],
                          rows: [
                            for (final r in items)
                              DataRow(onSelectChanged: (_) => c.go('/restaurants/${r['id']}'), cells: [
                                DataCell(Text('${r['name']}', style: HPType.label(context.hp.text))),
                                DataCell(Text('${r['code']}', style: HPType.mono(context.hp.muted))),
                                DataCell(Text('${r['ownerEmail']}')),
                                DataCell(Text('${r['plan'] ?? '—'}')),
                                DataCell(StatusChip(label: '${r['status']}', tone: toneForStatus(r['status'] as String?))),
                                DataCell(Text(shortDate(r['licenseEndsAt']))),
                                DataCell(Text('${r['branches']}')),
                              ]),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.all(HPSpace.sm),
                    child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      Text('$total restaurants · page $_page'),
                      IconButton(tooltip: 'Previous page', onPressed: _page > 1 ? () => setState(() => (_page--, _load = _makeLoad())) : null, icon: const Icon(Icons.chevron_left)),
                      IconButton(tooltip: 'Next page', onPressed: _page * 25 < total ? () => setState(() => (_page++, _load = _makeLoad())) : null, icon: const Icon(Icons.chevron_right)),
                    ]),
                  ),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _Drop extends StatelessWidget {
  const _Drop({required this.label, required this.value, required this.items, required this.onChanged});
  final String label;
  final String? value;
  final List<String> items;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 200,
        child: DropdownButtonFormField<String?>(
          key: Key('filter-$label'),
          isExpanded: true,
          initialValue: value,
          decoration: InputDecoration(labelText: label),
          items: [const DropdownMenuItem(value: null, child: Text('Any')), for (final i in items) DropdownMenuItem(value: i, child: Text(i))],
          onChanged: onChanged,
        ),
      );
}

/// P5 Register restaurant → sends the owner a verification email; the tenant exists only after verification.
class RegisterRestaurantDialog extends ConsumerStatefulWidget {
  const RegisterRestaurantDialog({super.key});
  @override
  ConsumerState<RegisterRestaurantDialog> createState() => _RegisterRestaurantDialogState();
}

class _RegisterRestaurantDialogState extends ConsumerState<RegisterRestaurantDialog> {
  final _form = GlobalKey<FormState>();
  final _c = {for (final k in ['ownerEmail', 'ownerName', 'restaurantName', 'gstin', 'address']) k: TextEditingController()};
  String _plan = 'standard';
  bool _busy = false;
  static final _gstin = RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$');

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).registerRestaurant({
        'ownerEmail': _c['ownerEmail']!.text.trim(),
        'ownerName': _c['ownerName']!.text.trim(),
        'restaurantName': _c['restaurantName']!.text.trim(),
        if (_c['gstin']!.text.trim().isNotEmpty) 'gstin': _c['gstin']!.text.trim().toUpperCase(),
        if (_c['address']!.text.trim().isNotEmpty) 'address': _c['address']!.text.trim(),
        'planCode': _plan,
      });
      if (!mounted) return;
      showDone(context, 'Verification email sent to ${_c['ownerEmail']!.text.trim()}');
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => HPDialog(
        title: 'Register restaurant',
        actions: [
          SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(context)),
          PrimaryButton(label: 'Send verification', height: 56, busy: _busy, onPressed: _submit),
        ],
        child: Form(
          key: _form,
          child: Column(children: [
            TextFormField(controller: _c['ownerEmail'], decoration: const InputDecoration(labelText: 'Owner email'), validator: (v) => v != null && v.contains('@') ? null : 'Valid email required'),
            const SizedBox(height: HPSpace.md),
            TextFormField(controller: _c['ownerName'], decoration: const InputDecoration(labelText: 'Owner name'), validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null),
            const SizedBox(height: HPSpace.md),
            TextFormField(controller: _c['restaurantName'], decoration: const InputDecoration(labelText: 'Restaurant name'), validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null),
            const SizedBox(height: HPSpace.md),
            TextFormField(controller: _c['gstin'], decoration: const InputDecoration(labelText: 'GSTIN (optional)'),
                validator: (v) => (v ?? '').trim().isEmpty || _gstin.hasMatch(v!.trim().toUpperCase()) ? null : 'Not a valid GSTIN'),
            const SizedBox(height: HPSpace.md),
            TextFormField(controller: _c['address'], decoration: const InputDecoration(labelText: 'Address (optional)')),
            const SizedBox(height: HPSpace.md),
            Consumer(builder: (c, ref, _) {
              final plans = ref.watch(activePlansProvider).valueOrNull ?? const <Json>[];
              final codes = plans.map((p) => p['code'] as String).toList();
              return DropdownButtonFormField<String>(
                key: const Key('register-plan'),
                initialValue: codes.contains(_plan) ? _plan : (codes.isEmpty ? null : codes.first),
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Plan'),
                items: [for (final p in plans) DropdownMenuItem(value: p['code'] as String, child: Text('${p['name']} · ${formatPaise(p['pricePaise'] as int)}/${p['billingCycle'] == 'yearly' ? 'yr' : 'mo'}'))],
                onChanged: (v) => setState(() => _plan = v!),
              );
            }),
          ]),
        ),
      );
}

/// P6 Restaurant detail + P7 license actions + payments.
class RestaurantDetailScreen extends ConsumerStatefulWidget {
  const RestaurantDetailScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<RestaurantDetailScreen> createState() => _RestaurantDetailScreenState();
}

class _RestaurantDetailScreenState extends ConsumerState<RestaurantDetailScreen> {
  late Future<Map<String, dynamic>> Function() _load = () => ref.read(apiProvider).restaurant(widget.id);
  void _reload() => setState(() => _load = () => ref.read(apiProvider).restaurant(widget.id));

  Future<void> _status(String action) async {
    final reason = await ReasonDialog.show(context, title: '${action[0].toUpperCase()}${action.substring(1)} restaurant', confirmLabel: action[0].toUpperCase() + action.substring(1),
        message: 'The owner and staff are affected immediately. Suspended and blocked restaurants become read-only.', destructive: action == 'suspend' || action == 'block');
    if (reason == null || !mounted) return;
    try {
      await ref.read(apiProvider).setStatus(widget.id, action, reason);
      if (mounted) showDone(context, 'Restaurant ${action}d');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _license(String action, String? currentPlan) async {
    String? plan = currentPlan;
    if (action == 'upgrade' || action == 'downgrade' || action == 'issue') {
      final plans = await ref.read(activePlansProvider.future);
      if (!mounted) return;
      plan = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(title: Text('Choose plan to $action'), children: [
          for (final p in plans)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, p['code'] as String),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${p['name']}'),
                trailing: Text('${formatPaise(p['pricePaise'] as int)}/${p['billingCycle'] == 'yearly' ? 'yr' : 'mo'}'),
                selected: p['code'] == currentPlan,
              ),
            ),
        ]),
      );
      if (plan == null) return;
    }
    if (!mounted) return;
    final reason = await ReasonDialog.show(context, title: 'License: $action', confirmLabel: action[0].toUpperCase() + action.substring(1), destructive: action == 'revoke');
    if (reason == null || !mounted) return;
    try {
      await ref.read(apiProvider).licenseAction(widget.id, action, reason, planCode: action == 'renew' || action == 'revoke' ? null : plan);
      if (mounted) showDone(context, 'License ${action == 'issue' ? 'issued' : '${action}d'}');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _payment() async {
    final amount = TextEditingController(), ref0 = TextEditingController();
    String method = 'upi';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => HPDialog(title: 'Record payment', actions: [
          SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c)),
          PrimaryButton(label: 'Record', height: 56, onPressed: () => Navigator.pop(c, true)),
        ], child: Column(children: [
          TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount (₹, whole rupees)')),
          const SizedBox(height: HPSpace.md),
          DropdownButtonFormField<String>(initialValue: method, decoration: const InputDecoration(labelText: 'Method'),
              items: const [DropdownMenuItem(value: 'upi', child: Text('UPI')), DropdownMenuItem(value: 'bank', child: Text('Bank transfer')), DropdownMenuItem(value: 'cash', child: Text('Cash')), DropdownMenuItem(value: 'other', child: Text('Other'))],
              onChanged: (v) => set(() => method = v!)),
          const SizedBox(height: HPSpace.md),
          TextField(controller: ref0, decoration: const InputDecoration(labelText: 'Reference (UTR / cheque no.)')),
        ])),
      ),
    );
    final rupees = int.tryParse(amount.text.trim());
    if (ok != true || rupees == null || rupees <= 0 || !mounted) return;
    try {
      await ref.read(apiProvider).recordPayment(widget.id, {'amountPaise': rupees * 100, 'method': method, 'reference': ref0.text.trim(), 'paidAt': DateTime.now().toUtc().toIso8601String()});
      if (mounted) showDone(context, 'Payment recorded');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    bool can(String p) => auth is SignedIn && auth.can(p);
    return AsyncView<Map<String, dynamic>>(
      load: _load,
      builder: (c, r, _) {
        final status = r['status'] as String;
        final ent = (r['entitlement'] as Map?)?.cast<String, dynamic>() ?? const {};
        final lic = (r['currentLicense'] as Map?)?.cast<String, dynamic>();
        return ListView(padding: const EdgeInsets.all(HPSpace.x4), children: [
          Row(children: [
            IconButton(tooltip: 'Back', onPressed: () => c.go('/restaurants'), icon: const Icon(Icons.arrow_back)),
            Expanded(child: Text('${r['name']}', style: Theme.of(c).textTheme.headlineMedium)),
            StatusChip(label: status, tone: toneForStatus(status)),
            const SizedBox(width: HPSpace.sm),
            StatusChip(label: 'License: ${ent['state'] ?? 'none'}', tone: toneForStatus('${ent['state']}')),
          ]),
          const SizedBox(height: HPSpace.x2),
          Wrap(spacing: HPSpace.lg, runSpacing: HPSpace.lg, children: [
            SizedBox(
              width: 460,
              child: SectionCard(title: 'Profile', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _kv('Code', r['code']), _kv('Owner', r['ownerEmail']), _kv('GSTIN', r['gstin']), _kv('Address', r['address']),
                _kv('Status reason', r['statusReason']), _kv('Created', shortDate(r['createdAt'])),
                if (can('platform.restaurant.status')) ...[
                  const SizedBox(height: HPSpace.lg),
                  Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
                    if (status == 'pending') SecondaryButton(label: 'Activate', height: 44, onPressed: () => _status('activate')),
                    if (status == 'active') SecondaryButton(label: 'Suspend', height: 44, onPressed: () => _status('suspend')),
                    if (status == 'active' || status == 'suspended') DangerButton(label: 'Block', onPressed: () => _status('block')),
                    if (status == 'suspended' || status == 'blocked') SecondaryButton(label: 'Reactivate', height: 44, onPressed: () => _status('reactivate')),
                  ]),
                ],
              ])),
            ),
            SizedBox(
              width: 460,
              child: SectionCard(title: 'License (P7)', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (lic == null) const Text('No active license — restaurant is read-only.') else ...[
                  _kv('Plan', lic['planCode']), _kv('Starts', shortDate(lic['startsAt'])), _kv('Ends', shortDate(lic['endsAt'])), _kv('Grace', '${lic['graceDays']} days'),
                  const SizedBox(height: HPSpace.sm),
                  Wrap(spacing: 6, runSpacing: 6, children: [for (final f in (ent['features'] as List? ?? const [])) Chip(label: Text('$f'), visualDensity: VisualDensity.compact)]),
                ],
                if (can('platform.license.manage')) ...[
                  const SizedBox(height: HPSpace.lg),
                  Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
                    for (final a in lic == null ? ['issue'] : ['renew', 'upgrade', 'downgrade'])
                      SecondaryButton(label: a[0].toUpperCase() + a.substring(1), height: 44, onPressed: () => _license(a, lic?['planCode'] as String?)),
                    if (lic != null) DangerButton(label: 'Revoke', onPressed: () => _license('revoke', null)),
                  ]),
                ],
              ])),
            ),
            SizedBox(
              width: 460,
              child: SectionCard(
                title: 'Payments',
                actions: [if (can('platform.payment.record')) TextButton.icon(onPressed: _payment, icon: const Icon(Icons.add), label: const Text('Record'))],
                child: (r['payments'] as List).isEmpty
                    ? const Text('No payments recorded yet.')
                    : Column(children: [
                        for (final p in (r['payments'] as List).cast<Map<String, dynamic>>())
                          ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(formatPaise(p['amountPaise'] as int)), subtitle: Text('${p['method']} · ${p['reference'] ?? ''}'), trailing: Text(shortDate(p['paidAt']))),
                      ]),
              ),
            ),
            SizedBox(
              width: 460,
              child: SectionCard(title: 'Branches & devices', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final b in (r['branches'] as List).cast<Map<String, dynamic>>()) _kv('${b['code']}', b['name']),
                const SizedBox(height: HPSpace.sm),
                for (final d in (r['devices'] as List).cast<Map<String, dynamic>>()) _kv(d['isHub'] == true ? 'Hub' : 'Device', '${d['name']} (${d['platform']}) · last seen ${shortDate(d['lastSeenAt'])}'),
                if ((r['devices'] as List).isEmpty) const Text('No devices paired yet.'),
              ])),
            ),
          ]),
          const SizedBox(height: HPSpace.lg),
          SectionCard(title: 'Audit (this restaurant)', child: SizedBox(height: 360, child: AuditList(tenantId: widget.id))),
        ]);
      },
    );
  }

  Widget _kv(String k, Object? v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 120, child: Text(k, style: HPType.body(context.hp.muted))),
          Expanded(child: Text(v == null || '$v'.isEmpty ? '—' : '$v', style: HPType.body(context.hp.text))),
        ]),
      );
}

/// P11 audit list (shared by the audit viewer and the restaurant detail tab). Tap a row for before/after.
class AuditList extends ConsumerStatefulWidget {
  const AuditList({super.key, this.tenantId, this.action});
  final String? tenantId;
  final String? action;
  @override
  ConsumerState<AuditList> createState() => _AuditListState();
}

class _AuditListState extends ConsumerState<AuditList> {
  @override
  Widget build(BuildContext context) => AsyncView<Map<String, dynamic>>(
        key: ValueKey('${widget.tenantId}|${widget.action}'),
        load: () => ref.read(apiProvider).audit(tenantId: widget.tenantId, action: widget.action),
        isEmpty: (d) => (d['items'] as List).isEmpty,
        emptyTitle: 'No audit events',
        builder: (c, d, _) => ListView(children: [
          for (final e in (d['items'] as List).cast<Map<String, dynamic>>())
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('${e['action']}', style: HPType.label(context.hp.text)),
              subtitle: Text('${shortDate(e['at'])} · ${e['actorType'] ?? 'system'} ${e['actorId'] ?? ''}${e['reason'] != null ? ' · “${e['reason']}”' : ''}'),
              children: [
                Align(alignment: Alignment.centerLeft, child: SelectableText('object: ${e['objectType']} ${e['objectId']}\nbefore: ${e['before']}\nafter:  ${e['after']}', style: HPType.mono(context.hp.muted))),
              ],
            ),
        ]),
      );
}

/// P11 audit viewer with filters.
class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});
  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  final _action = TextEditingController(), _tenant = TextEditingController();
  String? _a, _t;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(HPSpace.x4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Audit log', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: HPSpace.lg),
          Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, children: [
            SizedBox(width: 260, child: TextField(controller: _action, decoration: const InputDecoration(labelText: 'Action contains'))),
            SizedBox(width: 340, child: TextField(controller: _tenant, decoration: const InputDecoration(labelText: 'Restaurant id'))),
            SecondaryButton(label: 'Filter', height: 48, onPressed: () => setState(() => (_a = _action.text.trim(), _t = _tenant.text.trim()))),
          ]),
          const SizedBox(height: HPSpace.lg),
          Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(HPSpace.lg), child: AuditList(action: _a, tenantId: _t)))),
        ]),
      );
}

/// P8 Plans (feature flags + limits).
String apiErrorText(Object e) => e is ApiException ? e.message : '$e';
