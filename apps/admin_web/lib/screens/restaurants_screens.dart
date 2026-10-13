import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../api/api_client.dart';
import '../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/labels.dart';

/// P3 Super Admin dashboard: the platform at a glance (status counts, revenue), what needs attention today
/// (owners who have not activated, licenses about to end), plans in use and the latest activity.
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
        api.registrations(),
        api.plans(),
      ]);
      return {
        'active': (r[0] as Map)['total'], 'suspended': (r[1] as Map)['total'], 'blocked': (r[2] as Map)['total'],
        'expiring': (r[3] as Map)['total'], 'expiringItems': (r[3] as Map)['items'], 'audit': (r[4] as Map)['items'], 'awaiting': ((r[5] as Map)['counts'] as Map)['awaiting'], 'awaitingItems': (r[5] as Map)['items'], 'plans': r[6],
      };
    }

    return AsyncView<Map<String, dynamic>>(
      load: load,
      builder: (c, d, reload) {
        final p = context.hp;
        final narrow = isNarrowWeb(context);
        final plans = (d['plans'] as List).cast<Map<String, dynamic>>();
        // monthly recurring revenue from the plans restaurants are on right now (yearly plans count 1/12 per month)
        final mrr = plans.fold<int>(0, (s, x) => s + ((x['pricePaise'] as int) * ((x['activeLicenses'] as int?) ?? 0) ~/ (x['billingCycle'] == 'yearly' ? 12 : 1)));
        final awaiting = (d['awaitingItems'] as List).cast<Map<String, dynamic>>();
        final expiring = (d['expiringItems'] as List).cast<Map<String, dynamic>>();
        final kpis = <Widget>[
          _Kpi('Awaiting verification', d['awaiting'], HPTone.pending, Icons.mark_email_unread_outlined, () => c.go('/restaurants?status=pending')),
          _Kpi('Active', d['active'], HPTone.success, Icons.storefront_outlined, () => c.go('/restaurants?status=active')),
          _Kpi('Suspended', d['suspended'], HPTone.saffron, Icons.pause_circle_outline, () => c.go('/restaurants?status=suspended')),
          _Kpi('Blocked', d['blocked'], HPTone.danger, Icons.block, () => c.go('/restaurants?status=blocked')),
          _Kpi('Licenses ending in 30 days', d['expiring'], HPTone.pending, Icons.event_busy_outlined, () => c.go('/restaurants')),
          _Kpi('Monthly revenue (plans)', formatPaise(mrr).replaceAll('.00', ''), HPTone.success, Icons.currency_rupee_rounded, () => c.go('/plans')),
        ];
        Widget section(String title, Widget child, {List<Widget> actions = const []}) => SectionCard(title: title, actions: actions, child: child);
        final attention = section(
          'Needs your attention',
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (awaiting.isEmpty && expiring.isEmpty) Text('All clear — nothing waiting.', style: HPType.body(p.muted)),
            for (final r in awaiting.take(4))
              _AttentionRow(
                icon: Icons.mark_email_unread_outlined,
                tone: HPTone.pending,
                title: '${r['restaurantName']}',
                subtitle: 'Owner has not activated yet · ${r['ownerEmail']}',
                onTap: () => c.go('/restaurants?status=pending'),
              ),
            for (final r in expiring.take(4))
              _AttentionRow(
                icon: Icons.event_busy_outlined,
                tone: HPTone.saffron,
                title: '${r['name']}',
                subtitle: 'License ends ${shortDate(r['licenseEndsAt'])} · ${titleCase('${r['plan'] ?? ''}')}',
                onTap: () => c.go('/restaurants/${r['id']}'),
              ),
          ]),
        );
        final planMix = section(
          'Restaurants by plan',
          Column(children: [
            for (final pl in plans)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Expanded(child: Text('${pl['name']}', style: HPType.label(p.text), overflow: TextOverflow.ellipsis)),
                  Text('${pl['activeLicenses'] ?? 0}', style: HPType.titleCard(p.text).copyWith(fontSize: 18)),
                  const SizedBox(width: HPSpace.md),
                  SizedBox(width: 96, child: Text('${formatPaise(pl['pricePaise'] as int).replaceAll('.00', '')}/${pl['billingCycle'] == 'yearly' ? 'yr' : 'mo'}', textAlign: TextAlign.right, style: HPType.body(p.muted))),
                ]),
              ),
          ]),
          actions: [TextButton(onPressed: () => c.go('/plans'), child: const Text('Plans'))],
        );
        final activity = section(
          'Recent activity',
          Column(children: [for (final e in (d['audit'] as List).take(8)) _AuditRow(e as Map<String, dynamic>)]),
          actions: [TextButton(onPressed: () => c.go('/audit'), child: const Text('Audit log'))],
        );
        return RefreshIndicator(
          onRefresh: () async => reload(),
          child: PageFrame(
            title: 'Dashboard',
            subtitle: 'Your restaurants at a glance',
            actions: [IconButton(tooltip: 'Refresh', onPressed: reload, icon: const Icon(Icons.refresh_rounded))],
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              LayoutBuilder(builder: (c2, box) {
                final cols = box.maxWidth < 560 ? 2 : 3;
                const gap = HPSpace.md;
                final w = (box.maxWidth - gap * (cols - 1)) / cols;
                return Wrap(spacing: gap, runSpacing: gap, children: [for (final k in kpis) SizedBox(width: w, child: k)]);
              }),
              const SizedBox(height: HPSpace.lg),
              if (narrow) ...[attention, const SizedBox(height: HPSpace.lg), planMix, const SizedBox(height: HPSpace.lg), activity]
              else
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 3, child: Column(children: [attention, const SizedBox(height: HPSpace.lg), activity])),
                  const SizedBox(width: HPSpace.lg),
                  Expanded(flex: 2, child: planMix),
                ]),
            ]),
          ),
        );
      },
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, this.tone, this.icon, this.onTap);
  final String label;
  final Object? value;
  final HPTone tone;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final narrow = isNarrowWeb(context);
    return Card(
      key: Key('kpi-$label'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(narrow ? HPSpace.md : HPSpace.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: p.tone(tone).withValues(alpha: .14), borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 18, color: p.tone(tone)),
              ),
              const Spacer(),
              Icon(Icons.chevron_right_rounded, size: 18, color: p.faint),
            ]),
            const SizedBox(height: HPSpace.sm),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text('${value ?? 0}', style: HPType.displayTotal(p.text).copyWith(fontSize: narrow ? 28 : 34))),
            Text(label, style: HPType.body(p.muted).copyWith(fontSize: narrow ? 12.5 : 14), maxLines: 2, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({required this.icon, required this.tone, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final HPTone tone;
  final String title, subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(radius: 18, backgroundColor: p.tone(tone).withValues(alpha: .14), child: Icon(icon, size: 18, color: p.tone(tone))),
      title: Text(title, style: HPType.label(p.text), overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, style: HPType.body(p.muted), maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow(this.e);
  final Map<String, dynamic> e;
  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(auditActionLabel(e['action']), style: HPType.label(context.hp.text)),
        subtitle: Text(['by ${auditActor(e)}', if (e['tenantName'] != null) '${e['tenantName']}', if (e['reason'] != null) '“${e['reason']}”'].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Text(shortDate(e['at']), style: HPType.body(context.hp.muted).copyWith(fontSize: 12)),
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

  /// "pending" restaurants are registrations awaiting the owner's email: they live in their own tab.
  late bool _awaitingTab = widget.initialStatus == 'pending';
  int _awaitingReload = 0;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canCreate = auth is SignedIn && auth.can('platform.restaurant.create');
    final narrow = isNarrowWeb(context);
    return Padding(
      padding: EdgeInsets.all(narrow ? HPSpace.lg : HPSpace.x4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, runSpacing: HPSpace.md, children: [
          Text('Restaurants', style: Theme.of(context).textTheme.headlineMedium),
          if (canCreate)
            SizedBox(width: 240, child: PrimaryButton(key: const Key('register-restaurant'), label: 'Register restaurant', icon: Icons.add_rounded, height: 52, onPressed: () async {
              if (await showDialog<bool>(context: context, builder: (_) => const RegisterRestaurantDialog()) == true) {
                // a new registration waits for the owner's email: show it there
                setState(() {
                  _awaitingTab = true;
                  _awaitingReload++;
                });
              }
            })),
        ]),
        const SizedBox(height: HPSpace.lg),
        SegmentedButton<bool>(
          key: const Key('restaurants-tabs'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('Restaurants'), icon: Icon(Icons.storefront_outlined)),
            ButtonSegment(value: true, label: Text('Awaiting verification'), icon: Icon(Icons.mark_email_unread_outlined)),
          ],
          selected: {_awaitingTab},
          onSelectionChanged: (v) => setState(() => _awaitingTab = v.first),
        ),
        const SizedBox(height: HPSpace.lg),
        if (_awaitingTab) Expanded(child: PendingRegistrations(key: ValueKey(_awaitingReload), canAct: canCreate)) else ..._list(context),
      ]),
    );
  }

  List<Widget> _list(BuildContext context) => [
        Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: isNarrowWeb(context) ? double.infinity : 260, child: TextField(key: const Key('search'), controller: _q, decoration: const InputDecoration(labelText: 'Search name or code', prefixIcon: Icon(Icons.search)), onSubmitted: (_) => _apply())),
          SizedBox(width: isNarrowWeb(context) ? double.infinity : 220, child: TextField(controller: _owner, decoration: const InputDecoration(labelText: 'Owner email'), onSubmitted: (_) => _apply())),
          _Drop(label: 'Status', value: _status == 'pending' ? null : _status, items: const ['active', 'suspended', 'blocked'], onChanged: (v) {
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
              if (isNarrowWeb(context)) {
                // phones: one card per restaurant instead of a sideways-scrolling table
                return ListView(children: [
                  for (final r in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: HPSpace.sm),
                      child: OrderCard(
                        key: Key('row-${r['code']}'),
                        title: '${r['name']}',
                        subtitle: '${r['code']} · ${titleCase('${r['plan'] ?? 'no plan'}')}${r['licenseEndsAt'] == null ? '' : ' · ends ${shortDate(r['licenseEndsAt'])}'}',
                        total: '',
                        status: statusLabel(r['status']),
                        tone: toneForStatus(r['status'] as String?),
                        onTap: () => c.go('/restaurants/${r['id']}'),
                      ),
                    ),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    IconButton(tooltip: 'Previous page', onPressed: _page > 1 ? () => setState(() => (_page--, _load = _makeLoad())) : null, icon: const Icon(Icons.chevron_left)),
                    Text('$total · page $_page'),
                    IconButton(tooltip: 'Next page', onPressed: _page * 25 < total ? () => setState(() => (_page++, _load = _makeLoad())) : null, icon: const Icon(Icons.chevron_right)),
                  ]),
                ]);
              }
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
                                DataCell(Text(titleCase('${r['plan'] ?? '—'}'))),
                                DataCell(StatusChip(label: statusLabel(r['status']), tone: toneForStatus(r['status'] as String?))),
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
      ];
}

class _Drop extends StatelessWidget {
  const _Drop({required this.label, required this.value, required this.items, required this.onChanged});
  final String label;
  final String? value;
  final List<String> items;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: isNarrowWeb(context) ? (MediaQuery.sizeOf(context).width - 2 * HPSpace.lg - HPSpace.md) / 2 : 200,
        child: DropdownButtonFormField<String?>(
          key: Key('filter-$label'),
          isExpanded: true,
          initialValue: value,
          decoration: InputDecoration(labelText: label),
          items: [const DropdownMenuItem(value: null, child: Text('Any')), for (final i in items) DropdownMenuItem(value: i, child: Text(statusLabel(i)))],
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
      final r = await ref.read(apiProvider).registerRestaurant({
        'ownerEmail': _c['ownerEmail']!.text.trim(),
        'ownerName': _c['ownerName']!.text.trim(),
        'restaurantName': _c['restaurantName']!.text.trim(),
        if (_c['gstin']!.text.trim().isNotEmpty) 'gstin': _c['gstin']!.text.trim().toUpperCase(),
        if (_c['address']!.text.trim().isNotEmpty) 'address': _c['address']!.text.trim(),
        'planCode': _plan,
      });
      if (!mounted) return;
      if (r['emailSent'] == false) {
        // e.g. Resend sandbox: only the account's own address receives mail until a domain is verified
        await showActivationLinkDialog(context, r);
        if (mounted) Navigator.pop(context, true);
        return;
      }
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
    final plans = ref.watch(activePlansProvider).valueOrNull ?? const <Json>[];
    return AsyncView<Map<String, dynamic>>(
      load: _load,
      builder: (c, r, _) {
        final p = context.hp;
        final narrow = isNarrowWeb(context);
        final status = r['status'] as String;
        final ent = (r['entitlement'] as Map?)?.cast<String, dynamic>() ?? const {};
        final lic = (r['currentLicense'] as Map?)?.cast<String, dynamic>();
        final plan = plans.where((x) => x['code'] == lic?['planCode']).firstOrNull;
        final planName = '${plan?['name'] ?? lic?['planName'] ?? titleCase('${lic?['planCode'] ?? 'No plan'}')}';
        final ends = DateTime.tryParse('${lic?['endsAt'] ?? ''}');
        final daysLeft = ends?.difference(DateTime.now()).inDays;
        final devices = (r['devices'] as List).cast<Map<String, dynamic>>();
        final hub = devices.where((d) => d['isHub'] == true && d['revokedAt'] == null).firstOrNull;
        final features = (ent['features'] as List? ?? const []).cast<String>();

        Widget btn(Widget b) => SizedBox(height: 44, child: b);
        final profile = SectionCard(title: 'Profile', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _kv('Code', r['code']), _kv('Owner', r['ownerEmail']), _kv('GSTIN', r['gstin']), _kv('Address', r['address']),
          if (r['statusReason'] != null) _kv('Status reason', r['statusReason']),
          _kv('Created', shortDate(r['createdAt'])),
          if (can('platform.restaurant.status')) ...[
            const SizedBox(height: HPSpace.lg),
            Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
              if (status == 'pending') btn(SecondaryButton(label: 'Activate', icon: Icons.check_circle_outline, height: 44, onPressed: () => _status('activate'))),
              if (status == 'active') btn(SecondaryButton(label: 'Suspend', icon: Icons.pause_circle_outline, height: 44, onPressed: () => _status('suspend'))),
              if (status == 'suspended' || status == 'blocked') btn(SecondaryButton(label: 'Reactivate', icon: Icons.play_circle_outline, height: 44, onPressed: () => _status('reactivate'))),
              if (status == 'active' || status == 'suspended') btn(DangerButton(label: 'Block', icon: Icons.block, height: 44, onPressed: () => _status('block'))),
            ]),
          ],
        ]));
        final license = SectionCard(title: 'License', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (lic == null)
            Text('No active license — the restaurant is read-only until one is issued.', style: HPType.body(p.muted))
          else ...[
            _kv('Plan', '$planName${plan == null ? '' : ' · ${formatPaise(plan['pricePaise'] as int).replaceAll('.00', '')}/${plan['billingCycle'] == 'yearly' ? 'year' : 'month'}'}'),
            _kv('Started', shortDate(lic['startsAt'])),
            _kv('Ends', '${shortDate(lic['endsAt'])}${daysLeft == null ? '' : daysLeft >= 0 ? ' · $daysLeft days left' : ' · ended ${-daysLeft} days ago'}'),
            _kv('Grace period', '${lic['graceDays']} days after the end date'),
            const SizedBox(height: HPSpace.md),
            Text('INCLUDES', style: HPType.overline(p.muted)),
            const SizedBox(height: HPSpace.sm),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final f in features)
                Chip(
                  avatar: Icon(Icons.check_rounded, size: 16, color: p.success),
                  label: Text(featureLabel(f)),
                  visualDensity: VisualDensity.compact,
                ),
            ]),
          ],
          if (can('platform.license.manage')) ...[
            const SizedBox(height: HPSpace.lg),
            Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
              for (final (a, icon) in lic == null ? const [('issue', Icons.add_card_outlined)] : const [('renew', Icons.autorenew), ('upgrade', Icons.trending_up), ('downgrade', Icons.trending_down)])
                btn(SecondaryButton(label: a[0].toUpperCase() + a.substring(1), icon: icon, height: 44, onPressed: () => _license(a, lic?['planCode'] as String?))),
              if (lic != null) btn(DangerButton(label: 'Revoke', icon: Icons.cancel_outlined, height: 44, onPressed: () => _license('revoke', null))),
            ]),
          ],
        ]));
        final payments = SectionCard(
          title: 'Subscription payments',
          actions: [if (can('platform.payment.record')) TextButton.icon(onPressed: _payment, icon: const Icon(Icons.add), label: const Text('Record'))],
          child: (r['payments'] as List).isEmpty
              ? Text('No payments recorded yet.', style: HPType.body(p.muted))
              : Column(children: [
                  for (final pay in (r['payments'] as List).cast<Map<String, dynamic>>())
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.payments_outlined, color: p.success),
                      title: Text(formatPaise(pay['amountPaise'] as int), style: HPType.label(p.text)),
                      subtitle: Text('${titleCase('${pay['method']}')}${(pay['reference'] ?? '') == '' ? '' : ' · ${pay['reference']}'}', style: HPType.body(p.muted)),
                      trailing: Text(shortDate(pay['paidAt']), style: HPType.body(p.muted)),
                    ),
                ]),
        );
        final branches = SectionCard(title: 'Branches & devices', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final b in (r['branches'] as List).cast<Map<String, dynamic>>())
            ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.storefront_outlined, color: p.muted), title: Text('${b['name']}', style: HPType.label(p.text)), subtitle: Text('Branch ${b['code']}', style: HPType.body(p.muted))),
          for (final d in devices)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(d['isHub'] == true ? Icons.router_rounded : Icons.phone_android_rounded, color: d['revokedAt'] == null ? p.text : p.faint),
              title: Text('${d['name']}${d['isHub'] == true ? ' · Hub' : ''}', style: HPType.label(d['revokedAt'] == null ? p.text : p.faint)),
              subtitle: Text('${titleCase('${d['platform']}')} · ${d['revokedAt'] != null ? 'revoked' : 'last seen ${shortDate(d['lastSeenAt'])}'}', style: HPType.body(p.muted)),
            ),
          if (devices.isEmpty) Text('No devices yet. The owner sets up the hub from the POS app.', style: HPType.body(p.muted)),
        ]));

        const gap = SizedBox(height: HPSpace.lg, width: HPSpace.lg);
        return ListView(padding: EdgeInsets.all(narrow ? HPSpace.lg : HPSpace.x4), children: [
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: HPSpace.md, runSpacing: HPSpace.sm, children: [
            IconButton(tooltip: 'Back to restaurants', onPressed: () => c.go('/restaurants'), icon: const Icon(Icons.arrow_back)),
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('${r['name']}', style: HPType.titleScreen(p.text).copyWith(fontSize: narrow ? 28 : 34)),
              Text('${r['code']} · ${r['ownerEmail']}', style: HPType.body(p.muted)),
            ]),
            StatusChip(label: statusLabel(status), tone: toneForStatus(status)),
            StatusChip(label: 'License: ${statusLabel(ent['state'])}', tone: toneForStatus('${ent['state']}')),
          ]),
          const SizedBox(height: HPSpace.x2),
          LayoutBuilder(builder: (c2, box) {
            final cols = narrow ? 2 : 4;
            final w = (box.maxWidth - HPSpace.lg * (cols - 1)) / cols;
            return Wrap(spacing: HPSpace.lg, runSpacing: HPSpace.lg, children: [
              SizedBox(width: w, child: KpiCard(label: 'Plan', value: planName, caption: plan == null ? null : '${formatPaise(plan['pricePaise'] as int).replaceAll('.00', '')} / ${plan['billingCycle'] == 'yearly' ? 'year' : 'month'}', icon: Icons.workspace_premium_outlined, tone: HPTone.saffron)),
              SizedBox(width: w, child: KpiCard(label: 'License ends', value: ends == null ? '—' : shortDate(lic?['endsAt']), caption: daysLeft == null ? null : (daysLeft >= 0 ? '$daysLeft days left' : 'ended'), icon: Icons.event_outlined, tone: daysLeft != null && daysLeft < 7 ? HPTone.danger : HPTone.success)),
              SizedBox(width: w, child: KpiCard(label: 'Branches', value: '${(r['branches'] as List).length}', icon: Icons.storefront_outlined)),
              SizedBox(width: w, child: KpiCard(label: 'Devices', value: '${devices.where((d) => d['revokedAt'] == null).length}', caption: hub == null ? 'No hub yet' : 'Hub: ${hub['name']}', icon: Icons.router_outlined, tone: hub == null ? HPTone.neutral : HPTone.success)),
            ]);
          }),
          const SizedBox(height: HPSpace.lg),
          if (narrow) ...[profile, gap, license, gap, payments, gap, branches]
          else
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(children: [profile, gap, payments])),
              gap,
              Expanded(child: Column(children: [license, gap, branches])),
            ]),
          const SizedBox(height: HPSpace.lg),
          SectionCard(
            title: 'History',
            actions: [TextButton(onPressed: () => c.go('/audit'), child: const Text('Open audit log'))],
            child: AuditList(tenantId: widget.id, embedded: true),
          ),
        ]);
      },
    );
  }

  Widget _kv(String k, Object? v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(k, style: HPType.body(context.hp.muted))),
          Expanded(child: Text(v == null || '$v'.isEmpty ? '—' : '$v', style: HPType.body(context.hp.text))),
        ]),
      );
}

/// P11 audit list (shared by the audit viewer and the restaurant detail page): what happened, who did it, when,
/// why — tap a row to see exactly what changed.
class AuditList extends ConsumerStatefulWidget {
  const AuditList({super.key, this.tenantId, this.action, this.embedded = false});
  final String? tenantId;
  final String? action;

  /// Inside another page: no own scrolling, shows the latest events.
  final bool embedded;
  @override
  ConsumerState<AuditList> createState() => _AuditListState();
}

class _AuditListState extends ConsumerState<AuditList> {
  static IconData _icon(String action) => switch (action.split('.').first) {
        'auth' || 'mfa' => Icons.login_rounded,
        'restaurant' || 'tenant' => Icons.storefront_outlined,
        'license' || 'plan' || 'payment' => Icons.workspace_premium_outlined,
        'menu' || 'tax_rule' => Icons.restaurant_menu_rounded,
        'staff' => Icons.badge_outlined,
        'device' => Icons.router_outlined,
        'floor' || 'table' => Icons.table_restaurant_outlined,
        _ => Icons.history_rounded,
      };

  static String _when(Object? iso) {
    final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (t == null) return '';
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '${shortDate(iso)}, $h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  static String _short(Object? v) {
    if (v == null) return '—';
    final s = v is String ? v : '$v';
    return s.length > 60 ? '${s.substring(0, 57)}…' : s;
  }

  /// Field-by-field changes ("Status: active → suspended"); for creations just the new values.
  static List<(String, String)> _changes(Map<String, dynamic> e) {
    final before = (e['before'] as Map?)?.cast<String, dynamic>() ?? const {};
    final after = (e['after'] as Map?)?.cast<String, dynamic>() ?? const {};
    const hidden = {'id', 'tenantId', 'branchId', 'seq', 'createdAt', 'updatedAt', 'signedToken', 'passwordHash', 'pinHash', 'tokenHash', 'deleted'};
    final keys = {...before.keys, ...after.keys}.where((k) => !hidden.contains(k)).toList();
    return [
      for (final k in keys)
        if ('${before[k]}' != '${after[k]}' || before.isEmpty)
          (titleCase(k.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}').toLowerCase()), before.isEmpty || !before.containsKey(k) ? _short(after[k]) : '${_short(before[k])} → ${_short(after[k])}'),
    ];
  }

  @override
  Widget build(BuildContext context) => AsyncView<Map<String, dynamic>>(
        key: ValueKey('${widget.tenantId}|${widget.action}'),
        load: () => ref.read(apiProvider).audit(tenantId: widget.tenantId, action: widget.action),
        isEmpty: (d) => (d['items'] as List).isEmpty,
        emptyTitle: 'No history yet',
        builder: (c, d, _) {
          final p = context.hp;
          final items = (d['items'] as List).cast<Map<String, dynamic>>().take(widget.embedded ? 12 : 1000).toList();
          final tiles = [
            for (final e in items)
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  leading: CircleAvatar(radius: 18, backgroundColor: p.raised, child: Icon(_icon('${e['action']}'), size: 18, color: p.muted)),
                  title: Text(auditActionLabel(e['action']), style: HPType.label(p.text)),
                  subtitle: Text(
                    [
                      'by ${auditActor(e)}',
                      if (widget.tenantId == null && e['tenantName'] != null) '${e['tenantName']}',
                      _when(e['at']),
                      if (e['reason'] != null) '“${e['reason']}”',
                    ].join(' · '),
                    style: HPType.body(p.muted),
                  ),
                  childrenPadding: const EdgeInsets.only(left: 52, bottom: HPSpace.md),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (k, v) in _changes(e))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          SizedBox(width: 160, child: Text(k, style: HPType.body(p.muted))),
                          Expanded(child: SelectableText(v, style: HPType.body(p.text))),
                        ]),
                      ),
                    if (_changes(e).isEmpty) Text('No field changes recorded.', style: HPType.body(p.faint)),
                    if (e['ip'] != null) Text('From ${e['ip']}', style: HPType.body(p.faint).copyWith(fontSize: 12)),
                  ],
                ),
              ),
          ];
          return widget.embedded ? Column(children: tiles) : ListView(children: tiles);
        },
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
        padding: EdgeInsets.all(isNarrowWeb(context) ? HPSpace.lg : HPSpace.x4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Audit log', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: HPSpace.lg),
          Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, children: [
            SizedBox(width: isNarrowWeb(context) ? double.infinity : 260, child: TextField(controller: _action, decoration: const InputDecoration(labelText: 'Action contains'))),
            SizedBox(width: isNarrowWeb(context) ? double.infinity : 340, child: TextField(controller: _tenant, decoration: const InputDecoration(labelText: 'Restaurant id'))),
            SecondaryButton(label: 'Filter', height: 48, onPressed: () => setState(() => (_a = _action.text.trim(), _t = _tenant.text.trim()))),
          ]),
          const SizedBox(height: HPSpace.lg),
          Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(HPSpace.lg), child: AuditList(action: _a, tenantId: _t)))),
        ]),
      );
}

/// P8 Plans (feature flags + limits).
/// Shown when the email provider refused the message: the Super Admin passes the link on another way.
Future<void> showActivationLinkDialog(BuildContext context, Map<String, dynamic> r) => showDialog<void>(
      context: context,
      builder: (c) => HPDialog(
        title: 'Email not delivered',
        actions: [PrimaryButton(label: 'Done', height: 52, onPressed: () => Navigator.pop(c))],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text('The email provider said: ${r['emailError']}', style: HPType.body(c.hp.text)),
          const SizedBox(height: HPSpace.md),
          Text('Send the owner this activation link yourself (valid 72 hours):', style: HPType.body(c.hp.muted)),
          const SizedBox(height: HPSpace.sm),
          Container(
            padding: const EdgeInsets.all(HPSpace.md),
            decoration: BoxDecoration(color: c.hp.raised, borderRadius: BorderRadius.circular(12)),
            child: SelectableText('${r['verifyUrl']}', key: const Key('verify-link'), style: HPType.mono(c.hp.text)),
          ),
          const SizedBox(height: HPSpace.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy link'),
              onPressed: () => Clipboard.setData(ClipboardData(text: '${r['verifyUrl']}')),
            ),
          ),
        ]),
      ),
    );

String _ago(Object? iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  if (d == null) return '—';
  final m = DateTime.now().difference(d).inMinutes;
  if (m < 1) return 'just now';
  if (m < 60) return '$m min ago';
  if (m < 1440) return '${m ~/ 60} h ago';
  return '${m ~/ 1440} d ago';
}

String _expiresIn(Object? iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  if (d == null) return '—';
  final m = d.difference(DateTime.now()).inMinutes;
  if (m <= 0) return 'expired ${_ago(iso)}';
  if (m < 60) return 'expires in $m min';
  return 'expires in ${m ~/ 60} h';
}

/// Registrations waiting for the owner to confirm their email: resend a fresh link or cancel.
class PendingRegistrations extends ConsumerStatefulWidget {
  const PendingRegistrations({super.key, required this.canAct});
  final bool canAct;
  @override
  ConsumerState<PendingRegistrations> createState() => _PendingRegistrationsState();
}

class _PendingRegistrationsState extends ConsumerState<PendingRegistrations> {
  String _state = 'awaiting';
  String _q = '';
  int _reload = 0;
  final _busy = <String>{};

  Future<void> _resend(Map<String, dynamic> r) async {
    setState(() => _busy.add(r['id'] as String));
    try {
      final res = await ref.read(apiProvider).resendVerification(r['id'] as String);
      if (!mounted) return;
      setState(() => _busy.remove(r['id'])); // stop the spinner before any dialog opens
      if (res['emailSent'] == false) {
        await showActivationLinkDialog(context, res);
      } else {
        showDone(context, 'New link sent to ${r['ownerEmail']}');
      }
      setState(() => _reload++);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove(r['id']));
    }
  }

  Future<void> _cancel(Map<String, dynamic> r) async {
    final reason = await ReasonDialog.show(context, title: 'Cancel ${r['restaurantName']}?', confirmLabel: 'Cancel registration', message: 'The activation link stops working. You can register the restaurant again later.');
    if (reason == null) return;
    try {
      await ref.read(apiProvider).cancelRegistration(r['id'] as String, reason);
      if (mounted) showDone(context, 'Registration cancelled');
      setState(() => _reload++);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final (k, label) in const [('awaiting', 'Awaiting'), ('expired', 'Link expired'), ('cancelled', 'Cancelled'), ('all', 'All')])
          ChoiceChip(key: Key('reg-$k'), label: Text(label), selected: _state == k, onSelected: (_) => setState(() => _state = k)),
        SizedBox(width: 260, child: HPSearchField(hint: 'Restaurant or owner email', onChanged: (v) => setState(() => _q = v.trim()))),
      ]),
      const SizedBox(height: HPSpace.lg),
      Expanded(
        child: AsyncView<Map<String, dynamic>>(
          key: ValueKey('$_state|$_q|$_reload'),
          load: () => ref.read(apiProvider).registrations(state: _state, q: _q),
          isEmpty: (d) => (d['items'] as List).isEmpty,
          emptyTitle: _state == 'awaiting' ? 'Nobody is waiting to verify' : 'Nothing here',
          builder: (c, d, reload) => ListView(children: [
            for (final r in (d['items'] as List).cast<Map<String, dynamic>>())
              Padding(
                padding: const EdgeInsets.only(bottom: HPSpace.md),
                child: Card(
                  key: Key('registration-${r['restaurantName']}'),
                  child: Padding(
                    padding: const EdgeInsets.all(HPSpace.lg),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(color: p.pending.withValues(alpha: .14), borderRadius: BorderRadius.circular(12)),
                          child: Icon(Icons.mark_email_unread_outlined, color: p.pending),
                        ),
                        const SizedBox(width: HPSpace.md),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${r['restaurantName']}', style: HPType.titleCard(p.text)),
                            Text('${r['ownerName']} · ${r['ownerEmail']}', style: HPType.body(p.muted), overflow: TextOverflow.ellipsis),
                          ]),
                        ),
                        StatusChip(
                          label: switch (r['state']) { 'expired' => 'Link expired', 'cancelled' => 'Cancelled', _ => 'Awaiting owner' },
                          tone: switch (r['state']) { 'expired' => HPTone.saffron, 'cancelled' => HPTone.danger, _ => HPTone.pending },
                        ),
                      ]),
                      const SizedBox(height: HPSpace.md),
                      Wrap(spacing: HPSpace.lg, runSpacing: HPSpace.xs, children: [
                        _Fact(Icons.workspace_premium_outlined, '${r['planName']}'),
                        _Fact(Icons.send_outlined, 'Sent ${_ago(r['lastSentAt'] ?? r['createdAt'])}${(r['sendCount'] as int? ?? 1) > 1 ? ' · ${r['sendCount']}×' : ''}'),
                        if (r['state'] != 'cancelled') _Fact(Icons.timer_outlined, _expiresIn(r['expiresAt'])),
                        if (r['cancelReason'] != null) _Fact(Icons.block_outlined, 'Cancelled: ${r['cancelReason']}'),
                      ]),
                      if (r['lastEmailError'] != null && r['state'] != 'cancelled')
                        Container(
                          margin: const EdgeInsets.only(top: HPSpace.md),
                          padding: const EdgeInsets.all(HPSpace.sm),
                          decoration: BoxDecoration(color: p.danger.withValues(alpha: .1), borderRadius: BorderRadius.circular(10)),
                          child: Row(children: [
                            Icon(Icons.error_outline_rounded, size: 18, color: p.danger),
                            const SizedBox(width: HPSpace.sm),
                            Expanded(child: Text('Last email not delivered: ${r['lastEmailError']}', style: HPType.body(p.text).copyWith(fontSize: 13))),
                          ]),
                        ),
                      if (widget.canAct && r['state'] != 'cancelled') ...[
                        const SizedBox(height: HPSpace.md),
                        Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
                          SizedBox(
                            width: 200,
                            child: PrimaryButton(
                              key: Key('resend-${r['restaurantName']}'),
                              label: r['state'] == 'expired' ? 'Send a new link' : 'Resend email',
                              icon: Icons.forward_to_inbox_rounded,
                              height: 44,
                              busy: _busy.contains(r['id']),
                              onPressed: () => _resend(r),
                            ),
                          ),
                          SizedBox(width: 120, child: SecondaryButton(key: Key('cancel-${r['restaurantName']}'), label: 'Cancel', height: 44, onPressed: () => _cancel(r))),
                        ]),
                      ],
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ),
    ]);
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: context.hp.muted),
        const SizedBox(width: 6),
        Text(text, style: HPType.body(context.hp.muted)),
      ]);
}

String apiErrorText(Object e) => e is ApiException ? e.message : '$e';
