import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../app.dart' show restaurantNav;
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'dashboard_screen.dart';
import 'floor_editor.dart';
import 'staff_screen.dart' show roleInfo;

/// Restaurant console home. People who read business reports (owner, restaurant admin, auditor) get the business
/// dashboard. Everyone else gets panels for exactly what their role — or custom role — allows:
/// kitchen orders & stock (chef), today's bills & payments (cashier), live tables & orders (waiter).
/// Taking orders and payments stays on the POS app, which keeps working offline.
class ConsoleHome extends ConsumerWidget {
  const ConsoleHome({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(authProvider);
    if (a is! SignedIn) return const SizedBox.shrink();
    if (a.can('reports.read') && a.can('restaurant.profile.read')) return const RestaurantDashboardScreen();
    final api = ref.read(apiProvider);
    final role = a.me['customRoleName'] as String? ?? roleInfo[a.roles.firstOrNull ?? '']?.$1 ?? 'Team member';
    final items = restaurantNav.where((n) => n.$1 != '/console' && n.$4 != null && a.can(n.$4!)).toList();
    final p = context.hp;
    return PageFrame(
      title: 'Hello, ${'${a.me['name'] ?? ''}'.split(' ').first}',
      subtitle: role,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (a.can('order.write') || a.can('payment.take'))
          Padding(
            padding: const EdgeInsets.only(bottom: HPSpace.lg),
            child: Text('Take orders and payments on the POS app (it keeps working when the internet is down). This page shows what is happening.', key: const Key('pos-note'), style: HPType.body(p.muted)),
          ),
        if (a.can('order.read') && (a.can('kds.read') || a.can('order.write'))) ...[
          _LiveOrders(api: api, kitchen: a.can('kds.update') && !a.can('order.write')),
          const SizedBox(height: HPSpace.lg),
        ],
        if (a.can('payment.take') && a.can('order.read')) ...[
          _TodaySales(api: api),
          const SizedBox(height: HPSpace.lg),
        ],
        if (a.can('inventory.read')) ...[
          _StockPanel(api: api, canConsume: a.can('inventory.consume'), canRequest: a.can('inventory.request')),
          const SizedBox(height: HPSpace.lg),
        ],
        if (a.can('floor.read') && a.can('order.read') && !a.can('kds.update')) ...[
          _LiveFloor(api: api, canSetStatus: a.can('order.write')),
          const SizedBox(height: HPSpace.lg),
        ],
        if (items.isEmpty)
          const EmptyState(icon: Icons.point_of_sale_rounded, title: 'Your work is on the POS', message: 'Your role uses the POS app. Ask the owner if you need more here.')
        else
          Wrap(spacing: HPSpace.lg, runSpacing: HPSpace.lg, children: [
            for (final n in items)
              SizedBox(
                width: 240,
                child: Card(
                  child: InkWell(
                    key: Key('home-${n.$2}'),
                    borderRadius: BorderRadius.circular(HPRadius.card),
                    onTap: () => context.go(n.$1),
                    child: Padding(
                      padding: const EdgeInsets.all(HPSpace.lg),
                      child: Row(children: [
                        Icon(n.$3, color: p.accentInk),
                        const SizedBox(width: HPSpace.md),
                        Expanded(child: Text(n.$2, style: HPType.label(p.text))),
                        Icon(Icons.chevron_right_rounded, color: p.muted),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
      ]),
    );
  }
}

/// Open orders with their lines and kitchen status (from what the hub synced, a few seconds behind the POS).
class _LiveOrders extends StatefulWidget {
  const _LiveOrders({required this.api, required this.kitchen});
  final ApiClient api;
  final bool kitchen;
  @override
  State<_LiveOrders> createState() => _LiveOrdersState();
}

class _LiveOrdersState extends State<_LiveOrders> {
  List<Json>? _orders;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.liveOrders();
      if (mounted) setState(() => _orders = r.cast<Json>());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return SectionCard(
      title: widget.kitchen ? 'Kitchen orders' : 'Open orders',
      actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded), onPressed: _load)],
      child: _error != null
          ? Text('$_error', style: HPType.body(p.danger))
          : _orders == null
              ? const SkeletonBox(height: 80)
              : _orders!.isEmpty
                  ? Text('No open orders right now.', key: const Key('no-orders'), style: HPType.body(p.muted))
                  : Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, children: [
                      for (final o in _orders!)
                        SizedBox(
                          width: 260,
                          child: Card(
                            key: Key('live-${o['id']}'),
                            color: p.raised,
                            child: Padding(
                              padding: const EdgeInsets.all(HPSpace.md),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(o['table'] != null ? 'Table ${o['table']}' : 'Takeaway', style: HPType.label(p.text)),
                                Text([if (o['waiter'] != null) '${o['waiter']}', if (o['status'] == 'billed') 'bill printed', for (final k in (o['kitchen'] as List).cast<Json>()) 'KOT ${k['kotNo']} ${k['status']}'].join(' · '), style: HPType.body(p.muted).copyWith(fontSize: 12)),
                                const SizedBox(height: HPSpace.xs),
                                for (final l in (o['lines'] as List).cast<Json>().where((l) => l['status'] != 'reversed'))
                                  Text('${l['qty']} × ${l['name']}${l['status'] == 'pending' ? ' (not sent)' : ''}${l['notes'] != null ? ' — ${l['notes']}' : ''}', style: HPType.body(p.text)),
                              ]),
                            ),
                          ),
                        ),
                    ]),
    );
  }
}

class _TodaySales extends StatefulWidget {
  const _TodaySales({required this.api});
  final ApiClient api;
  @override
  State<_TodaySales> createState() => _TodaySalesState();
}

class _TodaySalesState extends State<_TodaySales> {
  Json? _s;
  @override
  void initState() {
    super.initState();
    widget.api.salesRecords({'from': DateTime.now().toIso8601String().substring(0, 10)}).then((s) {
      if (mounted) setState(() => _s = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final sum = _s?['summary'] as Json?;
    return SectionCard(
      title: 'Today\'s bills & payments',
      child: sum == null
          ? const SkeletonBox(height: 80)
          : Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, children: [
              SizedBox(width: 200, child: KpiCard(key: const Key('today-sales'), label: 'Collected', value: rupees(sum['salesPaise'] as int), caption: '${sum['paidBills']} paid bills', icon: Icons.payments_outlined)),
              for (final m in (sum['paymentsByMode'] as Json).entries) SizedBox(width: 160, child: KpiCard(label: m.key.toUpperCase(), value: rupees(m.value as int), icon: Icons.account_balance_wallet_outlined)),
              SizedBox(width: 160, child: KpiCard(label: 'Discounts', value: rupees(sum['discountsPaise'] as int), icon: Icons.local_offer_outlined)),
            ]),
    );
  }
}

class _StockPanel extends StatefulWidget {
  const _StockPanel({required this.api, required this.canConsume, required this.canRequest});
  final ApiClient api;
  final bool canConsume, canRequest;
  @override
  State<_StockPanel> createState() => _StockPanelState();
}

class _StockPanelState extends State<_StockPanel> {
  Json? _alerts;
  @override
  void initState() {
    super.initState();
    widget.api.invAlerts().then((a) {
      if (mounted) setState(() => _alerts = a);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final low = ((_alerts?['low'] as List?) ?? const []).cast<Json>(), exp = ((_alerts?['expiring'] as List?) ?? const []).cast<Json>();
    return SectionCard(
      title: 'Stock',
      actions: [
        if (widget.canConsume || widget.canRequest)
          TextButton.icon(key: const Key('go-inventory'), onPressed: () => context.go('/console/inventory'), icon: const Icon(Icons.inventory_2_outlined, size: 18), label: Text(widget.canConsume ? 'Record use / wastage' : 'Open inventory')),
      ],
      child: _alerts == null
          ? const SkeletonBox(height: 60)
          : low.isEmpty && exp.isEmpty
              ? Text('Nothing low or about to expire.', style: HPType.body(p.muted))
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final x in low) Text('Low: ${x['name']} (${x['stock']} ${x['unit']})', key: Key('home-low-${x['sku']}'), style: HPType.body(p.text)),
                  for (final x in exp) Text('Expiring ${x['expiryDate']}: ${x['name']}', style: HPType.body(p.danger)),
                ]),
    );
  }
}

/// The live floor for waiters: the owner's layout coloured by table state.
class _LiveFloor extends StatefulWidget {
  const _LiveFloor({required this.api, required this.canSetStatus});
  final ApiClient api;
  final bool canSetStatus;
  @override
  State<_LiveFloor> createState() => _LiveFloorState();
}

class _LiveFloorState extends State<_LiveFloor> {
  List<Json>? _floors;
  String? _floor;
  @override
  void initState() {
    super.initState();
    widget.api.floors().then((f) {
      if (mounted) {
        setState(() {
          _floors = f.cast<Json>();
          _floor = _floors!.firstOrNull?['id'] as String?;
        });
      }
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    if (_floors == null) return const SkeletonBox(height: 120);
    if (_floor == null) return const SizedBox.shrink();
    return SectionCard(
      title: 'Tables',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_floors!.length > 1)
          Wrap(spacing: HPSpace.sm, children: [
            for (final f in _floors!) ChoiceChip(label: Text('${f['name']}'), selected: f['id'] == _floor, onSelected: (_) => setState(() => _floor = f['id'] as String)),
          ]),
        FloorEditor(key: ValueKey('home-floor-$_floor'), api: widget.api, floorId: _floor!, canEdit: false, canSetStatus: widget.canSetStatus, editorInPlan: false),
      ]),
    );
  }
}
