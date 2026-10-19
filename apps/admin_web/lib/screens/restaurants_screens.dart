import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../api/api_client.dart';
import '../state/providers.dart';
import '../util/download.dart';
import '../widgets/common.dart';
import '../widgets/labels.dart';

/// P3 Super Admin dashboard: the platform at a glance (compact status counts, revenue), what needs attention today
/// (payment overdue / coming due, suspended > 3m, archived > 1y, awaiting verification), and granular categorized activity.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});
  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  String? _activityCategory; // null = all, 'account_lifecycle', 'auth_success', 'auth_failure', 'restaurant_lifecycle'

  @override
  Widget build(BuildContext context) {
    final api = ref.read(apiProvider);
    Future<Map<String, dynamic>> load() async {
      final r = await Future.wait([
        api.restaurants(status: 'active'),
        api.restaurants(status: 'suspended'),
        api.restaurants(status: 'blocked'),
        api.attention(),
        api.audit(category: _activityCategory),
        api.registrations(),
        api.plans(),
      ]);
      final attention = r[3] as Map<String, dynamic>;
      final counts = (attention['counts'] as Map?)?.cast<String, dynamic>() ?? const {};
      return {
        'active': (r[0] as Map)['total'],
        'suspended': (r[1] as Map)['total'],
        'blocked': (r[2] as Map)['total'],
        'attention': attention,
        'attentionCounts': counts,
        'audit': (r[4] as Map)['items'],
        'awaiting': ((r[5] as Map)['counts'] as Map)['awaiting'],
        'awaitingItems': (r[5] as Map)['items'],
        'plans': r[6],
      };
    }

    return AsyncView<Map<String, dynamic>>(
      key: ValueKey('dash-$_activityCategory'),
      load: load,
      builder: (c, d, reload) {
        final p = context.hp;
        final narrow = isNarrowWeb(context);
        final plans = (d['plans'] as List).cast<Map<String, dynamic>>();
        // monthly recurring revenue from the plans restaurants are on right now (yearly plans count 1/12 per month)
        final mrr = plans.fold<int>(0, (s, x) => s + ((x['pricePaise'] as int) * ((x['activeLicenses'] as int?) ?? 0) ~/ (x['billingCycle'] == 'yearly' ? 12 : 1)));
        final att = d['attention'] as Map<String, dynamic>;
        final overdue = (att['overdueLicenses'] as List? ?? const []).cast<Map<String, dynamic>>();
        final upcoming = (att['upcomingLicenses'] as List? ?? const []).cast<Map<String, dynamic>>();
        final suspended3m = (att['suspendedTenants'] as List? ?? const []).cast<Map<String, dynamic>>();
        final archived1y = (att['archivedTenants'] as List? ?? const []).cast<Map<String, dynamic>>();
        final awaiting = (d['awaitingItems'] as List).cast<Map<String, dynamic>>();
        final hasAttention = overdue.isNotEmpty || upcoming.isNotEmpty || suspended3m.isNotEmpty || archived1y.isNotEmpty || awaiting.isNotEmpty;

        final kpis = <Widget>[
          _Kpi('Awaiting verification', d['awaiting'], HPTone.pending, Icons.mark_email_unread_outlined, () => c.go('/restaurants?status=pending')),
          _Kpi('Active', d['active'], HPTone.success, Icons.storefront_outlined, () => c.go('/restaurants?status=active')),
          _Kpi('Suspended', d['suspended'], HPTone.saffron, Icons.pause_circle_outline, () => c.go('/restaurants?status=suspended')),
          _Kpi('Blocked', d['blocked'], HPTone.danger, Icons.block, () => c.go('/restaurants?status=blocked')),
          _Kpi('Attention needed', overdue.length + upcoming.length + suspended3m.length + archived1y.length, (overdue.isNotEmpty || suspended3m.isNotEmpty) ? HPTone.danger : HPTone.pending, Icons.notification_important_outlined, () => c.go('/restaurants')),
          _Kpi('Monthly revenue', formatPaise(mrr).replaceAll('.00', ''), HPTone.success, Icons.currency_rupee_rounded, () => c.go('/plans')),
        ];

        Widget section(String title, Widget child, {List<Widget> actions = const []}) => SectionCard(title: title, actions: actions, child: child);

        final attentionSection = section(
          'Needs your attention',
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!hasAttention)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('All clear — no licenses overdue or expiring, and no restaurants requiring lifecycle review.', style: HPType.body(p.muted)),
              ),
            for (final r in overdue.take(3))
              _AttentionRow(
                icon: Icons.money_off_rounded,
                tone: HPTone.danger,
                title: '${r['name']} (${r['code']})',
                subtitle: 'License overdue by ${r['daysOverdue']} days · Plan: ${r['plan']}',
                onTap: () => c.go('/restaurants/${r['id']}'),
              ),
            for (final r in upcoming.take(3))
              _AttentionRow(
                icon: Icons.schedule_rounded,
                tone: HPTone.saffron,
                title: '${r['name']} (${r['code']})',
                subtitle: 'Payment / license renewal in ${r['daysLeft']} days · Plan: ${r['plan']}',
                onTap: () => c.go('/restaurants/${r['id']}'),
              ),
            for (final r in suspended3m.take(3))
              _AttentionRow(
                icon: Icons.pause_circle_outline,
                tone: HPTone.danger,
                title: '${r['name']} (${r['code']})',
                subtitle: 'Suspended > 3 months (${r['daysSuspended']}d) · ${r['reason'] ?? 'No reason recorded'}',
                onTap: () => c.go('/restaurants/${r['id']}'),
              ),
            for (final r in archived1y.take(3))
              _AttentionRow(
                icon: Icons.archive_outlined,
                tone: HPTone.pending,
                title: '${r['name']} (${r['code']})',
                subtitle: 'Archived > 1 year (${r['daysArchived']}d) · Eligible for housekeeping removal',
                onTap: () => c.go('/restaurants/${r['id']}'),
              ),
            for (final r in awaiting.take(3))
              _AttentionRow(
                icon: Icons.mark_email_unread_outlined,
                tone: HPTone.pending,
                title: '${r['restaurantName']}',
                subtitle: 'Owner has not activated yet · ${r['ownerEmail']}',
                onTap: () => c.go('/restaurants?status=pending'),
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
                  SizedBox(width: 120, child: Text('${formatPaise(pl['pricePaise'] as int).replaceAll('.00', '')}/mo · ${formatPaise(pl['yearlyPricePaise'] as int? ?? (pl['pricePaise'] as int) * 10).replaceAll('.00', '')}/yr', textAlign: TextAlign.right, style: HPType.body(p.muted).copyWith(fontSize: 12))),
                ]),
              ),
          ]),
          actions: [TextButton(onPressed: () => c.go('/plans'), child: const Text('Plans'))],
        );

        final activity = section(
          'Recent activity',
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final (cat, label) in const [
                      (null, 'All'),
                      ('account_lifecycle', 'Account Lifecycle'),
                      ('auth_success', 'Auth Success'),
                      ('auth_failure', 'Auth Failures'),
                      ('restaurant_lifecycle', 'Restaurant Lifecycle'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(label),
                          selected: _activityCategory == cat,
                          onSelected: (_) => setState(() => _activityCategory = cat),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ]),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(6)),
                child: Text('Retention: 1.5 yrs', style: HPType.mono(p.muted).copyWith(fontSize: 11)),
              ),
            ]),
            const SizedBox(height: HPSpace.sm),
            if ((d['audit'] as List).isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('No activity recorded in this category yet.', style: HPType.body(p.muted)),
              )
            else
              Column(children: [for (final e in (d['audit'] as List).take(8)) _AuditRow(e as Map<String, dynamic>)]),
          ]),
          actions: [TextButton(onPressed: () => c.go('/audit'), child: const Text('Audit log'))],
        );

        return RefreshIndicator(
          onRefresh: () async => reload(),
          child: PageFrame(
            title: 'Dashboard',
            subtitle: 'Your restaurants and platform status at a glance',
            actions: [IconButton(tooltip: 'Refresh', onPressed: reload, icon: const Icon(Icons.refresh_rounded))],
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              LayoutBuilder(builder: (c2, box) {
                final cols = box.maxWidth < 560 ? 2 : 3;
                const gap = HPSpace.md;
                final w = (box.maxWidth - gap * (cols - 1)) / cols;
                return Wrap(spacing: gap, runSpacing: gap, children: [for (final k in kpis) SizedBox(width: w, child: k)]);
              }),
              const SizedBox(height: HPSpace.lg),
              if (narrow) ...[attentionSection, const SizedBox(height: HPSpace.lg), planMix, const SizedBox(height: HPSpace.lg), activity]
              else
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 3, child: Column(children: [attentionSection, const SizedBox(height: HPSpace.lg), activity])),
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
    return Card(
      key: Key('kpi-$label'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: p.tone(tone).withValues(alpha: .14), borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 18, color: p.tone(tone)),
            ),
            const SizedBox(width: HPSpace.sm),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text('${value ?? 0}', style: HPType.titleCard(p.text).copyWith(fontSize: 21, fontWeight: FontWeight.w700)),
                ),
                Text(label, style: HPType.body(p.muted).copyWith(fontSize: 11.5), maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, size: 16, color: p.faint),
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
              if (await showDialog<bool>(barrierDismissible: false, context: context, builder: (_) => const RegisterRestaurantDialog()) == true) {
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
          _Drop(label: 'Status', value: _status == 'pending' ? null : _status, items: const ['active', 'suspended', 'blocked', 'archived'], onChanged: (v) {
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
  final _c = {for (final k in ['ownerEmail', 'ownerName', 'restaurantName', 'gstin', 'address', 'password']) k: TextEditingController()};
  String _plan = 'standard';
  String _cycle = 'monthly'; // every plan is priced in this cycle, and the first license runs for it
  bool _busy = false, _showPassword = false;
  static final _gstin = RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$');

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final pwd = _c['password']!.text.trim();
      final r = await ref.read(apiProvider).registerRestaurant({
        'ownerEmail': _c['ownerEmail']!.text.trim(),
        'ownerName': _c['ownerName']!.text.trim(),
        'restaurantName': _c['restaurantName']!.text.trim(),
        if (_c['gstin']!.text.trim().isNotEmpty) 'gstin': _c['gstin']!.text.trim().toUpperCase(),
        if (_c['address']!.text.trim().isNotEmpty) 'address': _c['address']!.text.trim(),
        'planCode': _plan,
        'billingCycle': _cycle,
        if (pwd.isNotEmpty) 'password': pwd,
      });
      if (!mounted) return;
      if (r['status'] == 'active') {
        showDone(context, 'Restaurant ${r['restaurantCode'] ?? ''} created & activated! Owner can sign in immediately.');
        Navigator.pop(context, true);
        return;
      }
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
  Widget build(BuildContext context) {
    final hasPassword = _c['password']!.text.trim().isNotEmpty;
    return HPDialog(
      title: 'Register restaurant',
      actions: [
        SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(context)),
        PrimaryButton(label: hasPassword ? 'Create & activate' : 'Send verification', height: 56, busy: _busy, onPressed: _submit),
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
          TextFormField(
            key: const Key('register-password'),
            controller: _c['password'],
            obscureText: !_showPassword,
            decoration: InputDecoration(
              labelText: 'Owner password (optional)',
              helperText: 'Set now to activate immediately without email verification',
              suffixIcon: IconButton(
                key: const Key('register-show-password'),
                tooltip: _showPassword ? 'Hide password' : 'Show password',
                icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
            ),
            validator: (v) => (v != null && v.isNotEmpty && v.length < 8) ? 'Minimum 8 characters' : null,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: HPSpace.md),
          TextFormField(controller: _c['gstin'], decoration: const InputDecoration(labelText: 'GSTIN (optional)'),
              validator: (v) => (v ?? '').trim().isEmpty || _gstin.hasMatch(v!.trim().toUpperCase()) ? null : 'Not a valid GSTIN'),
          const SizedBox(height: HPSpace.md),
          TextFormField(controller: _c['address'], decoration: const InputDecoration(labelText: 'Address (optional)')),
          const SizedBox(height: HPSpace.md),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              key: const Key('register-cycle'),
              showSelectedIcon: false,
              segments: const [ButtonSegment(value: 'monthly', label: Text('Pay monthly')), ButtonSegment(value: 'yearly', label: Text('Pay yearly'))],
              selected: {_cycle},
              onSelectionChanged: (v) => setState(() => _cycle = v.first),
            ),
          ),
          const SizedBox(height: HPSpace.md),
          Consumer(builder: (c, ref, _) {
            final plans = [...ref.watch(activePlansProvider).valueOrNull ?? const <Json>[]]
              ..sort((a, b) => ((a['tier'] as int?) ?? 999).compareTo((b['tier'] as int?) ?? 999));
            final codes = plans.map((p) => p['code'] as String).toList();
            if (!codes.contains(_plan) && codes.isNotEmpty) _plan = codes.first;
            // every option in the same cycle so the prices compare like for like
            String price(Json p) {
              final monthly = p['pricePaise'] as int;
              final paise = _cycle == 'yearly' ? (p['yearlyPricePaise'] as int? ?? monthly * 10) : monthly;
              return '${formatPaise(paise).replaceAll('.00', '')} / ${_cycle == 'yearly' ? 'year' : 'month'}';
            }
            return DropdownButtonFormField<String>(
              key: ValueKey('register-plan-$_cycle'),
              initialValue: codes.isEmpty ? null : _plan,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Plan'),
              items: [for (final p in plans) DropdownMenuItem(value: p['code'] as String, child: Text('${p['name']} · ${price(p)}'))],
              onChanged: (v) => setState(() => _plan = v!),
            );
          }),
        ]),
      ),
    );
  }
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
    final reason = await ReasonDialog.show(
      context,
      title: '${action[0].toUpperCase()}${action.substring(1)} restaurant',
      confirmLabel: action[0].toUpperCase() + action.substring(1),
      message: action == 'suspend'
          ? 'In suspend, all restaurant logs and data remain on the system. The owner and staff become read-only.'
          : 'The owner and staff are affected immediately. Suspended and blocked restaurants become read-only.',
      destructive: action == 'suspend' || action == 'block',
    );
    if (reason == null || !mounted) return;
    try {
      await ref.read(apiProvider).setStatus(widget.id, action, reason);
      if (mounted) showDone(context, 'Restaurant ${action}d');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _archive() async {
    final reason = await ReasonDialog.show(
      context,
      title: 'Archive restaurant to cold storage?',
      confirmLabel: 'Archive to Cold Storage',
      message: 'All restaurant logs, menu, orders, staff, licenses and tenant data will be bundled into a compressed archive (.json.gz) with SHA-256 integrity verification. The restaurant status transitions to Archived.',
      destructive: true,
    );
    if (reason == null || !mounted) return;
    try {
      await ref.read(apiProvider).archiveRestaurant(widget.id, reason);
      if (mounted) showDone(context, 'Restaurant archived to cold storage');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _downloadArchive(String code) async {
    try {
      final bytes = await ref.read(apiProvider).downloadArchive(widget.id);
      await saveFile('restaurant-$code-archive.json.gz', bytes, 'application/gzip');
      if (mounted) showDone(context, 'Cold storage archive downloaded (.json.gz)');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _restore() async {
    final reason = await ReasonDialog.show(
      context,
      title: 'Restore restaurant from cold storage?',
      confirmLabel: 'Restore to Suspended',
      message: 'Integrity checksums will be verified, cold storage logs restored, and the restaurant moved to Suspended status (Archived -> Suspend -> Active). From Suspended you can review and reactivate.',
    );
    if (reason == null || !mounted) return;
    try {
      await ref.read(apiProvider).restoreRestaurant(widget.id, reason);
      if (mounted) showDone(context, 'Restaurant restored to Suspended status');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deleteRestaurant() async {
    final reason = await ReasonDialog.show(
      context,
      title: 'Permanently delete restaurant?',
      confirmLabel: 'Delete Restaurant',
      message: 'Housekeeping deletion is only permitted for archived restaurants. The restaurant tenant will be marked deleted and all credentials revoked, with a permanent audit record preserved.',
      destructive: true,
    );
    if (reason == null || !mounted) return;
    try {
      await ref.read(apiProvider).deleteRestaurant(widget.id, reason);
      if (mounted) {
        showDone(context, 'Restaurant deleted');
        context.go('/restaurants');
      }
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
                trailing: Text('${formatPaise(p['pricePaise'] as int).replaceAll('.00', '')}/mo · ${formatPaise(p['yearlyPricePaise'] as int? ?? (p['pricePaise'] as int) * 10).replaceAll('.00', '')}/yr'),
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
      barrierDismissible: false,
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
        // what this restaurant actually pays: the license's own cycle and amount, not the plan's default cycle
        final yearly = (lic?['billingCycle'] ?? plan?['billingCycle']) == 'yearly';
        final paidPaise = lic?['amountPaise'] as int? ?? (plan == null ? null : (yearly ? plan['yearlyPricePaise'] as int? ?? (plan['pricePaise'] as int) * 10 : plan['pricePaise'] as int));
        final priceText = paidPaise == null ? null : '${formatPaise(paidPaise).replaceAll('.00', '')} / ${yearly ? 'year' : 'month'}';
        final ends = DateTime.tryParse('${lic?['endsAt'] ?? ''}');
        final daysLeft = ends?.difference(DateTime.now()).inDays;
        final devices = (r['devices'] as List).cast<Map<String, dynamic>>();
        final hub = devices.where((d) => d['isHub'] == true && d['revokedAt'] == null).firstOrNull;
        final features = (ent['features'] as List? ?? const []).cast<String>();
        final archivesList = (r['archives'] as List? ?? const []).cast<Map<String, dynamic>>();

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
              if (status == 'suspended') btn(SecondaryButton(label: 'Archive to cold storage', icon: Icons.archive_outlined, height: 44, onPressed: _archive)),
              if (status == 'archived') btn(SecondaryButton(label: 'Download cold storage (.json.gz)', icon: Icons.download_rounded, height: 44, onPressed: () => _downloadArchive('${r['code']}'))),
              if (status == 'archived') btn(SecondaryButton(label: 'Restore to Suspended', icon: Icons.restore_page_outlined, height: 44, onPressed: _restore)),
              if (status == 'archived') btn(DangerButton(label: 'Delete (Housekeeping)', icon: Icons.delete_forever_outlined, height: 44, onPressed: _deleteRestaurant)),
              if (status == 'active' || status == 'suspended') btn(DangerButton(label: 'Block', icon: Icons.block, height: 44, onPressed: () => _status('block'))),
            ]),
          ],
        ]));
        final license = SectionCard(title: 'License', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (lic == null)
            Text('No active license — the restaurant is read-only until one is issued.', style: HPType.body(p.muted))
          else ...[
            _kv('Plan', '$planName${priceText == null ? '' : ' · $priceText'}'),
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
        final coldStorageCard = SectionCard(
          title: 'Cold Storage & Archives',
          child: archivesList.isEmpty
              ? Text('No cold storage archives created yet. When suspended, archiving bundles logs to S3 cold storage format.', style: HPType.body(p.muted))
              : Column(children: [
                  for (final arc in archivesList)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.archive_outlined, color: p.pending),
                      title: Text('Archive · ${((arc['sizeBytes'] as int? ?? 0) / 1024).toStringAsFixed(1)} KB', style: HPType.label(p.text)),
                      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('SHA-256: ${(arc['sha256'] as String? ?? '').substring(0, 16)}… · Created ${shortDate(arc['createdAt'])}', style: HPType.mono(p.muted).copyWith(fontSize: 12)),
                        if (arc['counts'] != null)
                          Text('${(arc['counts'] as Map)['users'] ?? 0} users · ${(arc['counts'] as Map)['auditEvents'] ?? 0} audit logs · ${(arc['counts'] as Map)['branches'] ?? 0} branches', style: HPType.body(p.muted).copyWith(fontSize: 12)),
                        if (arc['restoredAt'] != null)
                          Text('Restored on ${shortDate(arc['restoredAt'])}', style: HPType.mono(p.success).copyWith(fontSize: 11)),
                      ]),
                      trailing: Wrap(spacing: HPSpace.sm, children: [
                        IconButton(tooltip: 'Download .json.gz for S3 Archive', icon: const Icon(Icons.download_rounded), onPressed: () => _downloadArchive('${r['code']}')),
                        if (status == 'archived') TextButton.icon(icon: const Icon(Icons.restore_page_outlined, size: 16), label: const Text('Restore'), onPressed: _restore),
                      ]),
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
        // archives only matter once a restaurant is suspended or has been archived
        final showCold = archivesList.isNotEmpty || status == 'suspended' || status == 'archived';
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
          const SizedBox(height: HPSpace.md),
          _LifecyclePipeline(status: status),
          const SizedBox(height: HPSpace.lg),
          LayoutBuilder(builder: (c2, box) {
            final cols = narrow ? 2 : 4;
            final w = (box.maxWidth - HPSpace.lg * (cols - 1)) / cols;
            return Wrap(spacing: HPSpace.lg, runSpacing: HPSpace.lg, children: [
              SizedBox(width: w, child: KpiCard(label: 'Plan', value: planName, caption: priceText, icon: Icons.workspace_premium_outlined, tone: HPTone.saffron)),
              SizedBox(width: w, child: KpiCard(label: 'License ends', value: ends == null ? '—' : shortDate(lic?['endsAt']), caption: daysLeft == null ? null : (daysLeft >= 0 ? '$daysLeft days left' : 'ended'), icon: Icons.event_outlined, tone: daysLeft != null && daysLeft < 7 ? HPTone.danger : HPTone.success)),
              SizedBox(width: w, child: KpiCard(label: 'Branches', value: '${(r['branches'] as List).length}', icon: Icons.storefront_outlined)),
              SizedBox(width: w, child: KpiCard(label: 'Devices', value: '${devices.where((d) => d['revokedAt'] == null).length}', caption: hub == null ? 'No hub yet' : 'Hub: ${hub['name']}', icon: Icons.router_outlined, tone: hub == null ? HPTone.neutral : HPTone.success)),
            ]);
          }),
          const SizedBox(height: HPSpace.lg),
          if (narrow) ...[profile, gap, license, gap, payments, gap, branches, if (showCold) ...[gap, coldStorageCard]]
          else ...[
            // paired cards share a row and a height, so a new restaurant's short cards leave no ragged gaps
            IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: profile), gap, Expanded(child: license)])),
            gap,
            IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: payments), gap, Expanded(child: branches)])),
            if (showCold) ...[gap, coldStorageCard],
          ],
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

class _LifecyclePipeline extends StatelessWidget {
  const _LifecyclePipeline({required this.status});
  final String status;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final steps = const [
      ('pending', 'Create', 'Pending owner verification'),
      ('active', 'Active', 'Operational & licensed'),
      ('suspended', 'Suspended', 'Paused · Logs remain on system'),
      ('archived', 'Archived', 'Cold storage · Downloadable bundle'),
      ('deleted', 'Delete', 'Housekeeping removal'),
    ];
    final currentIdx = steps.indexWhere((s) => s.$1 == status);
    final isBlocked = status == 'blocked';

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: HPSpace.md, vertical: HPSpace.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: HPSpace.sm, runSpacing: HPSpace.xs, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.timeline_rounded, size: 16, color: p.muted),
              const SizedBox(width: 6),
              Text('RESTAURANT LIFECYCLE', style: HPType.overline(p.muted)),
            ]),
            Text(
              isBlocked ? 'Status: Blocked' : 'Order: Create ➔ Active ⇆ Suspend ⇆ Archived ➔ Delete',
              style: HPType.mono(p.muted).copyWith(fontSize: 10.5),
            ),
          ]),
          const SizedBox(height: HPSpace.sm),
          LayoutBuilder(builder: (context, box) {
            // wide: the steps share the full card width; narrow: they scroll sideways
            final fill = box.maxWidth >= 760;
            final row = Row(children: [
              for (var i = 0; i < steps.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Icon((i == 2 || i == 3) ? Icons.sync_alt_rounded : Icons.arrow_forward_rounded, size: 16, color: p.faint),
                  ),
                if (fill) Expanded(child: _step(steps, i, currentIdx, isBlocked)) else _step(steps, i, currentIdx, isBlocked),
              ],
            ]);
            return fill ? row : SingleChildScrollView(scrollDirection: Axis.horizontal, child: row);
          }),
        ]),
      ),
    );
  }

  Widget _step(List<(String, String, String)> steps, int i, int currentIdx, bool isBlocked) => _StepChip(
        label: steps[i].$2,
        caption: steps[i].$3,
        isCurrent: !isBlocked && (steps[i].$1 == status || (status == 'pending' && i == 0)),
        isPast: !isBlocked && currentIdx > i,
        tone: status == 'suspended' && steps[i].$1 == 'suspended'
            ? HPTone.saffron
            : status == 'archived' && steps[i].$1 == 'archived'
                ? HPTone.pending
                : status == 'deleted' && steps[i].$1 == 'deleted'
                    ? HPTone.danger
                    : HPTone.success,
      );
}

class _StepChip extends StatelessWidget {
  const _StepChip({required this.label, required this.caption, required this.isCurrent, required this.isPast, required this.tone});
  final String label;
  final String caption;
  final bool isCurrent;
  final bool isPast;
  final HPTone tone;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final color = isCurrent ? p.tone(tone) : isPast ? p.success : p.faint;
    final bg = isCurrent ? p.tone(tone).withValues(alpha: .12) : isPast ? p.success.withValues(alpha: .08) : p.raised;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8), border: Border.all(color: isCurrent ? color : Colors.transparent, width: 1.5)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(isCurrent ? Icons.radio_button_checked : isPast ? Icons.check_circle_rounded : Icons.radio_button_unchecked, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: HPType.label(isCurrent ? p.text : isPast ? p.text : p.muted).copyWith(fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal))),
        ]),
        const SizedBox(height: 2),
        Text(caption, maxLines: 1, overflow: TextOverflow.ellipsis, style: HPType.mono(p.muted).copyWith(fontSize: 10)),
      ]),
    );
  }
}

/// P11 audit list (shared by the audit viewer and the restaurant detail page): what happened, who did it, when,
/// why — tap a row to see exactly what changed.
class AuditList extends ConsumerStatefulWidget {
  const AuditList({super.key, this.tenantId, this.action, this.category, this.q, this.embedded = false, this.limit});
  final String? tenantId;
  final String? action;
  final String? category;
  final String? q;

  /// Inside another page: no own scrolling, shows the latest events.
  final bool embedded;

  /// How many events to show (default: 12 embedded, all otherwise).
  final int? limit;
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
    // lists of records (roles, dish sizes): their names, e.g. "Onboarding Admin, Platform Auditor"
    if (v is List) return v.isEmpty ? 'none' : _short(v.map((x) => x is Map ? (x['name'] ?? x['code'] ?? x) : x).join(', '));
    final s = v is String ? v : '$v';
    return s.length > 60 ? '${s.substring(0, 57)}…' : s;
  }

  /// Field-by-field changes ("Status: active → suspended"); for creations just the new values.
  static List<(String, String)> _changes(Map<String, dynamic> e) {
    // before/after are free-form JSON: anything that is not an object (list, text, number) shows as one value
    Map<String, dynamic> asMap(Object? v) => v is Map ? v.cast<String, dynamic>() : v == null ? const {} : {e['action'] == 'platform.admin.roles_changed' ? 'roles' : 'value': v};
    final before = asMap(e['before']);
    final after = asMap(e['after']);
    const hidden = {'id', 'tenantId', 'branchId', 'seq', 'createdAt', 'updatedAt', 'signedToken', 'passwordHash', 'pinHash', 'tokenHash', 'deleted'};
    final keys = {...before.keys, ...after.keys}.where((k) => !hidden.contains(k)).toList();
    return [
      for (final k in keys)
        if ('${before[k]}' != '${after[k]}' || before.isEmpty)
          (titleCase(k.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}').toLowerCase()), before.isEmpty || !before.containsKey(k) ? _short(after[k]) : '${_short(before[k])} → ${_short(after[k])}'),
    ];
  }

  static List<(String, String)> _safeChanges(Map<String, dynamic> e) {
    try {
      return _changes(e);
    } catch (_) {
      return const []; // one malformed record must not blank the whole log
    }
  }

  @override
  Widget build(BuildContext context) => AsyncView<Map<String, dynamic>>(
        key: ValueKey('${widget.tenantId}|${widget.action}|${widget.category}|${widget.q}'),
        load: () => ref.read(apiProvider).audit(tenantId: widget.tenantId, action: widget.action, category: widget.category, q: widget.q),
        isEmpty: (d) => (d['items'] as List).isEmpty,
        emptyTitle: 'No history yet',
        builder: (c, d, _) {
          final p = context.hp;
          final items = (d['items'] as List).whereType<Map>().map((m) => m.cast<String, dynamic>()).take(widget.limit ?? (widget.embedded ? 12 : 1000)).toList();
          final tiles = [
            for (final e in items)
              for (final changes in [_safeChanges(e)])
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
                    for (final (k, v) in changes)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          SizedBox(width: 160, child: Text(k, style: HPType.body(p.muted))),
                          Expanded(child: SelectableText(v, style: HPType.body(p.text))),
                        ]),
                      ),
                    if (changes.isEmpty) Text('No field changes recorded.', style: HPType.body(p.faint)),
                    if (e['ip'] != null) Text('From ${e['ip']}', style: HPType.body(p.faint).copyWith(fontSize: 12)),
                  ],
                ),
              ),
          ];
          // right inset keeps the web scrollbar off the expand arrows
          return widget.embedded ? Column(children: tiles) : ListView(padding: const EdgeInsets.only(right: HPSpace.md), children: tiles);
        },
      );
}

/// P11 audit viewer with granular category filters, restaurant selector, and 1.5 year retention policy.
class AuditScreen extends ConsumerStatefulWidget {
  const AuditScreen({super.key});
  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<AuditScreen> {
  final _action = TextEditingController(), _search = TextEditingController();
  String? _category; // null = all, 'account_lifecycle', 'account_creation', 'account_deletion', 'mfa_reset', 'authentication', 'auth_success', 'auth_failure', 'restaurant_lifecycle'
  String? _a, _q; // applied text filters (Filter button or Enter)

  void _applyText() => setState(() => (_a = _action.text.trim(), _q = _search.text.trim()));

  void _clear() => setState(() {
        _category = _a = _q = _selectedRestaurantId = null;
        _action.clear();
        _search.clear();
      });

  @override
  void dispose() {
    _action.dispose();
    _search.dispose();
    super.dispose();
  }
  List<Json>? _restaurants;
  String? _selectedRestaurantId;

  @override
  void initState() {
    super.initState();
    _loadRestaurants();
  }

  Future<void> _loadRestaurants() async {
    try {
      final res = await ref.read(apiProvider).restaurants();
      if (!mounted) return;
      setState(() {
        _restaurants = (res['items'] as List?)?.cast<Json>() ?? [];
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final narrow = isNarrowWeb(context);
    final filters = <Widget>[
        Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: HPSpace.sm, runSpacing: HPSpace.xs, children: [
          Text('Audit log', style: Theme.of(context).textTheme.headlineMedium),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.faint.withValues(alpha: .3))),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.shield_outlined, size: 16, color: p.muted),
                const SizedBox(width: 6),
                Text('Retention: 1.5 Years (548 days)', style: HPType.mono(p.muted).copyWith(fontSize: 12)),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: HPSpace.md),
        // chips wrap onto a second line instead of scrolling sideways under a scrollbar
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (cat, label) in const [
            (null, 'All activity'),
            ('account_lifecycle', 'Account lifecycle'),
            ('account_creation', 'Account creation'),
            ('account_deletion', 'Account deletion'),
            ('mfa_reset', 'MFA reset'),
            ('authentication', 'Authentication (all)'),
            ('auth_success', 'Auth success'),
            ('auth_failure', 'Auth failure'),
            ('restaurant_lifecycle', 'Restaurant lifecycle'),
          ])
            ChoiceChip(
              key: Key('audit-cat-${cat ?? 'all'}'),
              label: Text(label),
              selected: _category == cat,
              // a category narrows what the other filters already show; "All activity" drops only the category
              onSelected: (_) => setState(() => _category = cat),
            ),
        ]),
        const SizedBox(height: HPSpace.lg),
        Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: isNarrowWeb(context) ? double.infinity : 220, child: TextField(key: const Key('audit-search'), controller: _search, decoration: const InputDecoration(labelText: 'Search text / reason', prefixIcon: Icon(Icons.search)), onSubmitted: (_) => _applyText())),
          SizedBox(width: isNarrowWeb(context) ? double.infinity : 180, child: TextField(key: const Key('audit-action'), controller: _action, decoration: const InputDecoration(labelText: 'Action contains'), onSubmitted: (_) => _applyText())),
          SizedBox(
            width: isNarrowWeb(context) ? double.infinity : 260,
            child: DropdownButtonFormField<String?>(
              // keyed by the selection so clearing it from outside resets what the field shows
              key: ValueKey('audit-restaurant-filter-$_selectedRestaurantId-${_restaurants?.length}'),
              isExpanded: true,
              initialValue: _selectedRestaurantId,
              decoration: const InputDecoration(labelText: 'Restaurant', prefixIcon: Icon(Icons.storefront_outlined)),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('All restaurants', overflow: TextOverflow.ellipsis)),
                if (_restaurants != null)
                  for (final r in _restaurants!)
                    DropdownMenuItem<String?>(
                      value: r['id'] as String,
                      child: Text('${r['name']} (${r['code']})', overflow: TextOverflow.ellipsis),
                    ),
              ],
              onChanged: (v) => setState(() => _selectedRestaurantId = v),
            ),
          ),
          SecondaryButton(key: const Key('audit-filter'), label: 'Filter', icon: Icons.filter_alt_outlined, height: 48, onPressed: _applyText),
          if (_category != null || _selectedRestaurantId != null || (_q ?? '').isNotEmpty || (_a ?? '').isNotEmpty)
            TextButton.icon(key: const Key('audit-clear'), onPressed: _clear, icon: const Icon(Icons.clear_rounded, size: 18), label: const Text('Clear filters')),
        ]),
        const SizedBox(height: HPSpace.lg),
    ];
    // phones: filters and events scroll together, so the filters never squeeze the list off screen
    final list = Card(child: Padding(padding: const EdgeInsets.all(HPSpace.lg), child: AuditList(category: _category, action: _a, tenantId: _selectedRestaurantId, q: _q, embedded: narrow, limit: narrow ? 200 : null)));
    return Padding(
      padding: EdgeInsets.all(narrow ? HPSpace.lg : HPSpace.x4),
      child: narrow
          ? ListView(children: [...filters, list])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...filters, Expanded(child: list)]),
    );
  }
}

/// P8 Plans (feature flags + limits).
/// Shown when the email provider refused the message: the Super Admin passes the link on another way.
Future<void> showActivationLinkDialog(BuildContext context, Map<String, dynamic> r) => showDialog<void>(
      barrierDismissible: false,
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

  Future<void> _activate(Map<String, dynamic> r) async {
    final password = TextEditingController();
    final ok = await showDialog<bool>(barrierDismissible: false, context: context, builder: (d) => HPDialog(title: 'Activate ${r['restaurantName']}', actions: [SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(d)), PrimaryButton(label: 'Activate', onPressed: () { if (password.text.length >= 12) Navigator.pop(d, true); })], child: TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Owner password', helperText: 'At least 12 characters. No email required.'))));
    if (ok != true) { password.dispose(); return; }
    try { await ref.read(apiProvider).activateRegistration(r['id'] as String, password.text); if (mounted) { setState(() => _reload++); showDone(context, 'Restaurant active. Owner can sign in with email and password.'); } } catch (e) { if (mounted) showError(context, e); } finally { password.dispose(); }
  }

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
                          TextButton.icon(onPressed: () => _activate(r), icon: const Icon(Icons.check_circle_outline), label: const Text('Activate without email')),
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
