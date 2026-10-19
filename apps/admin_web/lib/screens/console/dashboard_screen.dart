import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

String rupees(int paise) {
  final s = formatPaise(paise);
  return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
}

String _hourLabel(int h) => '${h % 12 == 0 ? 12 : h % 12} ${h < 12 ? 'AM' : 'PM'}';

String _clock(Object? iso) {
  final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  if (t == null) return '—';
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '${t.day}/${t.month} $h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// O1 Restaurant dashboard: setup checklist, what is happening right now, sales for the chosen range against the
/// previous one, when and how guests pay, what sells, who sells, what was reversed, and every recent bill.
class RestaurantDashboardScreen extends ConsumerStatefulWidget {
  const RestaurantDashboardScreen({super.key});
  @override
  ConsumerState<RestaurantDashboardScreen> createState() => _RestaurantDashboardScreenState();
}

class _RestaurantDashboardScreenState extends ConsumerState<RestaurantDashboardScreen> {
  String _range = 'today';
  int _reload = 0;

  @override
  Widget build(BuildContext context) {
    final api = ref.read(apiProvider);
    final me = ref.watch(authProvider);
    final canReports = me is SignedIn && me.can('reports.read');
    return AsyncView<(Json, Json?)>(
      key: ValueKey('$_range-$_reload'),
      load: () async => (await api.overview(), canReports ? await api.dashboard(range: _range) : null),
      builder: (c, data, reload) {
        final (o, d) = data;
        final r = o['restaurant'] as Json;
        final lic = o['license'] as Json;
        final narrow = isNarrowWeb(context);
        return RefreshIndicator(
          onRefresh: () async => setState(() => _reload++),
          child: PageFrame(
            title: '${r['name']}',
            subtitle: 'Good ${_partOfDay()} · ${lic['planName'] == null ? 'No active plan' : '${lic['planName']} plan${lic['endsAt'] == null ? '' : ' until ${shortDate(lic['endsAt'])}'}'}',
            actions: [
              StatusChip(label: _hubLabel(o['hub'] as Json?), tone: _hubTone(o['hub'] as Json?), icon: Icons.router_rounded),
              if (canReports)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width - 2 * HPSpace.lg),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: SegmentedButton<String>(
                      key: const Key('range'),
                      showSelectedIcon: false,
                      segments: const [ButtonSegment(value: 'today', label: Text('Today')), ButtonSegment(value: '7d', label: Text('7 days')), ButtonSegment(value: '30d', label: Text('30 days'))],
                      selected: {_range},
                      onSelectionChanged: (v) => setState(() => _range = v.first),
                    ),
                  ),
                ),
              IconButton(tooltip: 'Refresh', onPressed: () => setState(() => _reload++), icon: const Icon(Icons.refresh_rounded)),
            ],
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (lic['state'] == 'none') ...[
                Card(
                  key: const Key('dashboard-no-plan'),
                  color: HPColors.amber.withValues(alpha: .12),
                  child: ListTile(
                    leading: const Icon(Icons.lock_outline_rounded),
                    title: const Text('Your restaurant has no active plan'),
                    subtitle: const Text('Menu, floors & tables, staff and the POS are locked until House Plating issues or renews your plan.'),
                  ),
                ),
                const SizedBox(height: HPSpace.lg),
              ],
              _Checklist(counts: o['counts'] as Json, hub: o['hub'] as Json?),
              if (d != null) ..._report(context, d, narrow),
            ]),
          ),
        );
      },
    );
  }

  String get _rangeWord => switch (_range) { 'today' => 'today', '30d' => '30 days', _ => '7 days' };
  String get _prevWord => switch (_range) { 'today' => 'yesterday', '30d' => 'previous 30 days', _ => 'previous 7 days' };

  List<Widget> _report(BuildContext context, Json d, bool narrow) {
    final k = d['kpis'] as Json;
    final change = d['change'] as Json;
    final live = d['live'] as Json;
    const gap = SizedBox(height: HPSpace.lg, width: HPSpace.lg);
    Widget row(List<(int, Widget)> parts) => narrow
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final (i, p) in parts.indexed) ...[if (i > 0) gap, p.$2]])
        : IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final (i, p) in parts.indexed) ...[if (i > 0) gap, Expanded(flex: p.$1, child: p.$2)]]));
    return [
      const SizedBox(height: HPSpace.lg),
      _LiveStrip(live: live),
      const SizedBox(height: HPSpace.lg),
      _grid(narrow ? 2 : 4, [
        KpiCard(key: const Key('kpi-sales'), label: 'Sales · $_rangeWord', value: rupees(k['salesPaise'] as int), caption: _delta(change['salesPct'], _prevWord, (d['previous'] as Json)['salesPaise'] as int), icon: Icons.currency_rupee_rounded, tone: HPTone.saffron),
        KpiCard(label: 'Bills', value: '${k['bills']}', caption: _deltaCount(change['billsPct'], _prevWord), icon: Icons.receipt_long_rounded),
        KpiCard(label: 'Average bill', value: rupees(k['avgBillPaise'] as int), caption: '${k['orders']} orders opened', icon: Icons.analytics_outlined, tone: HPTone.success),
        KpiCard(label: 'Tips', value: rupees(k['tipsPaise'] as int), caption: 'GST collected ${rupees(k['taxesPaise'] as int)}', icon: Icons.volunteer_activism_rounded, tone: HPTone.pending),
      ]),
      const SizedBox(height: HPSpace.lg),
      row([
        (3, SectionCard(
          title: _range == 'today' ? 'Sales by hour · today' : 'Sales by day · $_rangeWord',
          actions: [if (d['busiestHour'] != null) StatusChip(label: 'Busiest ${_hourLabel(d['busiestHour'] as int)}', icon: Icons.local_fire_department_outlined, tone: HPTone.saffron)],
          child: _range == 'today' ? _Bars.hourly((d['hourly'] as List).cast<Json>()) : _Bars.daily((d['series'] as List).cast<Json>()),
        )),
        (2, SectionCard(title: 'How guests paid', child: _Modes(byMode: (d['byMode'] as Json).cast<String, dynamic>()))),
      ]),
      const SizedBox(height: HPSpace.lg),
      row([
        (1, SectionCard(title: 'Dine-in vs takeaway', child: _Split(k: k))),
        (1, SectionCard(title: 'Sales by category', child: _Categories(cats: (d['byCategory'] as List).cast<Json>()))),
        (1, SectionCard(title: 'Discounts, reversals, corrections', child: _Leakage(k: k, reasons: ((d['reversals'] as Json)['reasons'] as List).cast<Json>()))),
      ]),
      const SizedBox(height: HPSpace.lg),
      row([
        (3, SectionCard(title: 'Top dishes · $_rangeWord', child: _TopDishes(items: (d['topItems'] as List).cast<Json>()))),
        (2, SectionCard(title: 'Staff performance', child: _Staff(rows: (d['byWaiter'] as List).cast<Json>()))),
      ]),
      const SizedBox(height: HPSpace.lg),
      SectionCard(title: 'Recent bills', child: _RecentBills(bills: (d['recentBills'] as List).cast<Json>())),
    ];
  }

  static String _delta(Object? pct, String prevWord, int prevPaise) {
    if (pct == null) return prevPaise == 0 ? 'nothing $prevWord to compare' : '';
    final v = pct as num;
    return '${v >= 0 ? '▲' : '▼'} ${v.abs()}% vs $prevWord (${rupees(prevPaise)})';
  }

  static String _deltaCount(Object? pct, String prevWord) {
    if (pct == null) return 'vs $prevWord: —';
    final v = pct as num;
    return '${v >= 0 ? '▲' : '▼'} ${v.abs()}% vs $prevWord';
  }

  static Widget _grid(int cols, List<Widget> children) => LayoutBuilder(builder: (c, box) {
        const gap = HPSpace.lg;
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(spacing: gap, runSpacing: gap, children: [for (final ch in children) SizedBox(width: w, child: ch)]);
      });

  static String _partOfDay() {
    final h = DateTime.now().hour;
    return h < 12 ? 'morning' : h < 17 ? 'afternoon' : 'evening';
  }

  static String _hubLabel(Json? hub) => hub == null ? 'No hub yet' : (hub['online'] == true ? 'Hub online' : 'Hub offline');
  static HPTone _hubTone(Json? hub) => hub == null ? HPTone.neutral : (hub['online'] == true ? HPTone.success : HPTone.danger);
}

/// What is happening in the restaurant right now (from the hub's latest sync).
class _LiveStrip extends StatelessWidget {
  const _LiveStrip({required this.live});
  final Json live;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    Widget fact(IconData icon, String value, String label, Color c) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: HPSpace.md, vertical: HPSpace.sm),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: c, size: 22),
            const SizedBox(width: HPSpace.sm),
            Text(value, style: HPType.titleCard(p.text).copyWith(fontSize: 22)),
            const SizedBox(width: 6),
            Flexible(child: Text(label, style: HPType.body(p.muted), overflow: TextOverflow.ellipsis)),
          ]),
        );
    return Container(
      key: const Key('live-strip'),
      padding: const EdgeInsets.all(HPSpace.sm),
      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(HPRadius.card), border: Border.all(color: p.line)),
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HPSpace.md),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: p.success, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text('RIGHT NOW', style: HPType.overline(p.muted)),
          ]),
        ),
        fact(Icons.table_restaurant_rounded, '${live['openTables']}', 'tables seated', HPColors.saffron),
        fact(Icons.shopping_bag_outlined, '${live['takeaways']}', 'takeaways open', p.pending),
        fact(Icons.hourglass_bottom_rounded, '${live['unpaidBills']}', 'bills unpaid · ${rupees(live['unpaidPaise'] as int)}', p.danger),
      ]),
    );
  }
}

class _Bars extends StatelessWidget {
  const _Bars._(this.points);
  factory _Bars.daily(List<Json> days) {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final many = days.length > 10;
    return _Bars._([
      for (final (i, d) in days.indexed)
        (
          many ? (i % 5 == 0 || i == days.length - 1 ? '${DateTime.tryParse('${d['day']}')?.day ?? ''}' : '') : wd[(DateTime.tryParse('${d['day']}')?.weekday ?? 1) - 1],
          d['salesPaise'] as int,
          '${d['day']}: ${rupees(d['salesPaise'] as int)} · ${d['bills']} bills',
          i == days.length - 1,
        ),
    ]);
  }
  factory _Bars.hourly(List<Json> hours) {
    // show the service day (8 AM – midnight) plus any hour that actually had sales
    final shown = hours.where((h) => (h['hour'] as int) >= 8 || (h['salesPaise'] as int) > 0).toList();
    final now = DateTime.now().hour;
    return _Bars._([
      for (final h in shown)
        ((h['hour'] as int) % 3 == 0 ? _hourLabel(h['hour'] as int).replaceAll(' ', '') : '', h['salesPaise'] as int, '${_hourLabel(h['hour'] as int)}: ${rupees(h['salesPaise'] as int)} · ${h['bills']} bills', h['hour'] == now),
    ]);
  }
  final List<(String label, int value, String tip, bool highlight)> points;

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final max = points.fold<int>(0, (m, x) => x.$2 > m ? x.$2 : m);
    if (max == 0) {
      return SizedBox(height: 190, child: Center(child: Text('No paid bills in this period yet', style: HPType.body(p.muted))));
    }
    return SizedBox(
      height: 200,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final x in points)
          Expanded(
            child: Tooltip(
              message: x.$3,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: points.length > 14 ? 1.5 : 4),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (x.$2 > 0 && points.length <= 10) FittedBox(fit: BoxFit.scaleDown, child: Text(rupees(x.$2), style: HPType.body(p.muted).copyWith(fontSize: 11))),
                  const SizedBox(height: 4),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: x.$2 / max),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    builder: (_, v, _) => Container(
                      height: 3 + 140 * v,
                      decoration: BoxDecoration(
                        color: x.$4 ? HPColors.saffron : p.accent.withValues(alpha: x.$2 == 0 ? .15 : (p.isDark ? .45 : .55)),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(height: 16, child: FittedBox(fit: BoxFit.scaleDown, child: Text(x.$1, style: HPType.label(x.$4 ? p.text : p.muted).copyWith(fontSize: 11)))),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

class _Modes extends StatelessWidget {
  const _Modes({required this.byMode});
  final Map<String, dynamic> byMode;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final total = byMode.values.fold<int>(0, (s, v) => s + (v as int));
    if (total == 0) return Text('No payments in this period yet.', style: HPType.body(p.muted));
    final colors = {'cash': p.success, 'upi': HPColors.saffron, 'card': p.pending};
    final icons = {'cash': Icons.payments_outlined, 'upi': Icons.qr_code_2_rounded, 'card': Icons.credit_card_rounded};
    final entries = byMode.entries.toList()..sort((a, b) => (b.value as int).compareTo(a.value as int));
    return Column(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 14,
          child: Row(children: [for (final e in entries) Expanded(flex: ((e.value as int) * 1000 ~/ total).clamp(1, 1000), child: Container(color: colors[e.key] ?? p.muted))]),
        ),
      ),
      const SizedBox(height: HPSpace.lg),
      for (final e in entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(icons[e.key] ?? Icons.payments_outlined, size: 18, color: colors[e.key] ?? p.muted),
            const SizedBox(width: HPSpace.sm),
            Expanded(child: Text(e.key.toUpperCase(), style: HPType.label(p.text))),
            Text('${((e.value as int) * 100 / total).round()}%', style: HPType.body(p.muted)),
            const SizedBox(width: HPSpace.md),
            SizedBox(width: 84, child: Text(rupees(e.value as int), textAlign: TextAlign.right, style: HPType.label(p.text))),
          ]),
        ),
      const Divider(),
      Row(children: [Text('Total collected', style: HPType.body(p.muted)), const Spacer(), Text(rupees(total), style: HPType.label(p.text))]),
    ]);
  }
}

class _Split extends StatelessWidget {
  const _Split({required this.k});
  final Json k;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final dine = k['dineInPaise'] as int, take = k['takeawayPaise'] as int;
    final total = dine + take;
    Widget line(IconData icon, String label, int paise, int bills, Color c) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(icon, color: c, size: 20),
            const SizedBox(width: HPSpace.sm),
            Expanded(child: Text(label, style: HPType.label(p.text))),
            Text('$bills bills', style: HPType.body(p.muted)),
            const SizedBox(width: HPSpace.md),
            Text(rupees(paise), style: HPType.label(p.text)),
          ]),
        );
    return Column(children: [
      if (total > 0)
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 14,
            child: Row(children: [
              if (dine > 0) Expanded(flex: dine, child: Container(color: HPColors.saffron)),
              if (take > 0) Expanded(flex: take, child: Container(color: p.pending)),
            ]),
          ),
        ),
      const SizedBox(height: HPSpace.md),
      line(Icons.table_restaurant_rounded, 'Dine-in', dine, k['dineInBills'] as int, HPColors.saffron),
      line(Icons.shopping_bag_outlined, 'Takeaway', take, k['takeawayBills'] as int, p.pending),
    ]);
  }
}

class _Categories extends StatelessWidget {
  const _Categories({required this.cats});
  final List<Json> cats;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    if (cats.isEmpty) return Text('No dishes sold in this period yet.', style: HPType.body(p.muted));
    final max = cats.fold<int>(0, (m, c) => (c['amountPaise'] as int) > m ? c['amountPaise'] as int : m);
    return Column(children: [
      for (final c in cats.take(6))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('${c['name']}', style: HPType.label(p.text), overflow: TextOverflow.ellipsis)),
              Text('${c['qty']} · ${rupees(c['amountPaise'] as int)}', style: HPType.body(p.muted)),
            ]),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: max == 0 ? 0 : (c['amountPaise'] as int) / max, minHeight: 6, color: HPColors.saffron, backgroundColor: p.raised),
            ),
          ]),
        ),
    ]);
  }
}

class _Leakage extends StatelessWidget {
  const _Leakage({required this.k, required this.reasons});
  final Json k;
  final List<Json> reasons;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final rev = k['reversals'] as Json, adj = k['adjustments'] as Json;
    Widget line(String label, String value, String sub, Color c) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            const SizedBox(width: HPSpace.sm),
            Expanded(child: Text(label, style: HPType.label(p.text))),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(value, style: HPType.label(p.text)), Text(sub, style: HPType.body(p.muted).copyWith(fontSize: 12))]),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      line('Discounts given', rupees(k['discountsPaise'] as int), 'on paid bills', HPColors.saffron),
      line('Items reversed', rupees(rev['amountPaise'] as int), '${rev['count']} lines', p.danger),
      line('Bill corrections', rupees(adj['amountPaise'] as int), '${adj['count']} adjustments', p.pending),
      if (reasons.isNotEmpty) ...[
        const SizedBox(height: HPSpace.sm),
        Text('TOP REVERSAL REASONS', style: HPType.overline(p.muted).copyWith(fontSize: 10)),
        const SizedBox(height: 4),
        for (final r in reasons.take(3)) Text('${r['count']}× ${r['reason']}', style: HPType.body(p.text), overflow: TextOverflow.ellipsis),
      ],
    ]);
  }
}

class _TopDishes extends StatelessWidget {
  const _TopDishes({required this.items});
  final List<Json> items;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    if (items.isEmpty) return Text('Dishes appear here once bills sync from the hub.', style: HPType.body(p.muted));
    final total = items.fold<int>(0, (s, i) => s + (i['amountPaise'] as int));
    return Column(children: [
      for (final (i, it) in items.indexed)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: HPSpace.xs),
          child: Row(children: [
            SizedBox(width: 28, child: Text('${i + 1}', style: HPType.titleCard(p.faint).copyWith(fontSize: 16))),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${it['name']}', style: HPType.label(p.text), overflow: TextOverflow.ellipsis),
                Text('${it['category'] ?? ''}', style: HPType.body(p.muted).copyWith(fontSize: 12)),
              ]),
            ),
            Text('${it['qty']} sold', style: HPType.body(p.muted)),
            const SizedBox(width: HPSpace.md),
            SizedBox(width: 48, child: Text(total == 0 ? '' : '${((it['amountPaise'] as int) * 100 / total).round()}%', textAlign: TextAlign.right, style: HPType.body(p.faint))),
            SizedBox(width: 90, child: Text(rupees(it['amountPaise'] as int), textAlign: TextAlign.right, style: HPType.label(p.text))),
          ]),
        ),
    ]);
  }
}

class _Staff extends StatelessWidget {
  const _Staff({required this.rows});
  final List<Json> rows;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    if (rows.isEmpty) return Text('Sales per waiter show here once bills are paid.', style: HPType.body(p.muted));
    return Column(children: [
      Row(children: [
        Expanded(child: Text('WAITER', style: HPType.overline(p.muted).copyWith(fontSize: 10))),
        SizedBox(width: 48, child: Text('BILLS', textAlign: TextAlign.right, style: HPType.overline(p.muted).copyWith(fontSize: 10))),
        SizedBox(width: 84, child: Text('SALES', textAlign: TextAlign.right, style: HPType.overline(p.muted).copyWith(fontSize: 10))),
        SizedBox(width: 64, child: Text('TIPS', textAlign: TextAlign.right, style: HPType.overline(p.muted).copyWith(fontSize: 10))),
      ]),
      const Divider(),
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            CircleAvatar(radius: 14, backgroundColor: p.success.withValues(alpha: .18), child: Text('${r['name']}'.characters.first, style: HPType.label(p.text).copyWith(fontSize: 12))),
            const SizedBox(width: HPSpace.sm),
            Expanded(child: Text('${r['name']}', style: HPType.label(p.text), overflow: TextOverflow.ellipsis)),
            SizedBox(width: 48, child: Text('${r['bills']}', textAlign: TextAlign.right, style: HPType.body(p.text))),
            SizedBox(width: 84, child: Text(rupees(r['salesPaise'] as int), textAlign: TextAlign.right, style: HPType.label(p.text))),
            SizedBox(width: 64, child: Text(rupees(r['tipsPaise'] as int), textAlign: TextAlign.right, style: HPType.body(p.accentInk))),
          ]),
        ),
    ]);
  }
}

class _RecentBills extends ConsumerWidget {
  const _RecentBills({required this.bills});
  final List<Json> bills;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.hp;
    if (bills.isEmpty) return Text('Bills appear here as the hub syncs them.', style: HPType.body(p.muted));
    return Column(children: [
      for (final b in bills)
        InkWell(
          key: Key('recent-${b['invoiceNo']}'),
          borderRadius: BorderRadius.circular(10),
          onTap: () => showDialog<void>(context: context, builder: (_) => _BillDetail(id: '${b['id']}')),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: HPSpace.sm, horizontal: HPSpace.xs),
            child: Row(children: [
              Expanded(
                flex: 3,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${b['invoiceNo']}', style: HPType.mono(p.text)),
                  Text([b['where'], if (b['waiter'] != null) b['waiter'], _clock(b['closedAt'] ?? b['createdAt'])].join(' · '), style: HPType.body(p.muted).copyWith(fontSize: 12), overflow: TextOverflow.ellipsis),
                ]),
              ),
              StatusChip(label: b['status'] == 'paid' ? 'Paid' : 'Open', tone: b['status'] == 'paid' ? HPTone.success : HPTone.saffron),
              const SizedBox(width: HPSpace.md),
              SizedBox(width: 90, child: Text(rupees(b['totalPaise'] as int), textAlign: TextAlign.right, style: HPType.label(p.text))),
              Icon(Icons.chevron_right_rounded, color: p.faint),
            ]),
          ),
        ),
    ]);
  }
}

/// Bill drill-down: lines (incl. reversed with reason), totals, payments, tip and corrections.
class _BillDetail extends ConsumerWidget {
  const _BillDetail({required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.hp;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 720),
        child: AsyncView<Json>(
          load: () => ref.read(apiProvider).billDetail(id),
          builder: (c, b, _) {
            final t = b['totals'] as Json;
            Widget money(String label, Object? v, {bool strong = false}) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(child: Text(label, style: strong ? HPType.label(p.text) : HPType.body(p.muted), overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: HPSpace.sm),
                    Text(rupees((v as num? ?? 0).toInt()), style: strong ? HPType.titleCard(p.text) : HPType.mono(p.muted)),
                  ]),
                );
            return ListView(padding: const EdgeInsets.all(HPSpace.x2), shrinkWrap: true, children: [
              Row(children: [
                Expanded(child: Text('${b['invoiceNo']}', style: HPType.titleCard(p.text))),
                StatusChip(label: b['status'] == 'paid' ? 'Paid' : 'Open', tone: b['status'] == 'paid' ? HPTone.success : HPTone.saffron),
              ]),
              Text([b['where'], if (b['waiter'] != null) 'Waiter ${b['waiter']}', _clock(b['closedAt'] ?? b['createdAt'])].join(' · '), style: HPType.body(p.muted)),
              const SizedBox(height: HPSpace.lg),
              for (final l in (b['lines'] as List).cast<Json>())
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 30, child: Text('${l['qty']}×', style: HPType.mono(p.muted))),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${l['name']}', style: HPType.body(l['status'] == 'reversed' ? p.faint : p.text).copyWith(decoration: l['status'] == 'reversed' ? TextDecoration.lineThrough : null)),
                        if (l['status'] == 'reversed') Text('Reversed: ${l['reversalReason'] ?? ''}', style: HPType.body(p.danger).copyWith(fontSize: 12)),
                        if (l['notes'] != null) Text('${l['notes']}', style: HPType.note(p.note).copyWith(fontSize: 13)),
                      ]),
                    ),
                    Text(rupees((l['amountPaise'] as num).toInt()), style: HPType.mono(l['status'] == 'reversed' ? p.faint : p.text)),
                  ]),
                ),
              const Divider(),
              money('Subtotal', t['subtotalPaise']),
              if ((t['discountPaise'] as num? ?? 0) != 0) money('Discount', -(t['discountPaise'] as num)),
              money('CGST', t['cgstPaise']),
              money('SGST', t['sgstPaise']),
              if ((t['tipPaise'] as num? ?? 0) != 0) money('Tip', t['tipPaise']),
              if ((t['roundOffPaise'] as num? ?? 0) != 0) money('Round-off', t['roundOffPaise']),
              const Divider(),
              money('Total', t['totalPaise'], strong: true),
              if ((b['payments'] as List).isNotEmpty) ...[
                const SizedBox(height: HPSpace.lg),
                Text('PAYMENTS', style: HPType.overline(p.muted)),
                for (final pay in (b['payments'] as List).cast<Json>())
                  money('${pay['mode']}'.toUpperCase() + ((pay['changePaise'] as num? ?? 0) > 0 ? ' · change ${rupees((pay['changePaise'] as num).toInt())}' : ''), pay['amountPaise']),
              ],
              for (final tip in (b['tips'] as List).cast<Json>()) money('Tip to ${tip['waiter'] ?? '—'}', tip['amountPaise']),
              if ((b['adjustments'] as List).isNotEmpty) ...[
                const SizedBox(height: HPSpace.lg),
                Text('CORRECTIONS', style: HPType.overline(p.muted)),
                for (final a in (b['adjustments'] as List).cast<Json>()) money('${a['reason']}', a['amountPaise']),
              ],
              const SizedBox(height: HPSpace.lg),
              Align(alignment: Alignment.centerRight, child: SecondaryButton(label: 'Close', height: 44, onPressed: () => Navigator.pop(c))),
            ]);
          },
        ),
      ),
    );
  }
}

/// "Get ready for service" checklist: what is missing before the first service, each step one click away.
class _Checklist extends StatelessWidget {
  const _Checklist({required this.counts, required this.hub});
  final Json counts;
  final Json? hub;
  @override
  Widget build(BuildContext context) {
    final steps = [
      ('Add your menu', '${counts['items']} dishes in ${counts['categories']} categories', (counts['items'] as int) > 0, '/console/menu', Icons.restaurant_menu_rounded),
      ('Set up floors & tables', '${counts['tables']} tables', (counts['tables'] as int) > 0, '/console/tables', Icons.table_restaurant_outlined),
      ('Add your team', '${counts['staff']} people with a PIN', (counts['staff'] as int) > 1, '/console/staff', Icons.badge_outlined),
      ('Connect the hub', hub == null ? 'Install the POS on the cashier device' : (hub!['online'] == true ? 'Online' : 'Registered, not seen recently'), hub != null, '/console/devices', Icons.router_outlined),
    ];
    final done = steps.where((s) => s.$3).length;
    if (done == steps.length) return const SizedBox.shrink();
    final p = context.hp;
    return SectionCard(
      title: 'Get ready for service · $done of ${steps.length}',
      child: Column(children: [
        ClipRRect(borderRadius: BorderRadius.circular(8), child: LinearProgressIndicator(value: done / steps.length, minHeight: 6)),
        const SizedBox(height: HPSpace.md),
        for (final s in steps)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: s.$3 ? p.success.withValues(alpha: .16) : p.raised, shape: BoxShape.circle),
              child: Icon(s.$3 ? Icons.check_rounded : s.$5, size: 18, color: s.$3 ? p.success : p.muted),
            ),
            title: Text(s.$1, style: HPType.label(s.$3 ? p.muted : p.text).copyWith(decoration: s.$3 ? TextDecoration.lineThrough : null)),
            subtitle: Text(s.$2, style: HPType.body(p.muted)),
            trailing: s.$3 ? null : const Icon(Icons.chevron_right_rounded),
            onTap: () => context.go(s.$4),
          ),
      ]),
    );
  }
}
