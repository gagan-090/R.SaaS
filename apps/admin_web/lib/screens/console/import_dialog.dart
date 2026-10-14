import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../util/download.dart';
import 'dashboard_screen.dart' show rupees;

/// Picks an .xlsx file (bytes + name). Overridable in tests.
typedef PickXlsx = Future<({String name, List<int> bytes})?> Function();
/// The file chooser used by [ImportDialog]; tests replace it.
PickXlsx xlsxPicker = pickXlsx;
Future<({String name, List<int> bytes})?> pickXlsx() async {
  final r = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx'], withData: true);
  final f = r?.files.single;
  return f?.bytes == null ? null : (name: f!.name, bytes: f.bytes!);
}

/// Excel import for the menu or inventory: Download template → Upload → Validate → Preview → Confirm → Results.
/// Nothing is saved until the person confirms; with errors they can only import the valid rows on purpose.
class ImportDialog extends StatefulWidget {
  const ImportDialog({super.key, required this.api, required this.kind});
  final ApiClient api;
  final String kind; // menu | inventory
  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  String _mode = 'create';
  Json? _job; // validated (or committed) import
  bool _busy = false, _partial = false;
  String? _error;

  bool get _menu => widget.kind == 'menu';
  List<Json> get _issues => ((_job?['issues'] as List?) ?? const []).cast<Json>();
  int get _errors => _issues.where((i) => i['severity'] == 'error').length;
  bool get _done => _job?['status'] == 'committed' || _job?['status'] == 'partially_committed';

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _template() => _run(() async {
        final b = await widget.api.importTemplate(widget.kind);
        await saveFile('house-plating-${widget.kind}-import-template.xlsx', b, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      });

  Future<void> _upload() async {
    final f = await xlsxPicker();
    if (f == null) return;
    await _run(() async {
      final j = await widget.api.validateImport(widget.kind, f.name, base64Encode(f.bytes), _mode);
      if (mounted) {
        setState(() {
          _job = j;
          _partial = false;
        });
      }
    });
  }

  Future<void> _commit() => _run(() async {
        final j = await widget.api.commitImport(_job!['id'] as String, partial: _errors > 0 && _partial);
        if (mounted) setState(() => _job = j);
      });

  Future<void> _report() => _run(() async {
        final b = await widget.api.importErrorReport(_job!['id'] as String);
        await saveFile('import-${widget.kind}-errors.csv', b, 'text/csv');
      });

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return HPDialog(
      title: _menu ? 'Import menu from Excel' : 'Import inventory from Excel',
      actions: [
        SecondaryButton(label: _done ? 'Close' : 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context, _done)),
        if (_job != null && !_done)
          PrimaryButton(
            key: const Key('confirm-import'),
            label: _errors > 0 ? 'Import valid rows only' : 'Confirm import',
            busy: _busy,
            height: 56,
            onPressed: _errors == 0 || _partial ? _commit : null,
          ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_job == null) ...[
          Text('1. Download the template — it explains every column and has example rows.', style: HPType.body(p.text)),
          const SizedBox(height: HPSpace.sm),
          Align(alignment: Alignment.centerLeft, child: SecondaryButton(key: const Key('download-template'), label: 'Download template', icon: Icons.download_rounded, onPressed: _busy ? null : _template)),
          const SizedBox(height: HPSpace.lg),
          Text('2. Choose what the file should do:', style: HPType.body(p.text)),
          RadioGroup<String>(
            groupValue: _mode,
            onChanged: (v) => setState(() => _mode = v!),
            child: Column(children: [
              RadioListTile<String>(key: const Key('mode-create'), contentPadding: EdgeInsets.zero, dense: true, value: 'create', title: const Text('Create only'),
                  subtitle: Text(_menu ? 'Adds new items and sizes. Codes that already exist are errors.' : 'Adds new products and opening stock. SKUs that already exist are errors.')),
              RadioListTile<String>(key: const Key('mode-update'), contentPadding: EdgeInsets.zero, dense: true, value: 'update', title: const Text('Update existing'),
                  subtitle: const Text('Changes rows whose code already exists. Blank cells keep the current value. Unknown codes are errors.')),
            ]),
          ),
          const SizedBox(height: HPSpace.md),
          Text('3. Upload the filled .xlsx. We check every row and show exactly what will change — nothing is saved yet.', style: HPType.body(p.text)),
          const SizedBox(height: HPSpace.sm),
          Align(alignment: Alignment.centerLeft, child: PrimaryButton(key: const Key('upload-xlsx'), label: 'Upload and check', icon: Icons.upload_file_rounded, busy: _busy, height: 48, onPressed: _upload)),
        ] else ...[
          _summary(p),
          if (_issues.isNotEmpty) ...[
            const SizedBox(height: HPSpace.md),
            Row(children: [
              Expanded(child: Text(_errors > 0 ? '$_errors error${_errors == 1 ? '' : 's'} to fix' : 'Warnings', style: HPType.titleCard(_errors > 0 ? p.danger : p.text))),
              TextButton.icon(key: const Key('error-report'), onPressed: _busy ? null : _report, icon: const Icon(Icons.download_rounded, size: 18), label: const Text('Error report')),
            ]),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(shrinkWrap: true, children: [
                for (final i in _issues.take(200))
                  ListTile(
                    dense: true,
                    leading: Icon(i['severity'] == 'error' ? Icons.error_outline_rounded : Icons.info_outline_rounded, color: i['severity'] == 'error' ? p.danger : p.muted, size: 18),
                    title: Text('${i['message']}', style: HPType.body(p.text)),
                    subtitle: Text([if ('${i['sheet']}'.isNotEmpty) 'Sheet ${i['sheet']}', if (i['row'] != 0) 'row ${i['row']}', if ('${i['column']}'.isNotEmpty) 'column ${i['column']}'].join(' · '), style: HPType.body(p.muted).copyWith(fontSize: 12)),
                  ),
              ]),
            ),
          ],
          if (!_done) ...[
            const SizedBox(height: HPSpace.md),
            _preview(p),
            if (_errors > 0)
              CheckboxListTile(
                key: const Key('partial'),
                contentPadding: EdgeInsets.zero,
                value: _partial,
                onChanged: (v) => setState(() => _partial = v!),
                title: const Text('Import only the rows without errors'),
                subtitle: const Text('Rows with errors, and anything that depends on them, are skipped and listed afterwards. Better: fix the file and upload again.'),
              ),
            TextButton(onPressed: _busy ? null : () => setState(() => _job = null), child: const Text('Upload a different file')),
          ] else
            _results(p),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: HPSpace.sm), child: Text(_error!, key: const Key('import-error'), style: HPType.body(p.danger))),
      ]),
    );
  }

  Widget _summary(HPPalette p) {
    final c = (_job!['counts'] as Json);
    final parts = _menu
        ? ['${c['itemsCreate']} new items', '${c['itemsUpdate']} items updated', '${c['variantsCreate']} new sizes', '${c['variantsUpdate']} sizes updated', '${c['categoriesCreate']} new categories', '${c['recipes']} recipes']
        : ['${c['productsCreate']} new products', '${c['productsUpdate']} updated', '${c['openingMovements']} opening stock entries (${rupees(c['openingValuePaise'] as int)})', '${c['suppliersCreate']} new suppliers', '${c['locationsCreate']} new locations'];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${_job!['fileName']} · ${_job!['mode'] == 'create' ? 'Create only' : 'Update existing'}', style: HPType.label(p.text)),
      const SizedBox(height: 4),
      Text(parts.join(' · '), key: const Key('import-summary'), style: HPType.body(p.muted)),
    ]);
  }

  Widget _preview(HPPalette p) {
    final pv = _job!['preview'] as Json;
    final rows = <Widget>[];
    String price(Object? paise) => paise == null ? '' : rupees(paise as int);
    if (_menu) {
      for (final it in (pv['items'] as List).cast<Json>().take(50)) {
        final d = it['data'] as Json;
        rows.add(Text('${it['op'] == 'create' ? 'New' : 'Update'} item ${it['code']}${d['name'] != null ? ' · ${d['name']}' : ''}${d['category'] != null ? ' · ${d['category']}' : ''}', style: HPType.body(p.text)));
      }
      for (final v in (pv['variants'] as List).cast<Json>().take(80)) {
        final d = v['data'] as Json, b = v['before'] as Json?;
        final change = b != null && d['pricePaise'] != null ? '${price(b['pricePaise'])} → ${price(d['pricePaise'])}' : price(d['pricePaise']);
        rows.add(Text('  ${v['op'] == 'create' ? 'New' : 'Update'} size ${v['code']}${d['name'] != null ? ' · ${d['name']}' : ''} $change', style: HPType.body(p.muted)));
      }
    } else {
      for (final x in (pv['products'] as List).cast<Json>().take(50)) {
        rows.add(Text('${x['op'] == 'create' ? 'New' : 'Update'} product ${x['sku']}${(x['data'] as Json)['name'] != null ? ' · ${(x['data'] as Json)['name']}' : ''}', style: HPType.body(p.text)));
      }
      for (final o in (pv['opening'] as List).cast<Json>().take(80)) {
        rows.add(Text('  Opening stock ${o['sku']}: +${o['baseQty']} ${o['baseUnit']} (${rupees(o['valuePaise'] as int)})${o['location'] != null ? ' in ${o['location']}' : ''}', style: HPType.body(p.muted)));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('PREVIEW', style: HPType.overline(p.muted)),
      const SizedBox(height: 4),
      ConstrainedBox(constraints: const BoxConstraints(maxHeight: 220), child: ListView(key: const Key('import-preview'), shrinkWrap: true, children: rows.isEmpty ? [Text('Nothing to import.', style: HPType.body(p.muted))] : rows)),
    ]);
  }

  Widget _results(HPPalette p) {
    final r = (_job!['result'] as Json?) ?? const {};
    final skipped = ((r['skipped'] as List?) ?? const []).cast<Json>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: HPSpace.md),
      Text(_job!['status'] == 'committed' ? 'Imported' : 'Imported the valid rows', key: const Key('import-done'), style: HPType.titleCard(p.success)),
      const SizedBox(height: 4),
      Text([for (final e in r.entries) if (e.key != 'skipped' && e.value is int && e.value != 0) '${e.key.replaceAllMapped(RegExp('[A-Z]'), (m) => ' ${m[0]!.toLowerCase()}')}: ${e.value}'].join(' · '), style: HPType.body(p.text)),
      if (skipped.isNotEmpty) ...[
        const SizedBox(height: HPSpace.sm),
        Text('Skipped ${skipped.length} rows: ${skipped.take(20).map((s) => '${s['sheet']} row ${s['row']} (${s['code']})').join(', ')}', key: const Key('import-skipped'), style: HPType.body(p.danger)),
      ],
    ]);
  }
}
