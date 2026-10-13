import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';
import '../state/app_state.dart';
import 'service_screens.dart';
import 'setup_screens.dart';

/// Phones and small tablets get single-column layouts below this width.
const narrowBreakpoint = 720.0;
bool isNarrow(BuildContext c) => MediaQuery.sizeOf(c).width < narrowBreakpoint;

/// Role-filtered destinations for the menu in the status bar. Every entry is also enforced by the hub.
List<(String label, IconData icon, Widget Function() page)> destinationsFor(StaffSession s, {required bool isHub}) => [
      if (s.can('order.read')) ('Tables', Icons.table_restaurant_rounded, () => const TableMapScreen()),
      if (s.can('kds.read')) ('Kitchen display', Icons.soup_kitchen_rounded, () => const KitchenScreen()),
      if (s.can('order.read')) ('Bill history', Icons.receipt_long_rounded, () => const BillHistoryScreen()),
      if (s.can('reports.read') || s.can('reports.own') || s.can('payment.take')) ('Tips', Icons.volunteer_activism_rounded, () => const TipsScreen()),
      if (s.can('device.manage')) ('Printers', Icons.print_rounded, () => const PrintersScreen()),
      if (isHub || s.can('device.manage')) ('Hub & devices', Icons.router_rounded, () => const HubStatusScreen()),
    ];

/// The "More" menu shown in the status bar for a signed-in user.
class RoleMenuButton extends ConsumerWidget {
  const RoleMenuButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    if (s == null) return const SizedBox.shrink();
    final dest = destinationsFor(s, isHub: ref.watch(setupProvider).valueOrNull?.isHub ?? false);
    return PopupMenuButton<int>(
      key: const Key('role-menu'),
      tooltip: 'Menu',
      icon: const Icon(Icons.menu_rounded),
      onSelected: (i) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => dest[i].$3())),
      itemBuilder: (_) => [
        for (var i = 0; i < dest.length; i++)
          PopupMenuItem(value: i, child: ListTile(dense: true, leading: Icon(dest[i].$2), title: Text(dest[i].$1))),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------- K1 Kitchen display

/// K1: live ticket queue. Chefs move tickets through preparing → ready → served; other roles watch.
class KitchenScreen extends ConsumerStatefulWidget {
  const KitchenScreen({super.key});
  @override
  ConsumerState<KitchenScreen> createState() => _KitchenScreenState();
}

class _KitchenScreenState extends ConsumerState<KitchenScreen> {
  Timer? _clock;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    // ticket ages tick even when nothing else changes
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _move(HubApi api, Json t, String status) async {
    setState(() => _busy.add(t['id'] as String));
    try {
      await api.setTicketStatus(t['id'] as String, status);
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(t['id']));
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(hubApiProvider)!;
    final s = ref.watch(sessionProvider);
    if (s == null) return const SizedBox.shrink(); // signing out: this screen is being closed
    ref.watch(hubTickProvider);
    final canUpdate = s.can('kds.update');
    return Scaffold(
      body: Column(children: [
        const StatusBar(title: 'Kitchen'),
        Expanded(
          child: FutureBuilder<List<Json>>(
            future: api.kdsTickets(),
            builder: (c, snap) {
              if (snap.hasError) return ErrorState(message: errText(snap.error!), onRetry: () => setState(() {}));
              if (!snap.hasData) return const LoadingState();
              final tickets = snap.data!;
              if (tickets.isEmpty) return const EmptyState(icon: Icons.soup_kitchen_outlined, title: 'No tickets', message: 'New KOTs appear here the moment they are sent.');
              final width = MediaQuery.sizeOf(context).width;
              final cardW = width < 420 ? width - 2 * HPSpace.lg : 340.0;
              return RefreshIndicator(
                onRefresh: () async => setState(() {}),
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(HPSpace.lg),
                  child: Wrap(spacing: HPSpace.lg, runSpacing: HPSpace.lg, children: [
                    for (final t in tickets) SizedBox(width: cardW, child: _TicketCard(ticket: t, canUpdate: canUpdate, busy: _busy.contains(t['id']), onMove: (st) => _move(api, t, st))),
                  ]),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _TicketCard extends StatelessWidget {
  const _TicketCard({required this.ticket, required this.canUpdate, required this.busy, required this.onMove});
  final Json ticket;
  final bool canUpdate, busy;
  final ValueChanged<String> onMove;

  @override
  Widget build(BuildContext context) {
    final status = ticket['status'] as String;
    final age = DateTime.now().toUtc().difference(DateTime.parse(ticket['createdAt'] as String)).inMinutes;
    final (tone, next, nextLabel) = switch (status) {
      'new' => (HPTone.danger, 'preparing', 'Start'),
      'preparing' => (HPTone.saffron, 'ready', 'Ready'),
      'ready' => (HPTone.success, 'served', 'Served'),
      _ => (HPTone.neutral, null, null),
    };
    return Card(
      key: Key('ticket-${ticket['kotNo']}'),
      child: Padding(
        padding: const EdgeInsets.all(HPSpace.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('KOT #${ticket['kotNo']} · ${ticket['where']}', style: HPType.titleCard(HPColors.ghee), overflow: TextOverflow.ellipsis)),
            StatusChip(label: status, tone: tone),
          ]),
          const SizedBox(height: HPSpace.xs),
          Text('${ticket['waiter'] ?? 'No waiter'} · ${age < 1 ? 'just now' : '$age min'}', style: HPType.body(age >= 15 && status != 'ready' ? HPColors.chili : HPColors.husk)),
          const Divider(),
          for (final l in (ticket['lines'] as List).cast<Json>())
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${l['qty']} × ${l['name']}${l['reversed'] == true ? '  (CANCELLED)' : ''}',
                    style: HPType.label(l['reversed'] == true ? HPColors.smoke : HPColors.ghee)
                        .copyWith(decoration: l['reversed'] == true ? TextDecoration.lineThrough : null, fontSize: 17)),
                if ((l['notes'] ?? '') != '') Text('${l['notes']}', style: HPType.note()),
              ]),
            ),
          if (canUpdate && next != null) ...[
            const SizedBox(height: HPSpace.md),
            Row(children: [
              if (status == 'new')
                Expanded(child: SecondaryButton(label: 'Ready', height: 48, onPressed: busy ? null : () => onMove('ready'))),
              if (status == 'new') const SizedBox(width: HPSpace.sm),
              Expanded(child: PrimaryButton(key: Key('ticket-${ticket['kotNo']}-$next'), label: nextLabel!, height: 48, busy: busy, onPressed: () => onMove(next))),
            ]),
          ],
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------- Tips

class TipsScreen extends ConsumerWidget {
  const TipsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(hubApiProvider)!;
    ref.watch(hubTickProvider);
    return Scaffold(
      body: Column(children: [
        const StatusBar(title: 'Tips'),
        Expanded(
          child: FutureBuilder<List<Json>>(
            future: api.tips(),
            builder: (c, s) {
              if (s.hasError) return ErrorState(message: errText(s.error!));
              if (!s.hasData) return const LoadingState();
              if (s.data!.isEmpty) return const EmptyState(icon: Icons.volunteer_activism_outlined, title: 'No tips yet');
              return ListView(padding: const EdgeInsets.all(HPSpace.x2), children: [
                for (final r in s.data!)
                  Card(
                    child: ListTile(
                      title: Text('${r['waiter_name'] ?? r['waiter_id']}', style: HPType.label(HPColors.ghee)),
                      subtitle: Text('${r['bills']} bill(s)', style: HPType.body(HPColors.husk)),
                      trailing: Text(formatPaise(r['tip_paise'] as int), style: HPType.titleCard(HPColors.saffron)),
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

// ------------------------------------------------------------------------------------------- T3 Printers

class PrintersScreen extends ConsumerStatefulWidget {
  const PrintersScreen({super.key});
  @override
  ConsumerState<PrintersScreen> createState() => _PrintersScreenState();
}

class _PrintersScreenState extends ConsumerState<PrintersScreen> {
  final _host = {'bill': TextEditingController(), 'kot': TextEditingController()};
  final _port = {'bill': TextEditingController(text: '9100'), 'kot': TextEditingController(text: '9100')};
  final _width = {'bill': 48, 'kot': 48};
  bool _loaded = false, _busy = false;
  Object? _error;

  HubApi get _api => ref.read(hubApiProvider)!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await _api.printers();
      for (final t in ['bill', 'kot']) {
        final m = p[t] as Map?;
        if (m == null) continue;
        _host[t]!.text = '${m['host']}';
        _port[t]!.text = '${m['port']}';
        _width[t] = m['widthChars'] as int? ?? 48;
      }
      setState(() => _loaded = true);
    } catch (e) {
      setState(() => _error = e);
    }
  }

  Json _settings() => {
        for (final t in ['bill', 'kot'])
          t: _host[t]!.text.trim().isEmpty ? null : {'host': _host[t]!.text.trim(), 'port': int.tryParse(_port[t]!.text) ?? 9100, 'widthChars': _width[t]},
      };

  Future<void> _run(Future<Object?> Function() f, String ok) async {
    setState(() => _busy = true);
    try {
      await f();
      if (mounted) toast(context, ok);
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _section(String target, String title, String help) => Card(
        child: Padding(
          padding: const EdgeInsets.all(HPSpace.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: HPType.titleCard(HPColors.ghee)),
            Text(help, style: HPType.body(HPColors.husk)),
            const SizedBox(height: HPSpace.md),
            TextField(key: Key('printer-$target-host'), controller: _host[target], keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Printer IP (blank = none)')),
            const SizedBox(height: HPSpace.sm),
            TextField(controller: _port[target], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port')),
            const SizedBox(height: HPSpace.sm),
            SegmentedButton<int>(
              segments: const [ButtonSegment(value: 48, label: Text('80 mm')), ButtonSegment(value: 32, label: Text('58 mm'))],
              selected: {_width[target]!},
              onSelectionChanged: (v) => setState(() => _width[target] = v.first),
            ),
            const SizedBox(height: HPSpace.sm),
            SecondaryButton(label: 'Test print', icon: Icons.print_outlined, height: 48,
                onPressed: _busy ? null : () => _run(() async { await _api.savePrinters(_settings()); return _api.testPrint(target); }, 'Test page sent')),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          const StatusBar(title: 'Printers'),
          Expanded(
            child: _error != null
                ? ErrorState(message: errText(_error!), onRetry: () => setState(() { _error = null; _load(); }))
                : !_loaded
                    ? const LoadingState()
                    : Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: ListView(padding: const EdgeInsets.all(HPSpace.lg), children: [
                            _section('bill', 'Bill printer', 'Customer bills and reprints. With no printer, bills are available as PDF.'),
                            const SizedBox(height: HPSpace.md),
                            _section('kot', 'Kitchen printer', 'KOTs. Leave blank to print KOTs on the bill printer.'),
                            const SizedBox(height: HPSpace.lg),
                            PrimaryButton(key: const Key('printers-save'), label: 'Save', busy: _busy, onPressed: () => _run(() => _api.savePrinters(_settings()), 'Printers saved')),
                          ]),
                        ),
                      ),
          ),
        ]),
      );
}

// ------------------------------------------------------------------------------------------- IT admin home

/// IT admin: no service screens (no order permissions) — printers, devices and sync instead.
class AdminHomeScreen extends ConsumerWidget {
  const AdminHomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(hubApiProvider)!;
    ref.watch(hubTickProvider);
    Widget tile(String title, String sub, IconData icon, Widget Function() page) => Card(
          child: ListTile(
            key: Key('admin-$title'),
            contentPadding: const EdgeInsets.all(HPSpace.lg),
            leading: Icon(icon, color: HPColors.saffron, size: 32),
            title: Text(title, style: HPType.titleCard(HPColors.ghee)),
            subtitle: Text(sub, style: HPType.body(HPColors.husk)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page())),
          ),
        );
    return Scaffold(
      body: Column(children: [
        const StatusBar(title: 'Setup'),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(padding: const EdgeInsets.all(HPSpace.lg), children: [
                tile('Printers', 'Bill and kitchen printers, test print', Icons.print_rounded, () => const PrintersScreen()),
                tile('Hub & devices', 'Pairing QR for new terminals, sync health', Icons.router_rounded, () => const HubStatusScreen()),
                const SizedBox(height: HPSpace.lg),
                FutureBuilder<Json>(
                  future: api.syncStatus(),
                  builder: (c, s) => !s.hasData
                      ? const SizedBox.shrink()
                      : Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
                          StatusChip(label: '${s.data!['pending']} waiting to sync', tone: (s.data!['pending'] as int) > 0 ? HPTone.saffron : HPTone.success),
                          StatusChip(label: '${s.data!['failed']} failed', tone: (s.data!['failed'] as int) > 0 ? HPTone.danger : HPTone.neutral),
                          StatusChip(label: 'last cloud pull ${s.data!['lastPullAt'] ?? 'never'}', tone: HPTone.neutral),
                        ]),
                ),
                const SizedBox(height: HPSpace.lg),
                Text('Menu, tables and staff are managed in the cloud and arrive here automatically.', style: HPType.body(HPColors.husk)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------- C9 adjustment + reprint

/// Bill actions from history: reprint (DUPLICATE) and, for paid bills, a correction with reason (+ owner PIN for cashiers).
Future<void> showBillActions(BuildContext context, WidgetRef ref, Json bill) async {
  final api = ref.read(hubApiProvider)!;
  final s = ref.read(sessionProvider)!;
  final paid = bill['status'] == 'paid';
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text('${bill['invoice_no']}', style: HPType.titleCard()), subtitle: Text(formatPaise(bill['total_paise'] as int))),
        if (s.can('payment.take')) ListTile(key: const Key('bill-reprint'), leading: const Icon(Icons.print_rounded), title: const Text('Reprint bill (DUPLICATE)'), onTap: () => Navigator.pop(c, 'print')),
        if (paid && s.can('payment.take')) ListTile(key: const Key('bill-adjust'), leading: const Icon(Icons.edit_note_rounded), title: const Text('Adjust paid bill'), onTap: () => Navigator.pop(c, 'adjust')),
        if (!s.can('payment.take')) const ListTile(title: Text('Read-only: bills are reprinted and adjusted by the cashier or owner.')),
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
        toast(context, r['error'] == 'printer_unreachable' ? 'Printer not reachable — check it is on and on the same Wi-Fi' : 'No bill printer set up (Menu → Printers)', error: true);
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
        final rupees = int.tryParse(amount.text) ?? 0;
        final ready = rupees > 0 && reason.text.trim().length >= 3 && (!needPin || (approver != null && pin.length >= 4));
        return HPDialog(
          title: 'Adjust ${bill['invoice_no']}',
          actions: [
            SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c)),
            DangerButton(label: 'Post adjustment', onPressed: ready ? () => Navigator.pop(c, true) : null),
          ],
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Paid bills are never edited. This posts a correction that shows in reports and the audit log.', style: HPType.body(HPColors.husk)),
              const SizedBox(height: HPSpace.md),
              SegmentedButton<bool>(
                segments: const [ButtonSegment(value: true, label: Text('Refund / reduce')), ButtonSegment(value: false, label: Text('Add charge'))],
                selected: {refund},
                onSelectionChanged: (v) => set(() => refund = v.first),
              ),
              const SizedBox(height: HPSpace.sm),
              TextField(key: const Key('adjust-amount'), controller: amount, keyboardType: TextInputType.number, onChanged: (_) => set(() {}), decoration: const InputDecoration(labelText: 'Amount in ₹', prefixText: '₹ ')),
              const SizedBox(height: HPSpace.sm),
              TextField(key: const Key('adjust-reason'), controller: reason, onChanged: (_) => set(() {}), decoration: const InputDecoration(labelText: 'Reason (required)')),
              if (needPin) ...[
                const SizedBox(height: HPSpace.md),
                Text('Owner approval needed', style: HPType.body(HPColors.saffronTint)),
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
          ),
        );
      },
    ),
  );
  if (ok != true) return;
  try {
    final paise = (int.parse(amount.text)) * 100;
    await api.adjust(bill['id'] as String, amountPaise: refund ? -paise : paise, reason: reason.text.trim(), approverUserId: approver, approverPin: needPin ? pin : null);
    if (context.mounted) toast(context, 'Adjustment posted');
  } catch (e) {
    if (context.mounted) toast(context, errText(e), error: true);
  }
}
