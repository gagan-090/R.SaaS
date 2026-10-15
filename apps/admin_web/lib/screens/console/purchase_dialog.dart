import 'dart:math';
import 'package:flutter/material.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';
import '../../api/api_client.dart';
import '../../util/money_input.dart';

class PurchaseDialog extends StatefulWidget {
  const PurchaseDialog({super.key, required this.api, required this.products, required this.suppliers, required this.locations});
  final ApiClient api;
  final List<Json> products, suppliers, locations;
  @override
  State<PurchaseDialog> createState() => _PurchaseDialogState();
}
class _Line {
  String? product;
  final qty = TextEditingController(text: '1'), cost = TextEditingController();
  void dispose() { qty.dispose(); cost.dispose(); }
}
class _PurchaseDialogState extends State<PurchaseDialog> {
  final _reference = TextEditingController();
  final _lines = <_Line>[_Line()];
  String? _supplier, _location, _error;
  bool _busy = false;
  late final _key = _uuid();
  String _uuid() {
    final r = Random.secure();
    final b = List.generate(16, (_) => r.nextInt(256)); b[6] = (b[6] & 15) | 64; b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0,8)}-${h.substring(8,12)}-${h.substring(12,16)}-${h.substring(16,20)}-${h.substring(20)}';
  }
  @override
  void dispose() { _reference.dispose(); for (final l in _lines) { l.dispose(); } super.dispose(); }
  Future<void> _save() async {
    if (_supplier == null || _reference.text.trim().isEmpty) { setState(() => _error = 'Choose a supplier and enter the invoice number.'); return; }
    final lines = <Json>[];
    for (final l in _lines) {
      final q = double.tryParse(l.qty.text), cost = parseRupees(l.cost.text);
      if (l.product == null || q == null || q <= 0 || cost == null || cost < 0) { setState(() => _error = 'Each line needs a product, positive quantity and unit cost.'); return; }
      final p = widget.products.firstWhere((p) => p['id'] == l.product);
      lines.add({'productId': l.product, 'quantity': q, 'unit': p['purchaseUnit'], 'unitCostPaise': cost});
    }
    setState(() { _busy = true; _error = null; });
    try {
      await widget.api.receivePurchase({'supplierId': _supplier, 'reference': _reference.text.trim(), 'locationId': _location, 'idempotencyKey': _key, 'lines': lines});
      if (mounted) Navigator.pop(context, true);
    } catch (e) { if (mounted) setState(() => _error = '$e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  @override
  Widget build(BuildContext context) => HPDialog(title: 'Receive a purchase', actions: [
    SecondaryButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
    PrimaryButton(label: 'Receive & update stock', busy: _busy, onPressed: _save),
  ], child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const Text('Record the delivered quantities. Every line updates stock and average cost together.'),
    const SizedBox(height: 16),
    DropdownButtonFormField<String>(initialValue: _supplier, decoration: const InputDecoration(labelText: 'Supplier'), items: [for (final s in widget.suppliers) DropdownMenuItem(value: s['id'] as String, child: Text('${s['name']}'))], onChanged: _busy ? null : (v) => setState(() => _supplier = v)),
    const SizedBox(height: 12),
    TextField(controller: _reference, decoration: const InputDecoration(labelText: 'Supplier invoice / receipt number')),
    const SizedBox(height: 12),
    DropdownButtonFormField<String>(initialValue: _location, decoration: const InputDecoration(labelText: 'Storage location'), items: [const DropdownMenuItem(value: null, child: Text('Default location')), for (final l in widget.locations) DropdownMenuItem(value: l['id'] as String, child: Text('${l['name']}'))], onChanged: _busy ? null : (v) => _location = v),
    for (final (i,l) in _lines.indexed) Padding(padding: const EdgeInsets.only(top: 16), child: Column(children: [
      DropdownButtonFormField<String>(key: ObjectKey(l), initialValue: l.product, isExpanded: true, decoration: InputDecoration(labelText: 'Product ${i+1}'), items: [for (final p in widget.products.where((p) => p['active'] != false)) DropdownMenuItem(value: p['id'] as String, child: Text('${p['name']} · ${p['purchaseUnit']}'))], onChanged: _busy ? null : (v) => setState(() { l.product = v; final p = widget.products.firstWhere((p) => p['id'] == v); l.cost.text = ((p['unitCostPaise'] as num) / 100).toStringAsFixed(2); })),
      const SizedBox(height: 8), Row(children: [Expanded(child: TextField(controller: l.qty, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantity'))), const SizedBox(width: 12), Expanded(child: TextField(controller: l.cost, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Cost per purchase unit', prefixText: '₹ '))), IconButton(tooltip: 'Remove line', onPressed: _busy || _lines.length == 1 ? null : () => setState(() { _lines.remove(l); l.dispose(); }), icon: const Icon(Icons.close))]),
    ])),
    TextButton.icon(onPressed: _busy || _lines.length >= 100 ? null : () => setState(() => _lines.add(_Line())), icon: const Icon(Icons.add), label: const Text('Add product')),
    if (_error != null) Text(_error!, style: TextStyle(color: context.hp.danger)),
  ]));
}
