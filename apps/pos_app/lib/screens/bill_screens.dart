import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';
import '../state/app_state.dart';
import '../ui/common.dart';
import '../ui/shell.dart';

/// C5 Bill preview + discount, C7 tip with waiter picker, C6 payment across modes with an idempotency key per attempt.
/// Wide screens: receipt preview on the left, "Still to collect" + keypad on the right. Phones: one column.
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
    _api.order(widget.orderId).then((o) {
      if (!mounted) return;
      setState(() {
        _order = o;
        _bill = o['bill'] as Json?;
      });
    });
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
          Text('AMOUNT', style: HPType.overline(c.hp.muted)),
          const SizedBox(height: HPSpace.sm),
          Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
            for (final r in [20, 50, 100, 200]) ChoiceChip(label: Text('₹$r'), selected: amount == r * 100, onSelected: (_) => set(() => amount = r * 100)),
          ]),
          const SizedBox(height: HPSpace.lg),
          Text('GOES TO', style: HPType.overline(c.hp.muted)),
          const SizedBox(height: HPSpace.sm),
          Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
            for (final w in waiters) ChoiceChip(key: Key('tip-waiter-${w['name']}'), label: Text('${w['name']}'), selected: waiter == w['id'], onSelected: (_) => set(() => waiter = w['id'] as String)),
          ]),
        ])),
      ),
    );
    if (ok != true) return;
    try {
      await _api.tip(_bill!['id'] as String, amountPaise: amount, waiterId: waiter);
      final o = await _api.order(widget.orderId);
      setState(() {
        _order = o;
        _bill = o['bill'] as Json?;
      });
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    }
  }

  Future<void> _pay() async {
    final rupeesIn = int.tryParse(_amount);
    if (rupeesIn == null || rupeesIn <= 0) return;
    final paise = _mode == 'cash' ? rupeesIn * 100 : (rupeesIn * 100 > _remaining ? _remaining : rupeesIn * 100);
    _pendingKey ??= newIdempotencyKey();
    setState(() => _busy = true);
    try {
      final r = await _api.pay(_bill!['id'] as String, _pendingKey!, mode: _mode, tenderedPaise: _mode == 'cash' ? paise : null, amountPaise: _mode == 'cash' ? null : paise);
      _pendingKey = null; // success: the next payment is a new attempt
      HapticFeedback.mediumImpact();
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

  void _setAmount(String v) => setState(() {
        _amount = v;
        _pendingKey = null;
      });

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    if (session == null) return const SizedBox.shrink(); // signing out: this screen is being closed
    if (_order == null) return const Scaffold(body: LoadingState());
    final p = context.hp;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final title = _bill == null ? 'Bill preview' : 'Bill ${_bill!['invoice_no']}';
    final where = _order!['table_id'] == null ? 'Takeaway' : 'Table ${_order!['table_name'] ?? ''}';

    if (_change != null) {
      return Scaffold(
        body: Column(children: [
          PosTopBar(title: where, subtitle: title),
          Expanded(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(HPSpace.x2), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: _paidView(p))))),
        ]),
      );
    }

    final receipt = _Receipt(order: _order!, bill: _bill, discountPreviewBp: _discountBp);
    final right = _bill == null ? _generatePanel(session, p) : _paymentPanel(p);
    return Scaffold(
      body: Column(children: [
        PosTopBar(title: where, subtitle: title),
        Expanded(
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(HPSpace.x2), child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: receipt)))),
                  VerticalDivider(width: 1, color: p.line),
                  Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(HPSpace.x2), child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: right)))),
                ])
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(HPSpace.lg),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [receipt, const SizedBox(height: HPSpace.lg), right]),
                ),
        ),
      ]),
    );
  }

  Widget _paidView(HPPalette p) => Column(children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutBack,
          builder: (_, v, _) => Transform.scale(
            scale: v,
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(color: p.success.withValues(alpha: .16), shape: BoxShape.circle),
              child: Icon(Icons.check_rounded, size: 56, color: p.success),
            ),
          ),
        ),
        const SizedBox(height: HPSpace.lg),
        Text('Paid', style: HPType.titleScreen(p.text)),
        Text('${_bill!['invoice_no']} · ${rupees(_total)}', style: HPType.mono(p.muted)),
        const SizedBox(height: HPSpace.lg),
        if (_change! > 0)
          Container(
            padding: const EdgeInsets.all(HPSpace.lg),
            decoration: BoxDecoration(color: p.success.withValues(alpha: .12), borderRadius: BorderRadius.circular(HPRadius.card)),
            child: Column(children: [
              Text('CHANGE TO RETURN', style: HPType.overline(p.muted)),
              Text('Change due ${formatPaise(_change!)}', key: const Key('change-due'), style: HPType.displayTotal(p.success).copyWith(fontSize: 34), textAlign: TextAlign.center),
            ]),
          ),
        const SizedBox(height: HPSpace.x2),
        SecondaryButton(key: const Key('paid-print'), label: 'Print bill', icon: Icons.print_rounded, onPressed: () => printBillWithFeedback(context, _api, _bill!['id'] as String)),
        const SizedBox(height: HPSpace.sm),
        PrimaryButton(label: 'Back to tables', icon: Icons.table_restaurant_rounded, onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst)),
      ]);

  Widget _generatePanel(StaffSession session, HPPalette p) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (session.can('discount.apply')) ...[
          Text('DISCOUNT', style: HPType.overline(p.muted)),
          const SizedBox(height: HPSpace.sm),
          Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
            for (final bp in [null, 500, 1000, 1500, 2000]) ChoiceChip(label: Text(bp == null ? 'None' : '${bp ~/ 100}%'), selected: _discountBp == bp, onSelected: (_) => setState(() => _discountBp = bp)),
          ]),
          if ((_discountBp ?? 0) > 1000) ...[
            const SizedBox(height: HPSpace.sm),
            TextField(controller: _discountReason, decoration: const InputDecoration(labelText: 'Reason (required above 10%)')),
          ],
          const SizedBox(height: HPSpace.x2),
        ],
        Text('Generating the bill locks the order and issues the invoice number.', style: HPType.body(p.muted)),
        const SizedBox(height: HPSpace.md),
        PrimaryButton(key: const Key('generate-bill'), label: 'Generate bill', icon: Icons.receipt_long_rounded, busy: _busy, onPressed: _generate),
      ]);

  Widget _paymentPanel(HPPalette p) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('STILL TO COLLECT', style: HPType.overline(p.muted)),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: FittedBox(
            key: ValueKey(_remaining),
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(formatPaise(_remaining), style: HPType.displayTotal(p.accentInk)),
          ),
        ),
        Text(_paid == 0 ? 'of ${formatPaise(_total)}' : '${formatPaise(_paid)} received of ${formatPaise(_total)}', key: const Key('amount-due'), style: HPType.body(p.muted)),
        for (final pay in _payments)
          Padding(
            padding: const EdgeInsets.only(top: HPSpace.xs),
            child: Row(children: [
              Icon(Icons.check_circle_rounded, size: 16, color: p.success),
              const SizedBox(width: HPSpace.sm),
              Text('${pay['mode']}'.toUpperCase(), style: HPType.label(p.text)),
              const Spacer(),
              Text(formatPaise(pay['amountPaise'] as int), style: HPType.label(p.text)),
            ]),
          ),
        const SizedBox(height: HPSpace.md),
        Row(children: [
          Expanded(
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'cash', label: Text('Cash'), icon: Icon(Icons.payments_outlined)),
                ButtonSegment(value: 'upi', label: Text('UPI'), icon: Icon(Icons.qr_code_2_rounded)),
                ButtonSegment(value: 'card', label: Text('Card'), icon: Icon(Icons.credit_card_rounded)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() {
                _mode = s.first;
                _pendingKey = null;
              }),
            ),
          ),
        ]),
        if (_paid == 0) Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: _tip, icon: const Icon(Icons.volunteer_activism_outlined, size: 18), label: const Text('Add tip'))),
        Container(
          margin: const EdgeInsets.symmetric(vertical: HPSpace.sm),
          padding: const EdgeInsets.symmetric(vertical: HPSpace.sm),
          decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(HPRadius.card)),
          child: Text(_amount.isEmpty ? '₹0' : '₹$_amount', key: const Key('entered-amount'), textAlign: TextAlign.center, style: HPType.displayTotal(_amount.isEmpty ? p.faint : p.text).copyWith(fontSize: 36)),
        ),
        NumericKeypad(
          onKey: (d) => _setAmount(_amount.length < 7 ? _amount + d : _amount),
          onBackspace: () => _setAmount(_amount.isEmpty ? '' : _amount.substring(0, _amount.length - 1)),
          onClear: () => _setAmount(''),
          quickAmounts: [('Exact', (_remaining + 99) ~/ 100), ('₹500', 500), ('₹1,000', 1000), ('₹2,000', 2000)],
          onQuickAmount: (v) => _setAmount('$v'),
        ),
        const SizedBox(height: HPSpace.md),
        PrimaryButton(label: 'Pay ${_mode.toUpperCase()}', icon: Icons.lock_rounded, busy: _busy, onPressed: _amount.isEmpty ? null : _pay),
      ]);
}

/// Receipt-style preview: lines, discount, CGST / SGST, tip, round-off and the total.
class _Receipt extends StatelessWidget {
  const _Receipt({required this.order, required this.bill, this.discountPreviewBp});
  final Json order;
  final Json? bill;
  final int? discountPreviewBp;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final lines = (order['lines'] as List).cast<Json>().where((l) => l['status'] != 'reversed').toList();
    final t = order['totals'] as Json;
    int v(String billKey, String totalsKey) => (bill?[billKey] ?? t[totalsKey]) as int;
    Widget row(String l, int paise, {bool strong = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Text(l, style: (strong ? HPType.label(p.text) : HPType.body(p.muted))),
            const Spacer(),
            Text(formatPaise(paise), style: strong ? HPType.label(p.text) : HPType.mono(p.muted)),
          ]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HPSpace.x2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: HPSpace.md, runSpacing: 4, children: [
            Text(bill == null ? 'PREVIEW' : 'TAX INVOICE', style: HPType.overline(p.muted)),
            if (bill != null) Text('${bill!['invoice_no']}', style: HPType.mono(p.text)),
          ]),
          const SizedBox(height: HPSpace.md),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 32, child: Text('${l['qty']}×', style: HPType.mono(p.muted))),
                Expanded(child: Text('${l['name_snapshot']}', style: HPType.body(p.text))),
                Text(formatPaise((l['qty'] as int) * (l['price_snapshot_paise'] as int)), style: HPType.mono(p.text)),
              ]),
            ),
          Padding(padding: const EdgeInsets.symmetric(vertical: HPSpace.sm), child: Divider(color: p.line)),
          row('Subtotal', v('subtotal_paise', 'subtotalPaise')),
          if (v('discount_paise', 'discountPaise') != 0) row('Discount', -v('discount_paise', 'discountPaise')),
          if (bill == null && discountPreviewBp != null) Text('${discountPreviewBp! ~/ 100}% discount applies when you generate the bill', style: HPType.body(p.accentInk).copyWith(fontSize: 12)),
          row('CGST', v('cgst_paise', 'cgstPaise')),
          row('SGST', v('sgst_paise', 'sgstPaise')),
          if (v('tip_paise', 'tipPaise') != 0) row('Tip', v('tip_paise', 'tipPaise')),
          if (v('round_off_paise', 'roundOffPaise') != 0) row('Round-off', v('round_off_paise', 'roundOffPaise')),
          Padding(padding: const EdgeInsets.symmetric(vertical: HPSpace.sm), child: Divider(color: p.line)),
          Row(children: [
            Text('Total', style: HPType.titleCard(p.text)),
            const SizedBox(width: HPSpace.md),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(formatPaise(v('total_paise', 'totalPaise')), style: HPType.titleCard(p.text).copyWith(fontSize: 26)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------- C8 history

/// C8 Bill history for today: totals at the top, search by invoice number, tap a bill to reprint or adjust it.
class BillHistoryScreen extends ConsumerStatefulWidget {
  const BillHistoryScreen({super.key});
  @override
  ConsumerState<BillHistoryScreen> createState() => _BillHistoryScreenState();
}

class _BillHistoryScreenState extends ConsumerState<BillHistoryScreen> {
  String _q = '';
  int _refresh = 0;
  @override
  Widget build(BuildContext context) {
    final api = ref.watch(hubApiProvider)!;
    ref.watch(hubTickProvider);
    final p = context.hp;
    final narrow = isNarrow(context);
    return Scaffold(
      body: Column(children: [
        const PosTopBar(title: 'Bills', subtitle: 'Today'),
        Expanded(
          child: FutureBuilder<List<Json>>(
            key: ValueKey(_refresh),
            future: api.bills(DateTime.now()),
            builder: (c, s) {
              if (s.hasError) return ErrorState(message: errText(s.error!), onRetry: () => setState(() => _refresh++));
              if (!s.hasData) return const LoadingState();
              final all = s.data!.reversed.toList();
              final paid = all.where((b) => b['status'] == 'paid').toList();
              final bills = all.where((b) => _q.isEmpty || '${b['invoice_no']}'.toLowerCase().contains(_q.toLowerCase())).toList();
              return RefreshIndicator(
                onRefresh: () async => setState(() => _refresh++),
                child: ListView(padding: EdgeInsets.all(narrow ? HPSpace.lg : HPSpace.x2), children: [
                  Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, children: [
                    SizedBox(width: narrow ? double.infinity : 260, child: KpiCard(label: 'Collected today', value: rupees(paid.fold(0, (n, b) => n + (b['total_paise'] as int))), caption: '${paid.length} paid bills', icon: Icons.payments_outlined, tone: HPTone.success)),
                    if (all.length > paid.length)
                      SizedBox(width: narrow ? double.infinity : 260, child: KpiCard(label: 'Open bills', value: '${all.length - paid.length}', caption: 'waiting for payment', icon: Icons.hourglass_bottom_rounded, tone: HPTone.saffron)),
                  ]),
                  const SizedBox(height: HPSpace.lg),
                  HPSearchField(hint: 'Search invoice number', onChanged: (v) => setState(() => _q = v.trim())),
                  const SizedBox(height: HPSpace.lg),
                  if (bills.isEmpty)
                    const Padding(padding: EdgeInsets.only(top: HPSpace.x4), child: EmptyState(title: 'No bills yet today', icon: Icons.receipt_long_rounded))
                  else
                    for (final b in bills)
                      Padding(
                        padding: const EdgeInsets.only(bottom: HPSpace.sm),
                        child: OrderCard(
                          key: Key('bill-${b['invoice_no']}'),
                          title: '${b['invoice_no']}',
                          subtitle: clock12(b['created_at']),
                          total: formatPaise(b['total_paise'] as int),
                          status: b['status'] == 'paid' ? 'Paid' : 'Open',
                          tone: b['status'] == 'paid' ? HPTone.success : HPTone.saffron,
                          onTap: () => showBillActions(context, ref, b),
                        ),
                      ),
                  Text(' ', style: HPType.body(p.muted)),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// Bill actions from history: reprint (DUPLICATE) and, for paid bills, a correction with reason (+ owner PIN for cashiers).
Future<void> showBillActions(BuildContext context, WidgetRef ref, Json bill) async {
  final api = ref.read(hubApiProvider)!;
  final s = ref.read(sessionProvider)!;
  final paid = bill['status'] == 'paid';
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text('${bill['invoice_no']}', style: HPType.titleCard(c.hp.text)), subtitle: Text('${formatPaise(bill['total_paise'] as int)} · ${clock12(bill['created_at'])}')),
        if (s.can('payment.take')) ListTile(key: const Key('bill-reprint'), leading: const Icon(Icons.print_rounded), title: const Text('Reprint bill (DUPLICATE)'), onTap: () => Navigator.pop(c, 'print')),
        if (paid && s.can('payment.take')) ListTile(key: const Key('bill-adjust'), leading: const Icon(Icons.edit_note_rounded), title: const Text('Adjust paid bill'), subtitle: const Text('Refund or extra charge with a reason'), onTap: () => Navigator.pop(c, 'adjust')),
        if (!s.can('payment.take')) const ListTile(leading: Icon(Icons.visibility_outlined), title: Text('Read-only: bills are reprinted and adjusted by the cashier or owner.')),
        const SizedBox(height: HPSpace.sm),
      ]),
    ),
  );
  if (!context.mounted || choice == null) return;
  if (choice == 'print') return printBillWithFeedback(context, api, bill['id'] as String);
  await _adjust(context, api, s, bill);
}

Future<void> printBillWithFeedback(BuildContext context, HubApi api, String billId, {bool ifPrinter = false}) async {
  try {
    final r = await api.printBill(billId, ifPrinter: ifPrinter);
    if (!context.mounted) return;
    switch (r['status']) {
      case 'printed':
        toast(context, (r['copyNo'] as int? ?? 1) > 1 ? 'Duplicate bill printed' : 'Bill printed');
      case 'no_printer':
        break; // auto-print after billing: nothing set up, stay quiet
      default:
        toast(context, r['error'] == 'printer_unreachable' ? 'Printer not reachable — check it is on and on the same Wi-Fi' : 'No bill printer set up (More → Printers)', error: true);
    }
  } catch (e) {
    if (context.mounted) toast(context, errText(e), error: true);
  }
}

Future<void> _adjust(BuildContext context, HubApi api, StaffSession s, Json bill) async {
  final amount = TextEditingController(), reason = TextEditingController();
  bool refund = true;
  String? approver;
  String pin = '';
  final needPin = !s.can('bill.adjust');
  final owners = needPin ? (await api.staff()).where((u) => (u['roles'] as List).contains('owner')).toList() : const <Json>[];
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        final rupeesIn = int.tryParse(amount.text) ?? 0;
        final ready = rupeesIn > 0 && reason.text.trim().length >= 3 && (!needPin || (approver != null && pin.length >= 4));
        return HPDialog(
          title: 'Adjust ${bill['invoice_no']}',
          actions: [
            SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c)),
            DangerButton(label: 'Post adjustment', onPressed: ready ? () => Navigator.pop(c, true) : null),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Paid bills are never edited. This posts a correction that shows in reports and the audit log.', style: HPType.body(c.hp.muted)),
            const SizedBox(height: HPSpace.md),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [ButtonSegment(value: true, label: Text('Refund')), ButtonSegment(value: false, label: Text('Extra charge'))],
              selected: {refund},
              onSelectionChanged: (v) => set(() => refund = v.first),
            ),
            const SizedBox(height: HPSpace.sm),
            TextField(key: const Key('adjust-amount'), controller: amount, keyboardType: TextInputType.number, onChanged: (_) => set(() {}), decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ ')),
            const SizedBox(height: HPSpace.sm),
            TextField(key: const Key('adjust-reason'), controller: reason, onChanged: (_) => set(() {}), decoration: const InputDecoration(labelText: 'Reason (required)')),
            if (needPin) ...[
              const SizedBox(height: HPSpace.md),
              Text('Owner approval needed', style: HPType.body(c.hp.accentInk)),
              Wrap(spacing: HPSpace.sm, children: [
                for (final o in owners) ChoiceChip(label: Text('${o['name']}'), selected: approver == o['id'], onSelected: (_) => set(() => approver = o['id'] as String)),
              ]),
              TextField(
                key: const Key('adjust-pin'),
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                onChanged: (v) => set(() => pin = v.trim()),
                decoration: const InputDecoration(labelText: 'Owner PIN', counterText: ''),
              ),
            ],
          ]),
        );
      },
    ),
  );
  if (ok != true) return;
  try {
    final paise = int.parse(amount.text) * 100;
    await api.adjust(bill['id'] as String, amountPaise: refund ? -paise : paise, reason: reason.text.trim(), approverUserId: approver, approverPin: needPin ? pin : null);
    if (context.mounted) toast(context, 'Adjustment posted');
  } catch (e) {
    if (context.mounted) toast(context, errText(e), error: true);
  }
}
