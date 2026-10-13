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

/// O1 Restaurant dashboard: today at a glance, the last 7 days, how guests pay, top dishes,
/// hub health and a setup checklist that walks a new owner through menu → tables → staff → hub.
class RestaurantDashboardScreen extends ConsumerWidget {
  const RestaurantDashboardScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiProvider);
    final me = ref.watch(authProvider);
    final canReports = me is SignedIn && me.can('reports.read');
    return AsyncView<(Json, Json?)>(
      load: () async => (await api.overview(), canReports ? await api.dashboard() : null),
      builder: (c, data, reload) {
        final (o, d) = data;
        final r = o['restaurant'] as Json;
        final lic = o['license'] as Json;
        final counts = o['counts'] as Json;
        final narrow = isNarrowWeb(context);
        final p = context.hp;
        return RefreshIndicator(
          onRefresh: () async => reload(),
          child: PageFrame(
            title: '${r['name']}',
            subtitle: 'Good ${_partOfDay()} · ${lic['planName'] ?? 'No plan'} plan${lic['endsAt'] == null ? '' : ' until ${shortDate(lic['endsAt'])}'}',
            actions: [
              StatusChip(label: _hubLabel(o['hub'] as Json?), tone: _hubTone(o['hub'] as Json?), icon: Icons.router_rounded),
              IconButton(tooltip: 'Refresh', onPressed: reload, icon: const Icon(Icons.refresh_rounded)),
            ],
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _Checklist(counts: counts, hub: o['hub'] as Json?),
              if (d != null) ...[
                const SizedBox(height: HPSpace.x2),
                _grid(narrow ? 2 : 4, [
                  KpiCard(key: const Key('kpi-today'), label: 'Sales today', value: rupees((d['today'] as Json)['salesPaise'] as int), caption: '${(d['today'] as Json)['bills']} bills', icon: Icons.currency_rupee_rounded, tone: HPTone.saffron),
                  KpiCard(label: 'Average bill', value: rupees((d['today'] as Json)['avgBillPaise'] as int), caption: 'today', icon: Icons.receipt_long_rounded),
                  KpiCard(label: '7-day sales', value: rupees((d['period'] as Json)['salesPaise'] as int), caption: '${(d['period'] as Json)['bills']} bills · ${(d['period'] as Json)['orders']} orders', icon: Icons.trending_up_rounded, tone: HPTone.success),
                  KpiCard(label: 'Tips · 7 days', value: rupees((d['period'] as Json)['tipsPaise'] as int), caption: 'GST ${rupees((d['period'] as Json)['taxesPaise'] as int)}', icon: Icons.volunteer_activism_rounded, tone: HPTone.pending),
                ]),
                const SizedBox(height: HPSpace.lg),
                Flex(
                  direction: narrow ? Axis.vertical : Axis.horizontal,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _flex(narrow, 3, SectionCard(title: 'Sales · last 7 days', child: _Bars(days: ((d['days'] as List).cast<Json>())))),
                    SizedBox(width: HPSpace.lg, height: HPSpace.lg),
                    _flex(narrow, 2, SectionCard(title: 'How guests paid', child: _Modes(byMode: (d['byMode'] as Json).cast<String, dynamic>()))),
                  ],
                ),
                const SizedBox(height: HPSpace.lg),
                SectionCard(
                  title: 'Top dishes · 7 days',
                  child: (d['topItems'] as List).isEmpty
                      ? Text('Dishes appear here once bills sync from the hub.', style: HPType.body(p.muted))
                      : Column(children: [
                          for (final (i, it) in (d['topItems'] as List).cast<Json>().indexed)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: HPSpace.xs),
                              child: Row(children: [
                                SizedBox(width: 28, child: Text('${i + 1}', style: HPType.titleCard(p.faint).copyWith(fontSize: 16))),
                                Expanded(child: Text('${it['name']}', style: HPType.label(p.text), overflow: TextOverflow.ellipsis)),
                                Text('${it['qty']} sold', style: HPType.body(p.muted)),
                                const SizedBox(width: HPSpace.lg),
                                SizedBox(width: 90, child: Text(rupees(it['amountPaise'] as int), textAlign: TextAlign.right, style: HPType.label(p.text))),
                              ]),
                            ),
                        ]),
                ),
              ],
            ]),
          ),
        );
      },
    );
  }

  static Widget _grid(int cols, List<Widget> children) => LayoutBuilder(builder: (c, box) {
        const gap = HPSpace.lg;
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(spacing: gap, runSpacing: gap, children: [for (final ch in children) SizedBox(width: w, child: ch)]);
      });

  static Widget _flex(bool narrow, int flex, Widget child) => narrow ? child : Expanded(flex: flex, child: child);

  static String _partOfDay() {
    final h = DateTime.now().hour;
    return h < 12 ? 'morning' : h < 17 ? 'afternoon' : 'evening';
  }

  static String _hubLabel(Json? hub) => hub == null ? 'No hub yet' : (hub['online'] == true ? 'Hub online' : 'Hub offline');
  static HPTone _hubTone(Json? hub) => hub == null ? HPTone.neutral : (hub['online'] == true ? HPTone.success : HPTone.danger);
}

/// "Get set up" checklist: what is missing before the first service, each step one click away.
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

class _Bars extends StatelessWidget {
  const _Bars({required this.days});
  final List<Json> days;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final max = days.fold<int>(0, (m, d) => (d['salesPaise'] as int) > m ? d['salesPaise'] as int : m);
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return SizedBox(
      height: 190,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final d in days)
          Expanded(
            child: Tooltip(
              message: '${d['day']}: ${rupees(d['salesPaise'] as int)} · ${d['bills']} bills',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if ((d['salesPaise'] as int) > 0)
                    FittedBox(fit: BoxFit.scaleDown, child: Text(rupees(d['salesPaise'] as int), style: HPType.body(p.muted).copyWith(fontSize: 11))),
                  const SizedBox(height: 4),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: max == 0 ? 0 : (d['salesPaise'] as int) / max),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    builder: (_, v, _) => Container(
                      height: 4 + 130 * v,
                      decoration: BoxDecoration(
                        color: d == days.last ? HPColors.saffron : p.accent.withValues(alpha: p.isDark ? .35 : .45),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(wd[(DateTime.tryParse('${d['day']}')?.weekday ?? 1) - 1], style: HPType.label(d == days.last ? p.text : p.muted).copyWith(fontSize: 12)),
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
    if (total == 0) return Text('No payments synced yet.', style: HPType.body(p.muted));
    final colors = {'cash': p.success, 'upi': HPColors.saffron, 'card': p.pending};
    return Column(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 14,
          child: Row(children: [for (final e in byMode.entries) Expanded(flex: ((e.value as int) * 1000 ~/ total).clamp(1, 1000), child: Container(color: colors[e.key] ?? p.muted))]),
        ),
      ),
      const SizedBox(height: HPSpace.lg),
      for (final e in byMode.entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: colors[e.key] ?? p.muted, shape: BoxShape.circle)),
            const SizedBox(width: HPSpace.sm),
            Expanded(child: Text(e.key.toUpperCase(), style: HPType.label(p.text))),
            Text('${((e.value as int) * 100 / total).round()}%', style: HPType.body(p.muted)),
            const SizedBox(width: HPSpace.md),
            Text(rupees(e.value as int), style: HPType.label(p.text)),
          ]),
        ),
    ]);
  }
}
