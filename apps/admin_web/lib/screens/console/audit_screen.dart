import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../util/download.dart';
import '../../widgets/common.dart';
import 'dashboard_screen.dart' show rupees;

/// Auditor portal (also for owners and admins with audit access): the restaurant's activity log with filters and
/// export, sales records (bills, payments, discounts, refunds, voids) and import history. Read-only by design —
/// there is nothing here that changes a record, and the server refuses changes from auditors anyway.
class RestaurantAuditScreen extends ConsumerStatefulWidget {
  const RestaurantAuditScreen({super.key});
  @override
  ConsumerState<RestaurantAuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<RestaurantAuditScreen> {
  int _tab = 0;
  ApiClient get _api => ref.read(apiProvider);
  bool _can(String p) {
    final a = ref.read(authProvider);
    return a is SignedIn && a.can(p);
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <(String, Widget)>[
      ('Activity log', _LogTab(api: _api, canExport: _can('audit.export'))),
      if (_can('order.read')) ('Sales & payments', _SalesTab(api: _api, canExport: _can('audit.export'))),
      ('Imports', _ImportsTab(api: _api)),
    ];
    return PageFrame(
      title: 'Audit & records',
      subtitle: 'Read-only history of this restaurant. Entries cannot be edited or deleted.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final (i, t) in tabs.indexed)
              Padding(padding: const EdgeInsets.only(right: HPSpace.sm), child: CategoryChip(key: Key('audit-tab-$i'), label: t.$1, selected: _tab == i, onTap: () => setState(() => _tab = i))),
          ]),
        ),
        const SizedBox(height: HPSpace.lg),
        tabs[_tab.clamp(0, tabs.length - 1)].$2,
      ]),
    );
  }
}

String _when(Object? iso) {
  final d = DateTime.tryParse('$iso')?.toLocal();
  if (d == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class _LogTab extends StatefulWidget {
  const _LogTab({required this.api, required this.canExport});
  final ApiClient api;
  final bool canExport;
  @override
  State<_LogTab> createState() => _LogTabState();
}

class _LogTabState extends State<_LogTab> {
  Json? _facets;
  List<Json>? _rows;
  Object? _error;
  String? _module, _actor, _role;
  final _from = TextEditingController(), _to = TextEditingController(), _q = TextEditingController();

  Map<String, String> get _query => {
        if (_module != null) 'module': _module!,
        if (_actor != null) 'actorId': _actor!,
        if (_role != null) 'role': _role!,
        if (_from.text.trim().isNotEmpty) 'from': _from.text.trim(),
        if (_to.text.trim().isNotEmpty) 'to': _to.text.trim(),
        if (_q.text.trim().isNotEmpty) 'q': _q.text.trim(),
      };

  @override
  void initState() {
    super.initState();
    widget.api.auditFacets().then((f) {
      if (mounted) setState(() => _facets = f);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e);
    });
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.auditEvents(_query);
      if (mounted) {
        setState(() {
          _rows = r.cast<Json>();
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _export() async {
    try {
      final b = await widget.api.auditCsv(_query);
      await saveFile('audit-log.csv', b, 'text/csv');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    if (_error != null) return ErrorState(message: '$_error', onRetry: _load);
    final f = _facets;
    Widget drop(String key, String label, String? value, List<(String, String)> items, ValueChanged<String?> on) => SizedBox(
          width: 210,
          child: DropdownButtonFormField<String?>(
            key: Key(key),
            initialValue: value,
            isExpanded: true,
            decoration: InputDecoration(labelText: label),
            items: [const DropdownMenuItem<String?>(value: null, child: Text('All')), for (final (v, l) in items) DropdownMenuItem<String?>(value: v, child: Text(l, overflow: TextOverflow.ellipsis))],
            onChanged: (v) {
              setState(() => on(v));
              _load();
            },
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, crossAxisAlignment: WrapCrossAlignment.end, children: [
        if (f != null) ...[
          drop('f-module', 'Area', _module, [for (final m in (f['modules'] as List).cast<String>()) (m, m)], (v) => _module = v),
          drop('f-actor', 'Employee', _actor, [for (final e in (f['employees'] as List).cast<Json>()) (e['id'] as String, '${e['name']}')], (v) => _actor = v),
          drop('f-role', 'Role', _role, [for (final r in (f['roles'] as List).cast<String>()) (r, r == 'it_admin' ? 'Restaurant admin' : r)], (v) => _role = v),
        ],
        SizedBox(width: 140, child: TextField(key: const Key('f-from'), controller: _from, decoration: const InputDecoration(labelText: 'From (YYYY-MM-DD)'), onSubmitted: (_) => _load())),
        SizedBox(width: 140, child: TextField(key: const Key('f-to'), controller: _to, decoration: const InputDecoration(labelText: 'To'), onSubmitted: (_) => _load())),
        SizedBox(width: 220, child: TextField(key: const Key('f-q'), controller: _q, decoration: const InputDecoration(labelText: 'Record / request id or reason'), onSubmitted: (_) => _load())),
        SecondaryButton(key: const Key('f-apply'), label: 'Apply', onPressed: _load),
        if (widget.canExport) SecondaryButton(key: const Key('export-log'), label: 'Export CSV', icon: Icons.download_rounded, onPressed: _export),
      ]),
      const SizedBox(height: HPSpace.lg),
      if (_rows == null)
        const SkeletonBox(height: 240)
      else if (_rows!.isEmpty)
        const EmptyState(icon: Icons.history_rounded, title: 'Nothing found', message: 'Try a wider date range or fewer filters.')
      else
        Card(
          child: Column(children: [
            for (final (i, e) in _rows!.indexed) ...[
              if (i > 0) const Divider(height: 1),
              ExpansionTile(
                key: Key('log-${e['id']}'),
                leading: Icon(e['source'] == 'pos' ? Icons.point_of_sale_rounded : Icons.cloud_outlined, color: p.muted),
                title: Text('${e['action']}', style: HPType.label(p.text)),
                subtitle: Text(
                  [_when(e['at']), '${e['actorName']}${e['actorRole'] != null ? ' (${e['actorRole']})' : ''}', '${e['module']}', if (e['reason'] != null) 'reason: ${e['reason']}'].join(' · '),
                  style: HPType.body(p.muted),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(HPSpace.lg, 0, HPSpace.lg, HPSpace.md),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Record: ${e['objectType'] ?? '—'} ${e['objectId'] ?? ''}', style: HPType.mono(p.muted)),
                  if (e['requestId'] != null) Text('Request: ${e['requestId']}', style: HPType.mono(p.muted)),
                  if (e['before'] != null) Text('Before: ${const JsonEncoder.withIndent('  ').convert(e['before'])}', style: HPType.mono(p.text)),
                  if (e['after'] != null) Text('After: ${const JsonEncoder.withIndent('  ').convert(e['after'])}', style: HPType.mono(p.text)),
                ],
              ),
            ],
          ]),
        ),
    ]);
  }
}

class _SalesTab extends StatefulWidget {
  const _SalesTab({required this.api, required this.canExport});
  final ApiClient api;
  final bool canExport;
  @override
  State<_SalesTab> createState() => _SalesTabState();
}

class _SalesTabState extends State<_SalesTab> {
  Json? _s;
  Object? _error;
  final _from = TextEditingController(text: DateTime.now().subtract(const Duration(days: 1)).toIso8601String().substring(0, 10)), _to = TextEditingController();

  Map<String, String> get _q => {'from': _from.text.trim(), if (_to.text.trim().isNotEmpty) 'to': _to.text.trim()};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await widget.api.salesRecords(_q);
      if (mounted) {
        setState(() {
          _s = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    if (_error != null) return ErrorState(message: '$_error', onRetry: _load);
    final s = _s;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, crossAxisAlignment: WrapCrossAlignment.end, children: [
        SizedBox(width: 150, child: TextField(controller: _from, decoration: const InputDecoration(labelText: 'From (YYYY-MM-DD)'), onSubmitted: (_) => _load())),
        SizedBox(width: 150, child: TextField(controller: _to, decoration: const InputDecoration(labelText: 'To (optional)'), onSubmitted: (_) => _load())),
        SecondaryButton(label: 'Apply', onPressed: _load),
        if (widget.canExport)
          SecondaryButton(key: const Key('export-sales'), label: 'Export CSV', icon: Icons.download_rounded, onPressed: () async {
            try {
              await saveFile('sales.csv', await widget.api.salesCsv(_q), 'text/csv');
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          }),
      ]),
      const SizedBox(height: HPSpace.lg),
      if (s == null)
        const SkeletonBox(height: 200)
      else ...[
        Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, children: [
          SizedBox(width: 220, child: KpiCard(key: const Key('sales-total'), label: 'Sales (paid)', value: rupees((s['summary'] as Json)['salesPaise'] as int), caption: '${(s['summary'] as Json)['paidBills']} bills', icon: Icons.payments_outlined)),
          SizedBox(width: 200, child: KpiCard(label: 'Discounts', value: rupees((s['summary'] as Json)['discountsPaise'] as int), icon: Icons.local_offer_outlined)),
          SizedBox(width: 200, child: KpiCard(label: 'Refunds & corrections', value: rupees(((s['summary'] as Json)['refundsPaise'] as int).abs()), icon: Icons.undo_rounded)),
          SizedBox(width: 200, child: KpiCard(label: 'Voided lines', value: '${(s['summary'] as Json)['voids']}', caption: rupees((s['summary'] as Json)['voidsPaise'] as int), icon: Icons.remove_circle_outline)),
          for (final m in ((s['summary'] as Json)['paymentsByMode'] as Json).entries) SizedBox(width: 160, child: KpiCard(label: m.key.toUpperCase(), value: rupees(m.value as int), icon: Icons.account_balance_wallet_outlined)),
        ]),
        const SizedBox(height: HPSpace.lg),
        SectionCard(
          title: 'Bills',
          child: (s['bills'] as List).isEmpty
              ? Text('No bills in this period.', style: HPType.body(p.muted))
              : Column(children: [
                  for (final b in (s['bills'] as List).cast<Json>())
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${b['invoiceNo'] ?? 'Draft'} · ${b['status']}', style: HPType.label(p.text)),
                      subtitle: Text([
                        _when(b['closedAt'] ?? b['createdAt']),
                        for (final pay in (b['payments'] as List).cast<Json>()) '${pay['mode']} ${rupees(pay['amountPaise'] as int)}',
                        if ((b['discountPaise'] as int) > 0) 'discount ${rupees(b['discountPaise'] as int)}${b['discountReason'] != null ? ' (${b['discountReason']})' : ''}',
                        for (final a in (b['adjustments'] as List).cast<Json>()) 'adjustment ${rupees(a['amountPaise'] as int)}: ${a['reason']}',
                      ].join(' · '), style: HPType.body(p.muted)),
                      trailing: Text(rupees(b['totalPaise'] as int), style: HPType.label(p.text)),
                    ),
                ]),
        ),
        if ((s['voids'] as List).isNotEmpty) ...[
          const SizedBox(height: HPSpace.lg),
          SectionCard(
            title: 'Voided lines',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final v in (s['voids'] as List).cast<Json>())
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('${v['name']} × ${v['qty']} · ${rupees(v['amountPaise'] as int)} · ${v['reason'] ?? 'no reason'} · by ${v['by'] ?? '—'}${v['approvedBy'] != null ? ', approved by ${v['approvedBy']}' : ''}', style: HPType.body(p.text)),
                ),
            ]),
          ),
        ],
      ],
    ]);
  }
}

class _ImportsTab extends StatefulWidget {
  const _ImportsTab({required this.api});
  final ApiClient api;
  @override
  State<_ImportsTab> createState() => _ImportsTabState();
}

class _ImportsTabState extends State<_ImportsTab> {
  List<Json>? _rows;
  @override
  void initState() {
    super.initState();
    widget.api.auditImports().then((r) {
      if (mounted) setState(() => _rows = r.cast<Json>());
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    if (_rows == null) return const SkeletonBox(height: 160);
    if (_rows!.isEmpty) return const EmptyState(icon: Icons.upload_file_rounded, title: 'No imports yet', message: 'Menu and inventory imports from Excel appear here with their results.');
    return Card(
      child: Column(children: [
        for (final (i, j) in _rows!.indexed) ...[
          if (i > 0) const Divider(height: 1),
          ListTile(
            title: Text('${j['kind']} · ${j['fileName']} · ${j['mode'] == 'create' ? 'create only' : 'update existing'}', style: HPType.label(p.text)),
            subtitle: Text([_when(j['createdAt']), 'by ${j['actorName']}', '${((j['fileSize'] as int) / 1024).toStringAsFixed(1)} KB', if ((j['errors'] as int) > 0) '${j['errors']} errors'].join(' · '), style: HPType.body(p.muted)),
            trailing: StatusChip(label: '${j['status']}'.replaceAll('_', ' '), tone: '${j['status']}'.contains('committed') ? HPTone.success : (j['status'] == 'invalid' ? HPTone.danger : HPTone.neutral)),
          ),
        ],
      ]),
    );
  }
}
