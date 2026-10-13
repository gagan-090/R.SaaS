import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';
import '../state/app_state.dart';
import '../ui/common.dart';
import '../ui/shell.dart';

/// K1 Kitchen display: New → Preparing → Ready columns (tablets) or a status filter (phones). Readable from 2 m:
/// big table names, quantity badges, notes in italic, and an age bar (green < 10 min, saffron 10–20, red > 20).
class KitchenScreen extends ConsumerStatefulWidget {
  const KitchenScreen({super.key});
  @override
  ConsumerState<KitchenScreen> createState() => _KitchenScreenState();
}

class _KitchenScreenState extends ConsumerState<KitchenScreen> {
  Timer? _clock;
  final _busy = <String>{};
  String _filter = 'all';
  int _refresh = 0;

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
      HapticFeedback.mediumImpact();
      if (mounted) setState(() => _refresh++);
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
    if (s == null) return const SizedBox.shrink();
    ref.watch(hubTickProvider);
    final canUpdate = s.can('kds.update');
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final p = context.hp;
    return Scaffold(
      body: Column(children: [
        PosTopBar(title: 'Kitchen', subtitle: clock12(DateTime.now().toIso8601String())),
        Expanded(
          child: FutureBuilder<List<Json>>(
            key: ValueKey(_refresh),
            future: api.kdsTickets(),
            builder: (c, snap) {
              if (snap.hasError) return ErrorState(message: errText(snap.error!), onRetry: () => setState(() => _refresh++));
              if (!snap.hasData) return const SkeletonGrid(maxExtent: 340, aspect: 1.2, count: 4);
              final tickets = snap.data!;
              if (tickets.isEmpty) {
                return const EmptyState(icon: Icons.soup_kitchen_outlined, title: 'No tickets', message: 'New KOTs appear here the moment a waiter or cashier sends them.');
              }
              Widget card(Json t) => _TicketCard(key: Key('ticket-${t['kotNo']}'), ticket: t, canUpdate: canUpdate, busy: _busy.contains(t['id']), onMove: (st) => _move(api, t, st));
              const columns = [('new', 'New'), ('preparing', 'Preparing'), ('ready', 'Ready to serve')];
              if (wide) {
                return Padding(
                  padding: const EdgeInsets.all(HPSpace.lg),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final (st, label) in columns) ...[
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          SectionHeader('$label · ${tickets.where((t) => t['status'] == st).length}'),
                          Expanded(
                            child: ListView(children: [
                              for (final t in tickets.where((t) => t['status'] == st)) Padding(padding: const EdgeInsets.only(bottom: HPSpace.md), child: card(t)),
                            ]),
                          ),
                        ]),
                      ),
                      if (st != 'ready') const SizedBox(width: HPSpace.lg),
                    ],
                  ]),
                );
              }
              final shown = tickets.where((t) => _filter == 'all' || t['status'] == _filter).toList();
              return Column(children: [
                SizedBox(
                  height: 56,
                  child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: HPSpace.lg, vertical: 6), children: [
                    for (final (st, label) in [('all', 'All'), ...columns])
                      Padding(
                        padding: const EdgeInsets.only(right: HPSpace.sm),
                        child: CategoryChip(label: label.split(' ').first, count: st == 'all' ? tickets.length : tickets.where((t) => t['status'] == st).length, selected: _filter == st, onTap: () => setState(() => _filter = st)),
                      ),
                  ]),
                ),
                Expanded(
                  child: shown.isEmpty
                      ? EmptyState(title: 'Nothing here', icon: Icons.check_circle_outline_rounded, message: 'No ${_filter == 'all' ? '' : '$_filter '}tickets right now.')
                      : RefreshIndicator(
                          onRefresh: () async => setState(() => _refresh++),
                          child: ListView(padding: const EdgeInsets.fromLTRB(HPSpace.lg, 0, HPSpace.lg, HPSpace.lg), children: [
                            for (final t in shown) Padding(padding: const EdgeInsets.only(bottom: HPSpace.md), child: card(t)),
                            Text(' ', style: HPType.body(p.muted)),
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

class _TicketCard extends StatelessWidget {
  const _TicketCard({super.key, required this.ticket, required this.canUpdate, required this.busy, required this.onMove});
  final Json ticket;
  final bool canUpdate, busy;
  final ValueChanged<String> onMove;

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final status = ticket['status'] as String;
    final age = minutesSince(ticket['createdAt']);
    final ageColor = age < 10 ? p.success : (age <= 20 ? HPColors.saffron : p.danger);
    final (tone, next, nextLabel, nextIcon) = switch (status) {
      'new' => (HPTone.danger, 'preparing', 'Start cooking', Icons.local_fire_department_rounded),
      'preparing' => (HPTone.saffron, 'ready', 'Mark ready', Icons.room_service_rounded),
      'ready' => (HPTone.success, 'served', 'Served', Icons.check_rounded),
      _ => (HPTone.neutral, null, null, null),
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(height: 6, color: ageColor),
        Padding(
          padding: const EdgeInsets.all(HPSpace.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${ticket['where']}', style: HPType.titleCard(p.text).copyWith(fontSize: 26)),
                  Text('KOT #${ticket['kotNo']} · ${ticket['waiter'] ?? 'No waiter'}', style: HPType.body(p.muted)),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(age < 1 ? 'now' : '$age', style: HPType.displayTotal(ageColor).copyWith(fontSize: 30)),
                if (age >= 1) Text('min', style: HPType.body(p.muted).copyWith(fontSize: 11)),
              ]),
            ]),
            const SizedBox(height: HPSpace.sm),
            StatusChip(label: status, tone: tone),
            const SizedBox(height: HPSpace.md),
            for (final l in (ticket['lines'] as List).cast<Json>())
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 34,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: l['reversed'] == true ? p.raised : p.text, borderRadius: BorderRadius.circular(8)),
                    child: Text('${l['qty']}', style: HPType.label(l['reversed'] == true ? p.faint : p.ground).copyWith(fontSize: 16)),
                  ),
                  const SizedBox(width: HPSpace.md),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${l['name']}${l['reversed'] == true ? '  (CANCELLED)' : ''}',
                          style: HPType.label(l['reversed'] == true ? p.faint : p.text)
                              .copyWith(fontSize: 19, decoration: l['reversed'] == true ? TextDecoration.lineThrough : null)),
                      if ((l['notes'] ?? '') != '') Text('${l['notes']}', style: HPType.note(p.note).copyWith(fontSize: 16)),
                    ]),
                  ),
                ]),
              ),
            if (canUpdate && next != null) ...[
              const SizedBox(height: HPSpace.md),
              Row(children: [
                if (status == 'new') ...[
                  Expanded(child: SecondaryButton(label: 'Ready', height: 52, onPressed: busy ? null : () => onMove('ready'))),
                  const SizedBox(width: HPSpace.sm),
                ],
                Expanded(flex: 2, child: PrimaryButton(key: Key('ticket-${ticket['kotNo']}-$next'), label: nextLabel!, icon: nextIcon, height: 52, busy: busy, onPressed: () => onMove(next))),
              ]),
            ],
          ]),
        ),
      ]),
    );
  }
}
