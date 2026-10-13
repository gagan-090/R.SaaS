import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';
import '../state/app_state.dart';
import '../ui/common.dart';
import '../ui/media.dart';
import '../ui/shell.dart';
import 'bill_screens.dart';

const quickNotes = ['Less spicy', 'Extra spicy', 'No onion', 'No garlic', 'Jain', 'Extra butter', 'Pack separately'];

/// C2 Order screen (+ C3 transfer, C4 reversal, kitchen notes). Tablets: menu + order panel side by side.
/// Phones: the menu with a sticky cart bar; the order opens as a sheet.
class OrderScreen extends ConsumerStatefulWidget {
  const OrderScreen({super.key, required this.orderId});
  final String orderId;
  @override
  ConsumerState<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends ConsumerState<OrderScreen> {
  String? _cat;
  String _q = '';
  Json? _order;
  Json? _menu;
  Object? _error;
  bool _sending = false;
  StateSetter? _sheetSet; // rebuilds the order sheet on phones after each change

  HubApi get _api => ref.read(hubApiProvider)!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([_api.order(widget.orderId), if (_menu == null) _api.menu()]);
      if (!mounted) return;
      setState(() {
        _order = r[0];
        if (r.length > 1) _menu = r[1];
        _error = null;
      });
      _sheetSet?.call(() {});
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _do(Future<Object?> Function() f, {String? done}) async {
    try {
      await f();
      await _load();
      if (done != null && mounted) toast(context, done);
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    }
  }

  Future<void> _add(Json item) async {
    HapticFeedback.selectionClick();
    await _do(() => _api.addLines(widget.orderId, [{'menuItemId': item['id'], 'qty': 1}]));
  }

  Future<void> _sendKot() async {
    setState(() => _sending = true);
    _sheetSet?.call(() {});
    try {
      final r = await _api.sendKot(widget.orderId);
      await _load();
      if (mounted) toast(context, 'KOT #${r['kotNo']} sent to the kitchen');
      HapticFeedback.mediumImpact();
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
      _sheetSet?.call(() {});
    }
  }

  Future<void> _note(Json line) async {
    final c = TextEditingController(text: '${line['notes'] ?? ''}');
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (s) => Padding(
        padding: EdgeInsets.fromLTRB(HPSpace.lg, 0, HPSpace.lg, MediaQuery.viewInsetsOf(s).bottom + HPSpace.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Note for the kitchen · ${line['name_snapshot']}', style: HPType.titleCard(s.hp.text)),
          const SizedBox(height: HPSpace.md),
          Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
            for (final n in quickNotes)
              ActionChip(label: Text(n), onPressed: () => c.text = c.text.trim().isEmpty ? n : '${c.text.trim()}, $n'),
          ]),
          const SizedBox(height: HPSpace.md),
          TextField(key: const Key('line-note'), controller: c, autofocus: true, maxLength: 120, decoration: const InputDecoration(labelText: 'Note')),
          PrimaryButton(key: const Key('save-note'), label: 'Save note', height: 52, onPressed: () => Navigator.pop(s, c.text.trim())),
        ]),
      ),
    );
    if (saved != null) await _do(() => _api.updateLine(widget.orderId, line['id'] as String, notes: saved));
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
            Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
              for (final r in ['Guest changed mind', 'Wrong item', 'Kitchen out of stock'])
                ActionChip(label: Text(r), onPressed: () => set(() => reason.text = r)),
            ]),
            const SizedBox(height: HPSpace.sm),
            TextField(key: const Key('reverse-reason'), controller: reason, onChanged: (_) => set(() {}), decoration: const InputDecoration(labelText: 'Reason (required)')),
            if (needPin) ...[
              const SizedBox(height: HPSpace.lg),
              Text('Already in the kitchen — owner approval needed', style: HPType.body(c.hp.accentInk)),
              const SizedBox(height: HPSpace.sm),
              Wrap(spacing: HPSpace.sm, children: [
                for (final m in managers) ChoiceChip(label: Text('${m['name']}'), selected: approver == m['id'], onSelected: (_) => set(() => approver = m['id'] as String)),
              ]),
              const SizedBox(height: HPSpace.sm),
              TextField(
                key: const Key('approver-pin'),
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                onChanged: (v) => set(() => pin = v.trim()),
                decoration: const InputDecoration(labelText: 'Owner PIN', counterText: '', prefixIcon: Icon(Icons.pin_outlined)),
              ),
            ],
          ]),
        ),
      ),
    );
    if (ok != true) return;
    await _do(() => _api.reverseLine(widget.orderId, line['id'] as String, reason: reason.text.trim(), approverUserId: approver, approverPin: needPin ? pin : null), done: '${line['name_snapshot']} reversed');
  }

  Future<void> _transfer() async {
    final state = await _api.state();
    if (!mounted) return;
    final free = (state['tables'] as List).cast<Json>().where((t) => t['status'] == 'free').toList();
    final to = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(HPSpace.lg, 0, HPSpace.lg, HPSpace.lg),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Move to which table?', style: HPType.titleCard(c.hp.text)),
            const SizedBox(height: HPSpace.md),
            if (free.isEmpty)
              Text('No free tables right now.', style: HPType.body(c.hp.muted))
            else
              Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, children: [
                for (final t in free) TableTile(key: Key('move-${t['name']}'), name: '${t['name']}', seats: t['seats'] as int, state: TableState.free, onTap: () => Navigator.pop(c, t['id'] as String)),
              ]),
          ]),
        ),
      ),
    );
    if (to != null) await _do(() => _api.transfer(widget.orderId, to), done: 'Order moved');
  }

  Future<void> _bill() async {
    if (Navigator.of(context).canPop() && _sheetSet != null) Navigator.of(context).pop(); // close the phone sheet first
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BillScreen(orderId: widget.orderId)));
    await _load();
  }

  Future<void> _openSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .9,
        maxChildSize: .95,
        minChildSize: .5,
        builder: (c, scroll) => StatefulBuilder(builder: (c, set) {
          _sheetSet = set;
          return _orderPanel(c, scroll: scroll, inSheet: true);
        }),
      ),
    );
    _sheetSet = null;
  }

  int _qtyFor(String itemId) {
    final lines = ((_order?['lines'] as List?) ?? const []).cast<Json>();
    return lines.where((l) => l['menu_item_id'] == itemId && l['status'] != 'reversed').fold(0, (n, l) => n + (l['qty'] as int));
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
    if (_error != null) return Scaffold(body: Column(children: [const PosTopBar(title: 'Order'), Expanded(child: ErrorState(message: errText(_error!), onRetry: _load))]));
    if (_order == null || _menu == null) return const Scaffold(body: LoadingState());
    final o = _order!;
    final narrow = isNarrow(context);
    final lines = (o['lines'] as List).cast<Json>().where((l) => l['status'] != 'reversed').toList();
    final count = lines.fold<int>(0, (n, l) => n + (l['qty'] as int));
    final pending = lines.where((l) => l['status'] == 'pending').length;
    final totals = o['totals'] as Json;
    final title = o['table_id'] == null ? 'Takeaway' : 'Table ${o['table_name'] ?? ''}';
    final canTransfer = o['table_id'] != null && session.can('order.transfer') && (o['status'] == 'open' || o['status'] == 'billed');

    final top = PosTopBar(
      title: title,
      subtitle: ['${minutesSince(o['opened_at'])} min', if (count > 0) '$count items', '${o['status']}'].join(' · '),
      actions: [if (canTransfer) IconButton(key: const Key('transfer'), tooltip: 'Move to another table', icon: const Icon(Icons.swap_horiz_rounded), onPressed: _transfer)],
    );

    if (!narrow) {
      return Scaffold(
        body: Column(children: [
          top,
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: _menuPane(session, narrow: false)),
              VerticalDivider(width: 1, color: context.hp.line),
              SizedBox(width: 420, child: _orderPanel(context)),
            ]),
          ),
        ]),
      );
    }
    return Scaffold(
      body: Column(children: [top, Expanded(child: _menuPane(session, narrow: true))]),
      bottomNavigationBar: _CartBar(
        count: count,
        totalPaise: totals['totalPaise'] as int,
        pendingLines: pending,
        busy: _sending,
        canSend: o['status'] == 'open' && session.can('order.write'),
        onSend: _sendKot,
        onOpen: _openSheet,
      ),
    );
  }

  Widget _menuPane(StaffSession session, {required bool narrow}) {
    final o = _order!;
    final editable = o['status'] == 'open' && session.can('order.write');
    final cats = (_menu!['categories'] as List).cast<Json>();
    final cat = _cat ?? (cats.isEmpty ? null : cats.first['id'] as String);
    final all = (_menu!['items'] as List).cast<Json>();
    final items = _q.isNotEmpty ? all.where((i) => '${i['name']}'.toLowerCase().contains(_q.toLowerCase())).toList() : all.where((i) => i['category_id'] == cat).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? HPSpace.md : HPSpace.lg, HPSpace.sm, narrow ? HPSpace.md : HPSpace.lg, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        HPSearchField(key: const Key('menu-search'), hint: 'Search ${all.length} dishes', onChanged: (v) => setState(() => _q = v.trim())),
        const SizedBox(height: HPSpace.md),
        if (_q.isEmpty)
          SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final c in cats)
                Padding(
                  padding: const EdgeInsets.only(right: HPSpace.sm),
                  child: CategoryChip(label: '${c['name']}', count: all.where((i) => i['category_id'] == c['id']).length, selected: c['id'] == cat, onTap: () => setState(() => _cat = c['id'] as String)),
                ),
            ]),
          ),
        const SizedBox(height: HPSpace.md),
        Expanded(
          child: items.isEmpty
              ? EmptyState(title: _q.isEmpty ? 'No dishes in this category' : 'No dish matches "$_q"', icon: Icons.search_off_rounded)
              : GridView.builder(
                  padding: const EdgeInsets.only(bottom: HPSpace.lg),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: narrow ? 200 : 210,
                    mainAxisSpacing: narrow ? HPSpace.sm : HPSpace.md,
                    crossAxisSpacing: narrow ? HPSpace.sm : HPSpace.md,
                    childAspectRatio: narrow ? .98 : .95,
                  ),
                  itemCount: items.length,
                  itemBuilder: (c, i) => MenuDishCard(
                    key: Key('dish-${items[i]['name']}'),
                    item: items[i],
                    qty: _qtyFor(items[i]['id'] as String),
                    enabled: editable,
                    onTap: () => _add(items[i]),
                  ),
                ),
        ),
      ]),
    );
  }

  Widget _orderPanel(BuildContext context, {ScrollController? scroll, bool inSheet = false}) {
    final session = ref.read(sessionProvider);
    if (session == null || _order == null) return const SizedBox.shrink();
    final p = context.hp;
    final o = _order!;
    final lines = (o['lines'] as List).cast<Json>();
    final pending = lines.where((l) => l['status'] == 'pending').toList();
    final sent = lines.where((l) => l['status'] == 'sent').toList();
    final reversed = lines.where((l) => l['status'] == 'reversed').toList();
    final tickets = ((o['tickets'] as List?) ?? const []).cast<Json>();
    final totals = o['totals'] as Json;
    final editable = o['status'] == 'open' && session.can('order.write');
    final canBill = session.can('payment.take');
    final ready = tickets.where((k) => k['status'] == 'ready').toList();

    return Container(
      color: inSheet ? null : p.surface,
      padding: EdgeInsets.fromLTRB(HPSpace.lg, inSheet ? 0 : HPSpace.lg, HPSpace.lg, HPSpace.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (inSheet) Text(o['table_id'] == null ? 'Takeaway' : 'Table ${o['table_name'] ?? ''}', style: HPType.titleScreen(p.text).copyWith(fontSize: 26)),
        if (ready.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: HPSpace.sm),
            padding: const EdgeInsets.symmetric(horizontal: HPSpace.md, vertical: HPSpace.sm),
            decoration: BoxDecoration(color: p.success.withValues(alpha: .14), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(Icons.notifications_active_rounded, color: p.success, size: 18),
              const SizedBox(width: HPSpace.sm),
              Expanded(child: Text('Ready at the pass: KOT ${ready.map((k) => '#${k['kot_no']}').join(', ')}', style: HPType.label(p.text))),
            ]),
          ),
        Wrap(spacing: HPSpace.xs, runSpacing: HPSpace.xs, children: [
          for (final k in tickets)
            StatusChip(
              key: Key('kot-${k['kot_no']}-${k['status']}'),
              label: 'KOT ${k['kot_no']} · ${k['status']}',
              icon: k['status'] == 'ready' ? Icons.notifications_active_rounded : Icons.soup_kitchen_outlined,
              tone: switch (k['status']) { 'ready' => HPTone.success, 'served' => HPTone.neutral, _ => HPTone.pending },
            ),
        ]),
        const SizedBox(height: HPSpace.sm),
        Expanded(
          child: ListView(controller: scroll, children: [
            if (sent.isNotEmpty) ...[
              SectionHeader('In the kitchen', trailing: Icon(Icons.lock_outline_rounded, size: 14, color: p.faint)),
              for (final l in sent) _LineRow(line: l, onReverse: session.can('order.reverse') && o['status'] != 'paid' ? () => _reverse(l) : null),
            ],
            if (sent.isNotEmpty && pending.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: HPSpace.sm), child: CustomPaint(painter: _Dashes(p.line), size: const Size(double.infinity, 1))),
            if (pending.isNotEmpty) ...[
              SectionHeader('New · not sent yet'),
              for (final l in pending)
                _LineRow(
                  line: l,
                  isNew: true,
                  onNote: editable ? () => _note(l) : null,
                  stepper: editable ? QtyStepper(qty: l['qty'] as int, onChanged: (q) => _do(() => _api.updateLine(widget.orderId, l['id'] as String, qty: q))) : null,
                  onReverse: session.can('order.reverse') ? () => _reverse(l) : null,
                ),
            ],
            if (reversed.isNotEmpty) ...[
              const SizedBox(height: HPSpace.sm),
              for (final l in reversed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('✕ ${l['name_snapshot']} — ${l['reversal_reason']}', style: HPType.body(p.faint).copyWith(decoration: TextDecoration.lineThrough)),
                ),
            ],
            if (lines.isEmpty) const Padding(padding: EdgeInsets.only(top: HPSpace.x4), child: EmptyState(title: 'Nothing ordered yet', message: 'Tap dishes on the menu to add them.', icon: Icons.restaurant_rounded)),
          ]),
        ),
        Divider(color: p.line),
        _TotalRow('Subtotal', totals['subtotalPaise'] as int),
        _TotalRow('CGST', totals['cgstPaise'] as int),
        _TotalRow('SGST', totals['sgstPaise'] as int),
        if (totals['roundOffPaise'] != 0) _TotalRow('Round-off', totals['roundOffPaise'] as int),
        Row(children: [
          Text('To pay', style: HPType.label(p.muted)),
          const Spacer(),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0, .3), end: Offset.zero).animate(a), child: c)),
            child: Text(formatPaise(totals['totalPaise'] as int), key: ValueKey(totals['totalPaise']), style: HPType.displayTotal(p.accentInk).copyWith(fontSize: 34)),
          ),
        ]),
        const SizedBox(height: HPSpace.md),
        Row(children: [
          if (session.can('order.write')) ...[
            Expanded(
              child: SecondaryButton(
                key: const Key('send-kot'),
                label: pending.isEmpty ? 'Send KOT' : 'Send KOT · ${pending.length}',
                icon: Icons.soup_kitchen_outlined,
                onPressed: editable && pending.isNotEmpty && !_sending ? _sendKot : null,
              ),
            ),
            const SizedBox(width: HPSpace.sm),
          ],
          Expanded(
            child: canBill
                ? PrimaryButton(
                    key: const Key('bill-pay'),
                    label: o['status'] == 'billed' ? 'Collect payment' : 'Bill & pay',
                    height: 56,
                    onPressed: (o['status'] == 'open' || o['status'] == 'billed') && lines.any((l) => l['status'] != 'reversed') ? _bill : null,
                  )
                : Text(session.can('order.write') ? 'The cashier bills this order' : 'Read-only', textAlign: TextAlign.center, style: HPType.body(p.muted)),
          ),
        ]),
      ]),
    );
  }
}

/// Phone cart bar: what is on the order, one tap to send the new items, one tap to review.
class _CartBar extends StatelessWidget {
  const _CartBar({required this.count, required this.totalPaise, required this.pendingLines, required this.busy, required this.canSend, required this.onSend, required this.onOpen});
  final int count, totalPaise, pendingLines;
  final bool busy, canSend;
  final VoidCallback onSend, onOpen;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return Material(
      color: p.surface,
      elevation: 0,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
          padding: const EdgeInsets.fromLTRB(HPSpace.md, HPSpace.sm, HPSpace.md, HPSpace.sm),
          child: Row(children: [
            Expanded(
              child: InkWell(
                key: const Key('view-order'),
                borderRadius: BorderRadius.circular(14),
                onTap: onOpen,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HPSpace.sm, vertical: HPSpace.xs),
                  child: Row(children: [
                    Badge(
                      isLabelVisible: count > 0,
                      label: Text('$count'),
                      backgroundColor: HPColors.saffron,
                      textColor: HPColors.onSaffron,
                      child: Icon(Icons.receipt_long_rounded, color: p.text),
                    ),
                    const SizedBox(width: HPSpace.md),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(rupees(totalPaise), key: const Key('cart-total'), style: HPType.titleCard(p.text).copyWith(fontSize: 20)),
                        Text(count == 0 ? 'Order is empty' : 'View order · $count items', style: HPType.body(p.muted).copyWith(fontSize: 12)),
                      ]),
                    ),
                    Icon(Icons.keyboard_arrow_up_rounded, color: p.muted),
                  ]),
                ),
              ),
            ),
            if (canSend)
              SizedBox(
                width: 150,
                child: PrimaryButton(
                  key: const Key('cart-send-kot'),
                  label: pendingLines == 0 ? 'Send KOT' : 'Send · $pendingLines',
                  icon: Icons.soup_kitchen_rounded,
                  height: 52,
                  busy: busy,
                  onPressed: pendingLines > 0 ? onSend : null,
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, this.stepper, this.onReverse, this.onNote, this.isNew = false});
  final Json line;
  final Widget? stepper;
  final VoidCallback? onReverse, onNote;
  final bool isNew;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final amount = (line['qty'] as int) * (line['price_snapshot_paise'] as int);
    final notes = '${line['notes'] ?? ''}';
    return TweenAnimationBuilder<double>(
      // a new line glows saffron briefly, then settles (STYLE.md §9)
      tween: Tween(begin: isNew ? 1 : 0, end: 0),
      duration: const Duration(milliseconds: 600),
      builder: (c, v, child) => Container(
        decoration: BoxDecoration(color: HPColors.saffron.withValues(alpha: .18 * v), borderRadius: BorderRadius.circular(10)),
        child: child,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onNote,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: HPSpace.xs, horizontal: 2),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${isNew ? '' : '${line['qty']} × '}${line['name_snapshot']}', style: HPType.label(isNew ? p.text : p.muted)),
                if (notes.isNotEmpty) Text(notes, style: HPType.note(p.note))
                else if (onNote != null) Text('Add note', style: HPType.body(p.faint).copyWith(fontSize: 12)),
              ]),
            ),
            ?stepper,
            const SizedBox(width: HPSpace.sm),
            Text(rupees(amount), style: HPType.label(p.text)),
            if (onReverse != null) IconButton(key: Key('reverse-${line['name_snapshot']}'), tooltip: 'Reverse item', icon: const Icon(Icons.undo_rounded, size: 18), onPressed: onReverse),
          ]),
        ),
      ),
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
        child: Row(children: [Text(label, style: HPType.body(context.hp.muted)), const Spacer(), Text(formatPaise(paise), style: HPType.body(context.hp.muted))]),
      );
}

class _Dashes extends CustomPainter {
  _Dashes(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, 0), Offset(x + 4, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_Dashes o) => o.color != color;
}
