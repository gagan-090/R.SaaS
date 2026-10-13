import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';
import '../state/app_state.dart';
import 'role_screens.dart';
import 'setup_screens.dart';

String _localTime(String iso) {
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) return iso;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.day)}/${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
}

String _shortId(String id) => id.length <= 4 ? id : '…${id.substring(id.length - 4)}';

Color _hex(Object? v, Color fallback) {
  final s = '${v ?? ''}'.replaceAll('#', '');
  return s.length == 6 ? Color(int.parse('FF$s', radix: 16)) : fallback;
}

/// Role routing after PIN login: service roles get the table map, kitchen roles the KDS, IT admins the setup home.
/// Every action is still enforced by the hub; this only picks the most useful first screen.
class RoleHome extends ConsumerWidget {
  const RoleHome({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    if (s == null) return const SizedBox.shrink(); // signing out: this screen is being closed
    if (s.can('order.read')) return const TableMapScreen(); // owner, cashier, waiter, auditor (read-only)
    if (s.can('kds.read')) return const KitchenScreen(); // chef
    return const AdminHomeScreen(); // IT admin
  }
}

/// C1 Table map: free / occupied / bill printed with running totals; takeaway; bill history.
class TableMapScreen extends ConsumerStatefulWidget {
  const TableMapScreen({super.key});
  @override
  ConsumerState<TableMapScreen> createState() => _TableMapScreenState();
}

class _TableMapScreenState extends ConsumerState<TableMapScreen> {
  String? _floor;

  Future<void> _open(HubApi api, {String? tableId, required String type}) async {
    final session = ref.read(sessionProvider)!;
    String? waiterId = session.can('payment.take') ? null : session.userId; // a waiter opens tables as themselves
    if (type == 'dine_in' && waiterId == null) {
      final staff = await api.staff();
      if (!mounted) return;
      final waiters = staff.where((s) => (s['roles'] as List).contains('waiter')).toList();
      if (waiters.isNotEmpty) {
        waiterId = await showDialog<String>(
          context: context,
          builder: (c) => SimpleDialog(title: const Text('Which waiter serves this table?'), children: [
            for (final w in waiters) SimpleDialogOption(onPressed: () => Navigator.pop(c, w['id'] as String), child: Text('${w['name']}')),
            SimpleDialogOption(onPressed: () => Navigator.pop(c), child: const Text('No waiter')),
          ]),
        );
      }
    }
    try {
      final o = await api.openOrder(type: type, tableId: tableId, waiterId: waiterId);
      if (mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: o['id'] as String)));
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(hubApiProvider)!;
    final session = ref.watch(sessionProvider);
    if (session == null) return const SizedBox.shrink(); // signing out: this screen is being closed
    ref.watch(hubTickProvider);
    return Scaffold(
      body: Column(children: [
        const StatusBar(),
        Expanded(
          child: FutureBuilder<Json>(
            future: api.state(),
            builder: (c, s) {
              if (s.hasError) return ErrorState(message: errText(s.error!), onRetry: () => setState(() {}));
              if (!s.hasData) return const LoadingState();
              final floors = (s.data!['floors'] as List).cast<Json>();
              final floorId = _floor ?? (floors.isEmpty ? null : floors.first['id'] as String);
              final tables = (s.data!['tables'] as List).cast<Json>().where((t) => t['floor_id'] == floorId).toList();
              final open = (s.data!['openOrders'] as List).cast<Json>();
              final takeaways = open.where((o) => o['type'] == 'takeaway').toList();
              return Padding(
                padding: const EdgeInsets.all(HPSpace.x2),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    for (final f in floors)
                      CategoryChip(label: '${f['name']}', selected: f['id'] == floorId, onTap: () => setState(() => _floor = f['id'] as String)),
                    if (!session.can('order.write')) const StatusChip(label: 'Read-only', icon: Icons.visibility_outlined),
                    if (session.can('order.read'))
                      SizedBox(width: 160, child: SecondaryButton(label: 'Bills', icon: Icons.receipt_long_rounded, height: 48, onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BillHistoryScreen())))),
                    if (session.can('order.write'))
                      SizedBox(width: 160, child: PrimaryButton(label: 'Takeaway', icon: Icons.shopping_bag_outlined, height: 48, onPressed: () => _open(api, type: 'takeaway'))),
                  ]),
                  const SizedBox(height: HPSpace.x2),
                  Expanded(
                    child: tables.isEmpty
                        ? const EmptyState(title: 'No tables on this floor', message: 'Add tables in the owner/IT admin setup.')
                        : SingleChildScrollView(
                            child: Wrap(spacing: isNarrow(context) ? HPSpace.md : HPSpace.lg, runSpacing: isNarrow(context) ? HPSpace.md : HPSpace.lg, children: [
                              for (final t in tables)
                                TableTile(
                                  key: Key('table-${t['name']}'),
                                  name: '${t['name']}',
                                  seats: t['seats'] as int,
                                  state: switch (t['status']) { 'occupied' => TableState.ordering, 'bill_printed' => TableState.billPrinted, _ => TableState.free },
                                  onTap: !session.can('order.write') && t['orderId'] == null
                                      ? null
                                      : () async {
                                          if (t['orderId'] == null) return _open(api, tableId: t['id'] as String, type: 'dine_in');
                                          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: t['orderId'] as String)));
                                          if (mounted) setState(() {});
                                        },
                                ),
                            ]),
                          ),
                  ),
                  if (takeaways.isNotEmpty) ...[
                    Text('TAKEAWAY', style: HPType.overline(HPColors.husk)),
                    const SizedBox(height: HPSpace.sm),
                    Wrap(spacing: HPSpace.sm, children: [
                      for (final o in takeaways)
                        ActionChip(label: Text('Takeaway · ${_shortId(o['id'] as String)}'), onPressed: () async {
                          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: o['id'] as String)));
                          if (mounted) setState(() {});
                        }),
                    ]),
                  ],
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// C2 Order screen (+ C3 transfer, C4 reversal): category rail, item grid, order panel.
class OrderScreen extends ConsumerStatefulWidget {
  const OrderScreen({super.key, required this.orderId});
  final String orderId;
  @override
  ConsumerState<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends ConsumerState<OrderScreen> {
  String? _cat;
  Json? _order;
  Json? _menu;
  Object? _error;

  HubApi get _api => ref.read(hubApiProvider)!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([_api.order(widget.orderId), _api.menu()]);
      if (mounted) setState(() { _order = r[0]; _menu = r[1]; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _do(Future<Object?> Function() f) async {
    try {
      await f();
      await _load();
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    }
  }

  Future<void> _reverse(Json line) async {
    final reason = TextEditingController();
    String pin = '';
    String? approver;
    final sent = line['status'] == 'sent';
    final session = ref.read(sessionProvider)!;
    final needPin = sent && !session.can('order.reverse.sent');
    final staff = needPin ? await _api.staff() : const <Json>[];
    if (!mounted) return;
    final managers = staff.where((s) => (s['roles'] as List).contains('owner')).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => HPDialog(
          title: 'Reverse ${line['name_snapshot']}',
          actions: [
            SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c)),
            DangerButton(
              label: 'Reverse item',
              onPressed: reason.text.trim().length < 3 || (needPin && (approver == null || pin.length < 4)) ? null : () => Navigator.pop(c, true),
            ),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${line['qty']} × ${formatPaise(line['price_snapshot_paise'] as int)} = ${formatPaise((line['qty'] as int) * (line['price_snapshot_paise'] as int))}', style: HPType.label()),
            const SizedBox(height: HPSpace.md),
            TextField(key: const Key('reverse-reason'), controller: reason, onChanged: (_) => set(() {}), decoration: const InputDecoration(labelText: 'Reason (required)')),
            if (needPin) ...[
              const SizedBox(height: HPSpace.lg),
              Text('Already sent to the kitchen — owner/manager approval needed', style: HPType.body(HPColors.saffronTint)),
              const SizedBox(height: HPSpace.sm),
              Wrap(spacing: HPSpace.sm, children: [
                for (final m in managers) ChoiceChip(label: Text('${m['name']}'), selected: approver == m['id'], onSelected: (_) => set(() => approver = m['id'] as String)),
              ]),
              Text('•' * pin.length, style: HPType.titleCard(HPColors.saffron)),
              SizedBox(width: 280, child: NumericKeypad(onKey: (d) => set(() => pin += d), onBackspace: () => set(() => pin = pin.isEmpty ? '' : pin.substring(0, pin.length - 1)), onClear: () => set(() => pin = ''))),
            ],
          ]),
        ),
      ),
    );
    if (ok != true) return;
    await _do(() => _api.reverseLine(widget.orderId, line['id'] as String, reason: reason.text.trim(), approverUserId: approver, approverPin: needPin ? pin : null));
  }

  Future<void> _transfer() async {
    final state = await _api.state();
    if (!mounted) return;
    final free = (state['tables'] as List).cast<Json>().where((t) => t['status'] == 'free').toList();
    final to = await showDialog<String>(
      context: context,
      builder: (c) => HPDialog(title: 'Move to which table?', child: free.isEmpty
          ? const Text('No free tables right now.')
          : Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, children: [
              for (final t in free) TableTile(name: '${t['name']}', seats: t['seats'] as int, state: TableState.free, onTap: () => Navigator.pop(c, t['id'] as String)),
            ])),
    );
    if (to != null) await _do(() => _api.transfer(widget.orderId, to));
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    if (session == null) return const SizedBox.shrink(); // signing out: this screen is being closed
    // live: KOT status changes from the kitchen and edits from other terminals reload this order
    ref.listen(hubEventsProvider, (_, next) {
      final d = next.valueOrNull?['data'];
      if (d is Map && d['orderId'] == widget.orderId) _load();
    });
    if (_error != null) return Scaffold(body: Column(children: [const StatusBar(), Expanded(child: ErrorState(message: errText(_error!), onRetry: _load))]));
    if (_order == null || _menu == null) return const Scaffold(body: LoadingState());
    final o = _order!;
    final cats = (_menu!['categories'] as List).cast<Json>();
    final cat = _cat ?? (cats.isEmpty ? null : cats.first['id'] as String);
    final items = (_menu!['items'] as List).cast<Json>().where((i) => i['category_id'] == cat).toList();
    final lines = (o['lines'] as List).cast<Json>();
    final pending = lines.where((l) => l['status'] == 'pending').toList();
    final sent = lines.where((l) => l['status'] == 'sent').toList();
    final reversed = lines.where((l) => l['status'] == 'reversed').toList();
    final tickets = ((o['tickets'] as List?) ?? const []).cast<Json>();
    final totals = o['totals'] as Json;
    final editable = o['status'] == 'open' && session.can('order.write');
    final title = o['table_id'] == null ? 'Takeaway' : 'Table ${_tableName(o)}';
    final narrow = isNarrow(context);
    final canBill = session.can('payment.take');

    final menuPane = Padding(
      padding: EdgeInsets.all(narrow ? HPSpace.md : HPSpace.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final c in cats) Padding(padding: const EdgeInsets.only(right: HPSpace.sm), child: CategoryChip(label: '${c['name']}', selected: c['id'] == cat, onTap: () => setState(() => _cat = c['id'] as String))),
          ]),
        ),
        SizedBox(height: narrow ? HPSpace.md : HPSpace.lg),
        Expanded(
          child: items.isEmpty
              ? const EmptyState(title: 'No dishes in this category')
              : GridView.extent(maxCrossAxisExtent: narrow ? 210 : 220, mainAxisSpacing: narrow ? HPSpace.sm : HPSpace.md, crossAxisSpacing: narrow ? HPSpace.sm : HPSpace.md, childAspectRatio: narrow ? 1.05 : .95, children: [
                  for (final i in items)
                    // feedback on phones is the Order tab label (count + total), not a toast that would cover the buttons
                    _DishTile(item: i, enabled: editable && i['available'] == 1, onAdd: () => _do(() => _api.addLines(widget.orderId, [{'menuItemId': i['id'], 'qty': 1}]))),
                ]),
        ),
      ]),
    );

    final orderPane = Container(
      decoration: BoxDecoration(color: HPColors.ember, border: narrow ? null : const Border(left: BorderSide(color: HPColors.clayLine))),
      padding: EdgeInsets.all(narrow ? HPSpace.lg : HPSpace.x2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(title, style: HPType.titleScreen(HPColors.ghee), overflow: TextOverflow.ellipsis)),
          if (o['table_id'] != null && session.can('order.transfer') && (o['status'] == 'open' || o['status'] == 'billed'))
            TextButton.icon(onPressed: _transfer, icon: const Icon(Icons.swap_horiz_rounded), label: const Text('Transfer')),
        ]),
        Wrap(spacing: HPSpace.xs, runSpacing: HPSpace.xs, children: [
          StatusChip(label: '${o['status']}', tone: o['status'] == 'open' ? HPTone.saffron : HPTone.danger),
          for (final k in tickets)
            StatusChip(
              key: Key('kot-${k['kot_no']}-${k['status']}'),
              label: 'KOT ${k['kot_no']}: ${k['status']}',
              icon: k['status'] == 'ready' ? Icons.notifications_active_rounded : Icons.soup_kitchen_outlined,
              tone: switch (k['status']) { 'ready' => HPTone.success, 'served' => HPTone.neutral, _ => HPTone.pending },
            ),
        ]),
        const SizedBox(height: HPSpace.md),
        Expanded(
          child: ListView(children: [
            if (sent.isNotEmpty) Text('IN THE KITCHEN', style: HPType.overline(HPColors.husk)),
            for (final l in sent) _LineRow(line: l, onReverse: session.can('order.reverse') && o['status'] != 'paid' ? () => _reverse(l) : null),
            if (sent.isNotEmpty && pending.isNotEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: HPSpace.sm), child: Divider()),
            if (pending.isNotEmpty) Text('NEW', style: HPType.overline(HPColors.saffron)),
            for (final l in pending)
              _LineRow(
                line: l,
                stepper: editable ? QtyStepper(qty: l['qty'] as int, onChanged: (q) => _do(() => _api.updateLine(widget.orderId, l['id'] as String, qty: q))) : null,
                onReverse: session.can('order.reverse') ? () => _reverse(l) : null,
              ),
            if (reversed.isNotEmpty) ...[
              const SizedBox(height: HPSpace.sm),
              for (final l in reversed) Text('✕ ${l['name_snapshot']} — ${l['reversal_reason']}', style: HPType.body(HPColors.smoke).copyWith(decoration: TextDecoration.lineThrough)),
            ],
            if (lines.isEmpty) Padding(padding: const EdgeInsets.only(top: HPSpace.x4), child: EmptyState(title: narrow ? 'Add dishes from the Menu tab' : 'Tap a dish to add it')),
          ]),
        ),
        const Divider(),
        _TotalRow('Subtotal', totals['subtotalPaise'] as int),
        _TotalRow('CGST', totals['cgstPaise'] as int),
        _TotalRow('SGST', totals['sgstPaise'] as int),
        _TotalRow('Round-off', totals['roundOffPaise'] as int),
        Row(children: [
          Text('To pay', style: HPType.label(HPColors.husk)),
          const Spacer(),
          Text(formatPaise(totals['totalPaise'] as int), key: const Key('order-total'), style: HPType.displayTotal(HPColors.saffron).copyWith(fontSize: narrow ? 30 : 36)),
        ]),
        const SizedBox(height: HPSpace.md),
        Row(children: [
          if (session.can('order.write')) ...[
            Expanded(child: SecondaryButton(label: 'Send KOT', onPressed: editable && pending.isNotEmpty ? () => _do(() => _api.sendKot(widget.orderId)) : null)),
            const SizedBox(width: HPSpace.sm),
          ],
          Expanded(
            child: canBill
                ? PrimaryButton(
                    label: 'Bill & pay',
                    height: 56,
                    onPressed: (o['status'] == 'open' || o['status'] == 'billed') && lines.any((l) => l['status'] != 'reversed')
                        ? () async {
                            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BillScreen(orderId: widget.orderId)));
                            await _load();
                          }
                        : null,
                  )
                : Text(session.can('order.write') ? 'The cashier bills this order' : 'Read-only', textAlign: TextAlign.center, style: HPType.body(HPColors.husk)),
          ),
        ]),
      ]),
    );

    return Scaffold(
      body: Column(children: [
        StatusBar(title: title),
        Expanded(
          child: narrow
              ? DefaultTabController(
                  length: 2,
                  initialIndex: editable ? 0 : 1,
                  child: Column(children: [
                    TabBar(tabs: [
                      const Tab(key: Key('tab-menu'), text: 'Menu'),
                      Tab(key: const Key('tab-order'), text: 'Order · ${lines.where((l) => l['status'] != 'reversed').length} · ${formatPaise(totals['totalPaise'] as int)}'),
                    ]),
                    Expanded(child: TabBarView(children: [menuPane, orderPane])),
                  ]),
                )
              : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: menuPane), SizedBox(width: 400, child: orderPane)]),
        ),
      ]),
    );
  }

  String _tableName(Json o) => '${o['table_name'] ?? ''}';
}

class _DishTile extends StatelessWidget {
  const _DishTile({required this.item, required this.enabled, required this.onAdd});
  final Json item;
  final bool enabled;
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext context) {
    final pc = item['plate_colors'] as Map?;
    return Card(
      child: InkWell(
        key: Key('dish-${item['name']}'),
        borderRadius: BorderRadius.circular(HPRadius.card),
        onTap: enabled ? onAdd : null,
        child: LayoutBuilder(builder: (c, box) {
          final small = box.maxWidth < 170; // phones: two compact columns
          return Padding(
            padding: EdgeInsets.all(small ? HPSpace.sm : HPSpace.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                PlateIcon(base: _hex(pc?['base'], HPColors.saffron), sauce: _hex(pc?['sauce'], HPColors.ghee), garnish: _hex(pc?['garnish'], HPColors.cardamom), size: small ? 40 : 56),
                const Spacer(),
                VegMark(isVeg: item['is_veg'] == 1 || item['is_veg'] == true),
              ]),
              const Spacer(),
              Text('${item['name']}', style: HPType.titleCard(HPColors.ghee).copyWith(fontSize: small ? 15 : 17), maxLines: 2, overflow: TextOverflow.ellipsis),
              Row(children: [
                Expanded(child: Text(formatPaise(item['price_paise'] as int), style: HPType.label(HPColors.husk), overflow: TextOverflow.ellipsis)),
                Icon(Icons.add_circle_rounded, color: enabled ? HPColors.saffron : HPColors.smoke, size: small ? 22 : 24),
              ]),
            ]),
          );
        }),
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, this.stepper, this.onReverse});
  final Json line;
  final Widget? stepper;
  final VoidCallback? onReverse;
  @override
  Widget build(BuildContext context) {
    final amount = (line['qty'] as int) * (line['price_snapshot_paise'] as int);
    final sent = line['status'] == 'sent';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HPSpace.xs),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${sent ? '${line['qty']} × ' : ''}${line['name_snapshot']}', style: HPType.label(sent ? HPColors.husk : HPColors.ghee)),
            if ((line['notes'] ?? '') != '') Text('${line['notes']}', style: HPType.note()),
          ]),
        ),
        ?stepper,
        const SizedBox(width: HPSpace.sm),
        Text(formatPaise(amount), style: HPType.label(HPColors.ghee)),
        if (onReverse != null) IconButton(key: Key('reverse-${line['name_snapshot']}'), tooltip: 'Reverse item', icon: const Icon(Icons.undo_rounded, size: 18), onPressed: onReverse),
      ]),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow(this.label, this.paise);
  final String label;
  final int paise;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [Text(label, style: HPType.body(HPColors.husk)), const Spacer(), Text(formatPaise(paise), style: HPType.body(HPColors.husk))]),
      );
}

/// C5 Bill preview + discount, C7 tip with waiter picker, C6 payment across modes with an idempotency key per attempt.
class BillScreen extends ConsumerStatefulWidget {
  const BillScreen({super.key, required this.orderId});
  final String orderId;
  @override
  ConsumerState<BillScreen> createState() => _BillScreenState();
}

class _BillScreenState extends ConsumerState<BillScreen> {
  Json? _order;
  Json? _bill;
  int? _discountBp;
  final _discountReason = TextEditingController();
  String _mode = 'cash';
  String _amount = '';
  String? _pendingKey; // reused if the same payment attempt is retried
  int _paid = 0;
  final _payments = <Json>[];
  bool _busy = false;
  int? _change;

  HubApi get _api => ref.read(hubApiProvider)!;

  @override
  void initState() {
    super.initState();
    _api.order(widget.orderId).then((o) => setState(() {
          _order = o;
          _bill = o['bill'] as Json?;
        }));
  }

  int get _total => (_bill?['total_paise'] as int?) ?? 0;
  int get _remaining => _total - _paid;

  Future<void> _generate() async {
    setState(() => _busy = true);
    try {
      final b = await _api.bill(widget.orderId,
          discount: _discountBp == null ? null : {'type': 'percent', 'bp': _discountBp},
          discountReason: _discountReason.text.trim().isEmpty ? null : _discountReason.text.trim());
      setState(() => _bill = b);
      // Build Spec §13: the bill prints when generated — only if a bill printer is set up
      if (mounted) unawaited(printBillWithFeedback(context, _api, b['id'] as String, ifPrinter: true));
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _tip() async {
    final staff = await _api.staff();
    if (!mounted) return;
    final waiters = staff.where((s) => (s['roles'] as List).contains('waiter')).toList();
    int amount = 0;
    String? waiter = _order?['waiter_id'] as String?;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => HPDialog(title: 'Add tip', actions: [
          SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c)),
          PrimaryButton(label: 'Add tip', height: 56, onPressed: amount > 0 && waiter != null ? () => Navigator.pop(c, true) : null),
        ], child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Amount', style: HPType.overline(HPColors.husk)),
          Wrap(spacing: HPSpace.sm, children: [
            for (final r in [20, 50, 100, 200]) ChoiceChip(label: Text('₹$r'), selected: amount == r * 100, onSelected: (_) => set(() => amount = r * 100)),
          ]),
          const SizedBox(height: HPSpace.lg),
          Text('Waiter', style: HPType.overline(HPColors.husk)),
          Wrap(spacing: HPSpace.sm, children: [
            for (final w in waiters) ChoiceChip(key: Key('tip-waiter-${w['name']}'), label: Text('${w['name']}'), selected: waiter == w['id'], onSelected: (_) => set(() => waiter = w['id'] as String)),
          ]),
        ])),
      ),
    );
    if (ok != true) return;
    try {
      await _api.tip(_bill!['id'] as String, amountPaise: amount, waiterId: waiter);
      final o = await _api.order(widget.orderId);
      setState(() { _order = o; _bill = o['bill'] as Json?; });
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    }
  }

  Future<void> _pay() async {
    final rupees = int.tryParse(_amount);
    if (rupees == null || rupees <= 0) return;
    final paise = _mode == 'cash' ? rupees * 100 : (rupees * 100 > _remaining ? _remaining : rupees * 100);
    _pendingKey ??= newIdempotencyKey();
    setState(() => _busy = true);
    try {
      final r = await _api.pay(_bill!['id'] as String, _pendingKey!,
          mode: _mode, tenderedPaise: _mode == 'cash' ? paise : null, amountPaise: _mode == 'cash' ? null : paise);
      _pendingKey = null; // success: the next payment is a new attempt
      setState(() {
        _payments.add(r);
        _paid += r['amountPaise'] as int;
        _amount = '';
        if (r['billStatus'] == 'paid') _change = r['changePaise'] as int;
      });
    } catch (e) {
      // keep _pendingKey: tapping Pay again retries the SAME attempt and cannot double-charge
      if (mounted) toast(context, '${errText(e)} — tap Pay to retry safely', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    if (session == null) return const SizedBox.shrink(); // signing out: this screen is being closed
    if (_order == null) return const Scaffold(body: LoadingState());
    final totals = _bill == null ? _order!['totals'] as Json : null;
    Widget paidView() => Column(children: [
      const Icon(Icons.check_circle_rounded, size: 72, color: HPColors.cardamom),
      Text('Paid', style: HPType.titleScreen(HPColors.ghee)),
      if (_change! > 0) Text('Change due ${formatPaise(_change!)}', key: const Key('change-due'), style: HPType.displayTotal(HPColors.saffron)),
      const SizedBox(height: HPSpace.x2),
      SecondaryButton(key: const Key('paid-print'), label: 'Print bill', icon: Icons.print_rounded, onPressed: () => printBillWithFeedback(context, _api, _bill!['id'] as String)),
      const SizedBox(height: HPSpace.sm),
      PrimaryButton(label: 'Back to tables', onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst)),
    ]);
    final summary = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(HPSpace.x2),
          child: Column(children: [
            _TotalRow('Subtotal', (_bill?['subtotal_paise'] ?? totals!['subtotalPaise']) as int),
            _TotalRow('Discount', -((_bill?['discount_paise'] ?? totals!['discountPaise']) as int)),
            _TotalRow('CGST', (_bill?['cgst_paise'] ?? totals!['cgstPaise']) as int),
            _TotalRow('SGST', (_bill?['sgst_paise'] ?? totals!['sgstPaise']) as int),
            _TotalRow('Tip', (_bill?['tip_paise'] ?? totals!['tipPaise']) as int),
            _TotalRow('Round-off', (_bill?['round_off_paise'] ?? totals!['roundOffPaise']) as int),
            const Divider(),
            Row(children: [
              Text(_bill == null ? 'Total' : 'Remaining', style: HPType.label(HPColors.husk)),
              const Spacer(),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(formatPaise(_bill == null ? totals!['totalPaise'] as int : _remaining), key: const Key('amount-due'), style: HPType.displayTotal(HPColors.saffron)),
                ),
              ),
            ]),
          ]),
        ),
      ),
      if (_bill != null) ...[
        const SizedBox(height: HPSpace.sm),
        Row(children: [
          Text('PAYMENT', style: HPType.overline(HPColors.husk)),
          const Spacer(),
          if (_paid == 0) TextButton.icon(onPressed: _tip, icon: const Icon(Icons.volunteer_activism_outlined), label: const Text('Add tip')),
        ]),
        for (final p in _payments) ListTile(dense: true, title: Text('${p['mode']}'.toUpperCase()), trailing: Text(formatPaise(p['amountPaise'] as int))),
      ],
    ]);
    final generate = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (session.can('discount.apply')) ...[
        Text('DISCOUNT', style: HPType.overline(HPColors.husk)),
        Wrap(spacing: HPSpace.sm, children: [
          for (final bp in [null, 500, 1000, 1500]) ChoiceChip(label: Text(bp == null ? 'None' : '${bp ~/ 100}%'), selected: _discountBp == bp, onSelected: (_) => setState(() => _discountBp = bp)),
        ]),
        if ((_discountBp ?? 0) > 1000) TextField(controller: _discountReason, decoration: const InputDecoration(labelText: 'Reason (required above 10%)')),
        const SizedBox(height: HPSpace.lg),
      ],
      PrimaryButton(label: 'Generate bill', busy: _busy, onPressed: _generate),
    ]);
    final payment = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'cash', label: Text('Cash'), icon: Icon(Icons.payments_outlined)),
          ButtonSegment(value: 'upi', label: Text('UPI'), icon: Icon(Icons.qr_code_2_rounded)),
          ButtonSegment(value: 'card', label: Text('Card'), icon: Icon(Icons.credit_card_rounded)),
        ],
        selected: {_mode},
        onSelectionChanged: (s) => setState(() { _mode = s.first; _pendingKey = null; }),
      ),
      const SizedBox(height: HPSpace.sm),
      Text(_amount.isEmpty ? '₹0' : '₹$_amount', key: const Key('entered-amount'), textAlign: TextAlign.center, style: HPType.displayTotal(HPColors.ghee).copyWith(fontSize: 36)),
      NumericKeypad(
        onKey: (d) => setState(() { _amount = _amount.length < 7 ? _amount + d : _amount; _pendingKey = null; }),
        onBackspace: () => setState(() { _amount = _amount.isEmpty ? '' : _amount.substring(0, _amount.length - 1); _pendingKey = null; }),
        onClear: () => setState(() { _amount = ''; _pendingKey = null; }),
        quickAmounts: [('Exact', (_remaining + 99) ~/ 100), ('₹500', 500), ('₹1,000', 1000), ('₹2,000', 2000)],
        onQuickAmount: (v) => setState(() { _amount = '$v'; _pendingKey = null; }),
      ),
      const SizedBox(height: HPSpace.sm),
      PrimaryButton(label: 'Pay ${_mode.toUpperCase()}', busy: _busy, onPressed: _amount.isEmpty ? null : _pay),
    ]);
    // Wide screens (tablet / PC): totals left, keypad right, so the Pay button is always on screen.
    final wide = MediaQuery.sizeOf(context).width >= 900 && _bill != null && _change == null;
    Widget scroll(Widget child, double maxWidth) => SingleChildScrollView(
          padding: const EdgeInsets.all(HPSpace.lg),
          child: Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child)),
        );
    return Scaffold(
      body: Column(children: [
        StatusBar(title: _bill == null ? 'Bill preview' : 'Bill ${_bill!['invoice_no']}'),
        Expanded(
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: scroll(summary, 520)),
                  Expanded(child: scroll(payment, 480)),
                ])
              : scroll(
                  _change != null
                      ? paidView()
                      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          summary,
                          const SizedBox(height: HPSpace.lg),
                          if (_bill == null) generate else payment,
                        ]),
                  560),
        ),
      ]),
    );
  }
}

/// C8 Bill history for today.
class BillHistoryScreen extends ConsumerWidget {
  const BillHistoryScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(hubApiProvider)!;
    ref.watch(hubTickProvider);
    return Scaffold(
      body: Column(children: [
        const StatusBar(title: 'Bill history'),
        Expanded(
          child: FutureBuilder<List<Json>>(
            future: api.bills(DateTime.now()),
            builder: (c, s) {
              if (s.hasError) return ErrorState(message: errText(s.error!));
              if (!s.hasData) return const LoadingState();
              if (s.data!.isEmpty) return const EmptyState(title: 'No bills yet today', icon: Icons.receipt_long_rounded);
              return ListView(padding: const EdgeInsets.all(HPSpace.x2), children: [
                for (final b in s.data!)
                  Padding(
                    padding: const EdgeInsets.only(bottom: HPSpace.sm),
                    child: OrderCard(
                        key: Key('bill-${b['invoice_no']}'),
                        title: '${b['invoice_no']}',
                        subtitle: _localTime('${b['created_at']}'),
                        total: formatPaise(b['total_paise'] as int),
                        status: '${b['status']}',
                        tone: b['status'] == 'paid' ? HPTone.success : HPTone.saffron,
                        onTap: () => showBillActions(context, ref, b)),
                  ),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}
