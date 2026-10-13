import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';
import '../state/app_state.dart';
import '../ui/common.dart';
import '../ui/shell.dart';
import 'order_screen.dart';

/// Restaurant + branch names for headers ("Demo Dhaba · MG Road").
final branchNameProvider = FutureProvider<String>((ref) async {
  final api = ref.watch(hubApiProvider);
  if (api == null) return '';
  try {
    final b = await api.branch();
    final tenant = (b['tenant'] as Map?)?['name'];
    final branch = (b['branch'] as Map?)?['name'];
    return [?tenant, if (branch != null && branch != tenant) '$branch'.replaceFirst('$tenant — ', '')].join(' · ');
  } catch (_) {
    return '';
  }
});

/// C1 Table map: the floor right now — free / seated / bill printed with running totals, minutes and waiter;
/// the takeaway queue; and one tap to open or continue an order.
class TableMapScreen extends ConsumerStatefulWidget {
  const TableMapScreen({super.key});
  @override
  ConsumerState<TableMapScreen> createState() => _TableMapScreenState();
}

class _TableMapScreenState extends ConsumerState<TableMapScreen> {
  String? _floor;
  int _refresh = 0;

  Future<void> _openOrder(HubApi api, {String? tableId, String? tableName, required String type}) async {
    final session = ref.read(sessionProvider)!;
    String? waiterId = session.can('payment.take') ? null : session.userId; // a waiter opens tables as themselves
    if (type == 'dine_in' && waiterId == null) {
      final staff = await api.staff();
      if (!mounted) return;
      final waiters = staff.where((s) => (s['roles'] as List).contains('waiter')).toList();
      if (waiters.isNotEmpty) {
        final picked = await showModalBottomSheet<String>(
          context: context,
          builder: (c) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(HPSpace.lg, 0, HPSpace.lg, HPSpace.lg),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Who serves table $tableName?', style: HPType.titleCard(c.hp.text)),
                const SizedBox(height: HPSpace.md),
                Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
                  for (final w in waiters)
                    ActionChip(
                      key: Key('waiter-${w['name']}'),
                      avatar: CircleAvatar(backgroundColor: roleColor(c, 'waiter').withValues(alpha: .25), child: Text('${w['name']}'.characters.first)),
                      label: Text('${w['name']}'.split(' (').first),
                      onPressed: () => Navigator.pop(c, w['id'] as String),
                    ),
                ]),
                const SizedBox(height: HPSpace.md),
                TextButton(key: const Key('waiter-none'), onPressed: () => Navigator.pop(c, ''), child: const Text('No waiter — I will serve it')),
              ]),
            ),
          ),
        );
        if (picked == null) return; // dismissed: do not open the table
        waiterId = picked.isEmpty ? null : picked;
      }
    }
    try {
      final o = await api.openOrder(type: type, tableId: tableId, waiterId: waiterId);
      if (mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: o['id'] as String)));
      if (mounted) setState(() => _refresh++);
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    }
  }

  Future<void> _continue(String orderId) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: orderId)));
    if (mounted) setState(() => _refresh++);
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(hubApiProvider)!;
    final session = ref.watch(sessionProvider);
    if (session == null) return const SizedBox.shrink();
    ref.watch(hubTickProvider);
    final p = context.hp;
    final narrow = isNarrow(context);
    final canWrite = session.can('order.write');
    return Scaffold(
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              key: const Key('new-takeaway'),
              heroTag: 'takeaway',
              onPressed: () {
                HapticFeedback.selectionClick();
                _openOrder(api, type: 'takeaway');
              },
              backgroundColor: HPColors.saffron,
              foregroundColor: HPColors.onSaffron,
              icon: const Icon(Icons.shopping_bag_outlined),
              label: Text('Takeaway', style: HPType.label(HPColors.onSaffron)),
            )
          : null,
      body: Column(children: [
        PosTopBar(title: 'Tables', subtitle: ref.watch(branchNameProvider).valueOrNull),
        Expanded(
          child: FutureBuilder<Json>(
            key: ValueKey(_refresh),
            future: api.state(),
            builder: (c, s) {
              if (s.hasError) return ErrorState(message: errText(s.error!), onRetry: () => setState(() => _refresh++));
              if (!s.hasData) return const SkeletonGrid(maxExtent: 150);
              final floors = (s.data!['floors'] as List).cast<Json>();
              final floorId = _floor != null && floors.any((f) => f['id'] == _floor) ? _floor : (floors.isEmpty ? null : floors.first['id'] as String);
              final all = (s.data!['tables'] as List).cast<Json>();
              final tables = all.where((t) => t['floor_id'] == floorId).toList()
                ..sort((a, b) => (int.tryParse('${a['name']}') ?? 999).compareTo(int.tryParse('${b['name']}') ?? 999));
              final open = (s.data!['openOrders'] as List).cast<Json>();
              final takeaways = open.where((o) => o['type'] == 'takeaway').toList();
              final free = all.where((t) => t['status'] == 'free').length;
              final seated = all.where((t) => t['status'] == 'occupied').length;
              final billing = all.where((t) => t['status'] == 'bill_printed').length;
              final pad = narrow ? HPSpace.lg : HPSpace.x2;
              return CustomScrollView(slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(pad, HPSpace.sm, pad, HPSpace.md),
                    sliver: SliverToBoxAdapter(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
                          StatusChip(key: const Key('count-free'), label: '$free free', icon: Icons.event_seat_outlined),
                          StatusChip(label: '$seated seated', tone: HPTone.saffron, icon: Icons.restaurant_rounded),
                          if (billing > 0) StatusChip(label: '$billing billing', tone: HPTone.danger, icon: Icons.receipt_rounded),
                          if (!canWrite) const StatusChip(label: 'Read-only', icon: Icons.visibility_outlined),
                        ]),
                        if (floors.length > 1) ...[
                          const SizedBox(height: HPSpace.md),
                          SizedBox(
                            height: 44,
                            child: ListView(scrollDirection: Axis.horizontal, children: [
                              for (final f in floors)
                                Padding(
                                  padding: const EdgeInsets.only(right: HPSpace.sm),
                                  child: CategoryChip(
                                    label: '${f['name']}',
                                    count: all.where((t) => t['floor_id'] == f['id'] && t['status'] != 'free').length,
                                    selected: f['id'] == floorId,
                                    onTap: () => setState(() => _floor = f['id'] as String),
                                  ),
                                ),
                            ]),
                          ),
                        ],
                      ]),
                    ),
                  ),
                  if (tables.isEmpty)
                    const SliverFillRemaining(hasScrollBody: false, child: EmptyState(icon: Icons.table_restaurant_outlined, title: 'No tables yet', message: 'The owner adds floors and tables in the web console.'))
                  else
                    SliverPadding(
                      padding: EdgeInsets.symmetric(horizontal: pad),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: narrow ? 120 : 160, mainAxisSpacing: HPSpace.md, crossAxisSpacing: HPSpace.md, childAspectRatio: .95),
                        delegate: SliverChildListDelegate([
                          for (final t in tables)
                            TableTile(
                              key: Key('table-${t['name']}'),
                              expand: true,
                              name: '${t['name']}',
                              seats: t['seats'] as int,
                              state: switch (t['status']) { 'occupied' => TableState.ordering, 'bill_printed' => TableState.billPrinted, _ => TableState.free },
                              runningTotal: t['totalPaise'] == null ? null : rupees(t['totalPaise'] as int),
                              minutesSeated: t['openedAt'] == null ? null : minutesSince(t['openedAt']),
                              caption: (t['waiterName'] as String?)?.split(' (').first,
                              onTap: t['orderId'] != null
                                  ? () => _continue(t['orderId'] as String)
                                  : (canWrite ? () => _openOrder(api, tableId: t['id'] as String, tableName: '${t['name']}', type: 'dine_in') : null),
                            ),
                        ]),
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(pad, HPSpace.x2, pad, 120),
                    sliver: SliverToBoxAdapter(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        SectionHeader('Takeaway · ${takeaways.length}'),
                        if (takeaways.isEmpty)
                          Text(canWrite ? 'No takeaway orders. Tap Takeaway to start one.' : 'No takeaway orders.', style: HPType.body(p.muted))
                        else
                          Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, children: [
                            for (final o in takeaways)
                              SizedBox(
                                width: narrow ? double.infinity : 340,
                                child: OrderCard(
                                  key: Key('takeaway-${o['id']}'),
                                  leading: CircleAvatar(backgroundColor: HPColors.saffron.withValues(alpha: .2), child: Icon(Icons.shopping_bag_outlined, color: p.accentInk)),
                                  title: 'Takeaway · ${clock12(o['opened_at'])}',
                                  subtitle: '${o['item_count'] ?? 0} items · ${minutesSince(o['opened_at'])} min',
                                  total: rupees((o['total_paise'] as int?) ?? 0),
                                  status: o['status'] == 'billed' ? 'Billed' : 'Open',
                                  tone: o['status'] == 'billed' ? HPTone.danger : HPTone.saffron,
                                  onTap: () => _continue(o['id'] as String),
                                ),
                              ),
                          ]),
                      ]),
                    ),
                  ),
                ]);
            },
          ),
        ),
      ]),
    );
  }
}
