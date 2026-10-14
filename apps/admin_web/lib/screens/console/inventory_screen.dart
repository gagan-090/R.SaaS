import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'dashboard_screen.dart' show rupees;
import 'import_dialog.dart';

const stockUnits = ['g', 'kg', 'mg', 'ml', 'l', 'piece', 'dozen', 'bottle', 'can', 'packet', 'box', 'case', 'plate', 'portion'];

/// Movement types a person can post, with the words staff see and the permission each needs.
const movementTypes = <(String, String, String, IconData)>[
  ('purchase', 'Receive stock', 'inventory.write', Icons.local_shipping_outlined),
  ('consumption', 'Kitchen use', 'inventory.consume', Icons.soup_kitchen_outlined),
  ('wastage', 'Wastage', 'inventory.consume', Icons.delete_sweep_outlined),
  ('count', 'Stock count', 'inventory.write', Icons.fact_check_outlined),
  ('adjustment', 'Adjust', 'inventory.write', Icons.tune_rounded),
  ('return_to_supplier', 'Return to supplier', 'inventory.write', Icons.assignment_return_outlined),
  ('customer_return', 'Customer return', 'inventory.write', Icons.keyboard_return_rounded),
  ('transfer', 'Move to another location', 'inventory.write', Icons.swap_horiz_rounded),
  ('opening', 'Opening stock', 'inventory.write', Icons.flag_outlined),
];
const typeLabels = {
  'opening': 'Opening stock', 'purchase': 'Received', 'sale': 'Sold (from bills)', 'consumption': 'Kitchen use', 'wastage': 'Wastage',
  'return_to_supplier': 'Returned to supplier', 'customer_return': 'Customer return', 'count_adjustment': 'Count correction',
  'adjustment': 'Adjustment', 'transfer_out': 'Moved out', 'transfer_in': 'Moved in',
};
const wastageReasons = ['Spoiled', 'Expired', 'Burnt / over-cooked', 'Dropped / spilled', 'Prepared but not sold', 'Returned by guest'];

String qtyText(num q, String unit) => '${q % 1 == 0 ? q.toInt() : q.toStringAsFixed(3).replaceAll(RegExp(r'0+$'), '')} $unit';

/// Inventory (plan feature "inventory"): stock, movements, alerts, replenishment requests, suppliers & locations,
/// valuation. What each person can do follows their permissions; the API checks them again.
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});
  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  List<Json>? _products, _locations, _suppliers;
  Json? _alerts;
  Object? _error;
  String _q = '';
  int _tab = 0;
  int _reload = 0;

  ApiClient get _api => ref.read(apiProvider);
  bool get _isOwner => (ref.read(authProvider) as SignedIn).roles.contains('owner');
  bool _can(String p) {
    final a = ref.read(authProvider);
    return a is SignedIn && a.can(p);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([_api.invProducts(), _api.invLocations(), _api.invSuppliers(), _api.invAlerts()]);
      if (!mounted) return;
      setState(() {
        _products = (r[0] as List).cast<Json>();
        _locations = (r[1] as List).cast<Json>();
        _suppliers = (r[2] as List).cast<Json>();
        _alerts = r[3] as Json;
        _error = null;
        _reload++;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _editProduct([Json? p]) async {
    final saved = await showDialog<String>(context: context, builder: (_) => _ProductEditor(api: _api, product: p, locations: _locations!, suppliers: _suppliers!));
    if (saved != null) {
      await _load();
      if (mounted) showDone(context, saved);
    }
  }

  Future<void> _move(Json p, String type) async {
    final done = await showDialog<String>(context: context, builder: (_) => _MovementDialog(api: _api, product: p, type: type, locations: _locations!, suppliers: _suppliers!));
    if (done != null) {
      await _load();
      if (mounted) showDone(context, done);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error is ApiException && (_error as ApiException).code == 'feature_not_in_plan') {
      return const PageFrame(
        title: 'Inventory',
        child: EmptyState(key: Key('inventory-locked'), icon: Icons.lock_outline_rounded, title: 'Inventory is not in your plan', message: 'Ask House Plating to add inventory to your plan. Stock, recipes and wastage tracking then appear here.'),
      );
    }
    if (_error != null) return ErrorState(message: '$_error', onRetry: _load);
    if (_products == null) return const LoadingState();
    final p = context.hp;
    final alertCount = ((_alerts!['low'] as List).length) + ((_alerts!['negative'] as List).length) + ((_alerts!['expiring'] as List).length);
    final tabs = <(String, Widget)>[
      ('Stock', _stockTab(p)),
      ('Movements', _MovementsTab(key: ValueKey('mv-$_reload'), api: _api)),
      ('Alerts${alertCount > 0 ? ' · $alertCount' : ''}', _AlertsTab(alerts: _alerts!)),
      ('Requests', _RequestsTab(key: ValueKey('rq-$_reload'), api: _api, products: _products!, canRequest: _can('inventory.request'), canHandle: _can('inventory.write'))),
      ('Suppliers & places', _PlacesTab(api: _api, locations: _locations!, suppliers: _suppliers!, canManage: _can('inventory.manage'), onChanged: _load)),
      ('Value', _ValuationTab(key: ValueKey('val-$_reload'), api: _api)),
    ];
    return PageFrame(
      title: 'Inventory',
      subtitle: '${_products!.length} products · stock comes only from recorded movements',
      actions: [
        if ((_can('import.run') || _isOwner) && _can('inventory.manage') && _can('inventory.write'))
          SecondaryButton(key: const Key('import-inventory'), label: 'Import Excel', icon: _can('import.run') ? Icons.upload_file_rounded : Icons.lock_outline_rounded, onPressed: () async {
            if (!_can('import.run')) {
              showError(context, 'Excel import is not in your plan. Ask the Super Admin to enable "Excel import (menu & inventory)" in Plans, then sign in again.');
              return;
            }
            final done = await showDialog<bool>(context: context, builder: (_) => ImportDialog(api: _api, kind: 'inventory'));
            if (done == true) await _load();
          }),
        if (_can('inventory.manage')) PrimaryButton(key: const Key('add-product'), label: 'Add product', icon: Icons.add_rounded, height: 48, onPressed: () => _editProduct()),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final (i, t) in tabs.indexed)
              Padding(padding: const EdgeInsets.only(right: HPSpace.sm), child: CategoryChip(key: Key('inv-tab-$i'), label: t.$1, selected: _tab == i, onTap: () => setState(() => _tab = i))),
          ]),
        ),
        const SizedBox(height: HPSpace.lg),
        tabs[_tab].$2,
      ]),
    );
  }

  Widget _stockTab(HPPalette p) {
    final shown = _products!.where((x) => _q.isEmpty || '${x['name']} ${x['sku']} ${x['category'] ?? ''}'.toLowerCase().contains(_q.toLowerCase())).toList();
    final allowed = movementTypes.where((m) => _can(m.$3)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      HPSearchField(hint: 'Search name, SKU or category', onChanged: (v) => setState(() => _q = v.trim())),
      const SizedBox(height: HPSpace.md),
      if (shown.isEmpty)
        EmptyState(icon: Icons.inventory_2_outlined, title: _products!.isEmpty ? 'No products yet' : 'Nothing matches', message: _products!.isEmpty ? 'Add ingredients and packaged drinks, or import them from Excel.' : 'Try another search.')
      else
        Card(
          child: Column(children: [
            for (final (i, x) in shown.indexed) ...[
              if (i > 0) const Divider(height: 1),
              ListTile(
                key: Key('product-${x['sku']}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: HPSpace.lg, vertical: HPSpace.xs),
                title: Text('${x['name']}', style: HPType.label(x['active'] == true ? p.text : p.faint)),
                subtitle: Text([x['sku'], if (x['category'] != null) x['category'], 'avg ${rupees(((x['avgCostPaise'] as num) * 1).round())}/${x['baseUnit']}'].join(' · '), style: HPType.body(p.muted)),
                trailing: Wrap(spacing: HPSpace.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  if (x['negative'] == true) const StatusChip(label: 'Below zero', tone: HPTone.danger)
                  else if (x['low'] == true) const StatusChip(label: 'Low', tone: HPTone.saffron),
                  if ((x['expiring'] as List).isNotEmpty) const StatusChip(label: 'Expiring', tone: HPTone.danger, icon: Icons.event_busy_outlined),
                  Text(qtyText(x['stock'] as num, '${x['baseUnit']}'), key: Key('stock-${x['sku']}'), style: HPType.label(p.text)),
                  if (allowed.isNotEmpty || _can('inventory.manage'))
                    PopupMenuButton<String>(
                      key: Key('actions-${x['sku']}'),
                      tooltip: 'Record a movement',
                      onSelected: (v) => v == 'edit' ? _editProduct(x) : _move(x, v),
                      itemBuilder: (_) => [
                        for (final m in allowed) PopupMenuItem(value: m.$1, child: ListTile(dense: true, leading: Icon(m.$4), title: Text(m.$2))),
                        if (_can('inventory.manage')) const PopupMenuItem(value: 'edit', child: ListTile(dense: true, leading: Icon(Icons.edit_outlined), title: Text('Edit product'))),
                      ],
                    ),
                ]),
              ),
            ],
          ]),
        ),
    ]);
  }
}

// ---------------------------------------------------------------- product editor

class _ProductEditor extends StatefulWidget {
  const _ProductEditor({required this.api, required this.product, required this.locations, required this.suppliers});
  final ApiClient api;
  final Json? product;
  final List<Json> locations, suppliers;
  @override
  State<_ProductEditor> createState() => _ProductEditorState();
}

class _ProductEditorState extends State<_ProductEditor> {
  late final _sku = TextEditingController(text: widget.product?['sku'] as String? ?? '');
  late final _name = TextEditingController(text: widget.product?['name'] as String? ?? '');
  late final _cat = TextEditingController(text: widget.product?['category'] as String? ?? '');
  late final _factor = TextEditingController(text: '${widget.product?['conversionFactor'] ?? 1}'.replaceAll(RegExp(r'\.0+$'), ''));
  late final _cost = TextEditingController(text: widget.product == null ? '' : ((widget.product!['unitCostPaise'] as int) / 100).toStringAsFixed(2));
  late final _min = TextEditingController(text: '${widget.product?['minStock'] ?? 0}'.replaceAll(RegExp(r'\.0+$'), ''));
  late String _base = widget.product?['baseUnit'] as String? ?? 'g';
  late String _purchase = widget.product?['purchaseUnit'] as String? ?? 'kg';
  late String? _supplier = widget.product?['defaultSupplierId'] as String?;
  late String? _location = widget.product?['defaultLocationId'] as String?;
  late bool _active = widget.product?['active'] as bool? ?? true;
  bool _busy = false;
  String? _error;

  bool get _isNew => widget.product == null;

  Future<void> _save() async {
    final factor = double.tryParse(_factor.text.trim());
    final cost = double.tryParse(_cost.text.trim().isEmpty ? '0' : _cost.text.trim());
    final min = double.tryParse(_min.text.trim().isEmpty ? '0' : _min.text.trim());
    if (_isNew && !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$').hasMatch(_sku.text.trim())) return setState(() => _error = 'SKU: letters, digits, - _ . (no spaces)');
    if (_name.text.trim().isEmpty) return setState(() => _error = 'Enter a product name');
    if (factor == null || factor <= 0) return setState(() => _error = 'Conversion must be a number above 0');
    if (cost == null || cost < 0) return setState(() => _error = 'Cost must be a number (₹ per purchase unit)');
    if (min == null || min < 0) return setState(() => _error = 'Reorder level must be 0 or more');
    setState(() {
      _busy = true;
      _error = null;
    });
    final body = <String, dynamic>{
      'name': _name.text.trim(), 'category': _cat.text.trim().isEmpty ? null : _cat.text.trim(), 'baseUnit': _base, 'purchaseUnit': _purchase,
      'conversionFactor': factor, 'unitCostPaise': (cost * 100).round(), 'minStock': min, 'defaultSupplierId': _supplier, 'defaultLocationId': _location, 'active': _active,
    };
    try {
      if (_isNew) {
        await widget.api.createInvProduct({...body, 'sku': _sku.text.trim().toUpperCase()});
      } else {
        await widget.api.updateInvProduct(widget.product!['id'] as String, body);
      }
      if (mounted) Navigator.pop(context, '${_name.text.trim()} saved');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    Widget unit(String key, String label, String value, ValueChanged<String> on) => DropdownButtonFormField<String>(
          key: Key(key),
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [for (final u in stockUnits) DropdownMenuItem(value: u, child: Text(u))],
          onChanged: (v) => setState(() => on(v!)),
        );
    return HPDialog(
      title: _isNew ? 'Add a product' : 'Edit ${widget.product!['name']}',
      actions: [
        SecondaryButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        PrimaryButton(key: const Key('save-product'), label: 'Save', busy: _busy, height: 56, onPressed: _save),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: TextField(key: const Key('product-sku'), controller: _sku, enabled: _isNew, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'SKU (stable code)', hintText: 'RICE-BAS'))),
          const SizedBox(width: HPSpace.sm),
          Expanded(flex: 2, child: TextField(key: const Key('product-name'), controller: _name, decoration: const InputDecoration(labelText: 'Product name'))),
        ]),
        const SizedBox(height: HPSpace.md),
        TextField(controller: _cat, decoration: const InputDecoration(labelText: 'Category (optional)', hintText: 'Grains, Dairy, Packaged drinks')),
        const SizedBox(height: HPSpace.md),
        Text('Stock is counted in the base unit. You buy in the purchase unit; "1 purchase unit = N base units".', style: HPType.body(p.muted).copyWith(fontSize: 12)),
        const SizedBox(height: HPSpace.sm),
        Row(children: [
          Expanded(child: unit('base-unit', 'Base unit', _base, (v) => _base = v)),
          const SizedBox(width: HPSpace.sm),
          Expanded(child: unit('purchase-unit', 'Purchase unit', _purchase, (v) => _purchase = v)),
          const SizedBox(width: HPSpace.sm),
          Expanded(child: TextField(key: const Key('product-factor'), controller: _factor, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '1 $_purchase = ? $_base'))),
        ]),
        const SizedBox(height: HPSpace.md),
        Row(children: [
          Expanded(child: TextField(key: const Key('product-cost'), controller: _cost, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Cost per $_purchase', prefixText: '₹ '))),
          const SizedBox(width: HPSpace.sm),
          Expanded(child: TextField(key: const Key('product-min'), controller: _min, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Reorder level ($_base)'))),
        ]),
        const SizedBox(height: HPSpace.md),
        DropdownButtonFormField<String?>(
          initialValue: _supplier,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Usual supplier'),
          items: [const DropdownMenuItem<String?>(value: null, child: Text('—')), for (final s in widget.suppliers) DropdownMenuItem<String?>(value: s['id'] as String, child: Text('${s['name']}'))],
          onChanged: (v) => setState(() => _supplier = v),
        ),
        const SizedBox(height: HPSpace.md),
        DropdownButtonFormField<String?>(
          initialValue: _location,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Stored in'),
          items: [const DropdownMenuItem<String?>(value: null, child: Text('Main store')), for (final l in widget.locations) DropdownMenuItem<String?>(value: l['id'] as String, child: Text('${l['name']}'))],
          onChanged: (v) => setState(() => _location = v),
        ),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: _active, onChanged: (v) => setState(() => _active = v), title: const Text('Active')),
        if (_error != null) Text(_error!, key: const Key('product-error'), style: HPType.body(p.danger)),
      ]),
    );
  }
}

// ---------------------------------------------------------------- movement dialog

class _MovementDialog extends StatefulWidget {
  const _MovementDialog({required this.api, required this.product, required this.type, required this.locations, required this.suppliers});
  final ApiClient api;
  final Json product;
  final String type;
  final List<Json> locations, suppliers;
  @override
  State<_MovementDialog> createState() => _MovementDialogState();
}

class _MovementDialogState extends State<_MovementDialog> {
  final _qty = TextEditingController(), _cost = TextEditingController(), _ref = TextEditingController(), _batch = TextEditingController(), _expiry = TextEditingController(), _reason = TextEditingController();
  late String _unit = ['purchase', 'opening', 'return_to_supplier'].contains(widget.type) ? '${widget.product['purchaseUnit']}' : '${widget.product['baseUnit']}';
  late String? _location = widget.product['defaultLocationId'] as String?;
  String? _to, _supplier;
  bool _negative = false, _busy = false;
  String? _error;
  // one key per dialog: a double tap or a retry after a network error never records the movement twice
  final _key = 'web-${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}';

  String get _label => movementTypes.firstWhere((m) => m.$1 == widget.type).$2;
  bool get _inbound => ['purchase', 'opening'].contains(widget.type);
  bool get _needsReason => ['wastage', 'adjustment', 'count', 'return_to_supplier', 'customer_return'].contains(widget.type);

  Future<void> _save() async {
    final q = double.tryParse(_qty.text.trim());
    if (q == null || q <= 0) return setState(() => _error = widget.type == 'count' ? 'Enter the quantity you counted' : 'Enter a quantity above 0');
    if (_needsReason && _reason.text.trim().isEmpty) return setState(() => _error = 'Give a reason');
    if (_expiry.text.trim().isNotEmpty && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(_expiry.text.trim())) return setState(() => _error = 'Expiry date as YYYY-MM-DD');
    if (widget.type == 'transfer' && (_to == null || _to == _location)) return setState(() => _error = 'Choose where the stock goes');
    final cost = double.tryParse(_cost.text.trim());
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.invMove({
        'type': widget.type, 'productId': widget.product['id'], 'quantity': widget.type == 'adjustment' && _negative ? -q : q, 'unit': _unit,
        'locationId': _location, if (widget.type == 'transfer') 'toLocationId': _to,
        if (_inbound && cost != null) 'unitCostPaise': (cost * 100).round(),
        if (_supplier != null) 'supplierId': _supplier,
        if (_ref.text.trim().isNotEmpty) 'reference': _ref.text.trim(),
        if (_batch.text.trim().isNotEmpty) 'batchNumber': _batch.text.trim(),
        if (_expiry.text.trim().isNotEmpty) 'expiryDate': _expiry.text.trim(),
        if (_reason.text.trim().isNotEmpty) 'reason': _reason.text.trim(),
        'idempotencyKey': _key,
      });
      final ms = (r['movements'] as List).cast<Json>();
      if (mounted) Navigator.pop(context, ms.isEmpty ? 'Count matches the stock — nothing changed' : '$_label recorded for ${widget.product['name']}');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final units = {'${widget.product['baseUnit']}', '${widget.product['purchaseUnit']}', ...stockUnits}.toList();
    return HPDialog(
      title: '$_label · ${widget.product['name']}',
      actions: [
        SecondaryButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        PrimaryButton(key: const Key('save-movement'), label: 'Record', busy: _busy, height: 56, onPressed: _save),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('In stock now: ${qtyText(widget.product['stock'] as num, '${widget.product['baseUnit']}')}', style: HPType.body(p.muted)),
        const SizedBox(height: HPSpace.md),
        Row(children: [
          Expanded(child: TextField(key: const Key('mv-qty'), controller: _qty, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: widget.type == 'count' ? 'Counted quantity' : 'Quantity'))),
          const SizedBox(width: HPSpace.sm),
          SizedBox(
            width: 120,
            child: DropdownButtonFormField<String>(key: const Key('mv-unit'), initialValue: _unit, isExpanded: true, decoration: const InputDecoration(labelText: 'Unit'), items: [for (final u in units) DropdownMenuItem(value: u, child: Text(u))], onChanged: (v) => setState(() => _unit = v!)),
          ),
        ]),
        if (widget.type == 'adjustment')
          SwitchListTile(key: const Key('mv-negative'), contentPadding: EdgeInsets.zero, value: _negative, onChanged: (v) => setState(() => _negative = v), title: Text(_negative ? 'Remove from stock' : 'Add to stock')),
        const SizedBox(height: HPSpace.md),
        DropdownButtonFormField<String?>(
          initialValue: _location,
          isExpanded: true,
          decoration: InputDecoration(labelText: widget.type == 'transfer' ? 'From' : 'Location'),
          items: [const DropdownMenuItem<String?>(value: null, child: Text('Main store')), for (final l in widget.locations) DropdownMenuItem<String?>(value: l['id'] as String, child: Text('${l['name']}'))],
          onChanged: (v) => setState(() => _location = v),
        ),
        if (widget.type == 'transfer') ...[
          const SizedBox(height: HPSpace.md),
          DropdownButtonFormField<String?>(
            key: const Key('mv-to'),
            initialValue: _to,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'To'),
            items: [const DropdownMenuItem<String?>(value: null, child: Text('Main store')), for (final l in widget.locations) DropdownMenuItem<String?>(value: l['id'] as String, child: Text('${l['name']}'))],
            onChanged: (v) => setState(() => _to = v),
          ),
        ],
        if (_inbound || widget.type == 'return_to_supplier') ...[
          const SizedBox(height: HPSpace.md),
          Row(children: [
            if (_inbound) Expanded(child: TextField(key: const Key('mv-cost'), controller: _cost, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Cost per $_unit', prefixText: '₹ '))),
            if (_inbound) const SizedBox(width: HPSpace.sm),
            Expanded(child: TextField(controller: _ref, decoration: const InputDecoration(labelText: 'Invoice / reference'))),
          ]),
          const SizedBox(height: HPSpace.md),
          DropdownButtonFormField<String?>(
            initialValue: _supplier ?? widget.product['defaultSupplierId'] as String?,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Supplier'),
            items: [const DropdownMenuItem<String?>(value: null, child: Text('—')), for (final s in widget.suppliers) DropdownMenuItem<String?>(value: s['id'] as String, child: Text('${s['name']}'))],
            onChanged: (v) => setState(() => _supplier = v),
          ),
        ],
        if (_inbound) ...[
          const SizedBox(height: HPSpace.md),
          Row(children: [
            Expanded(child: TextField(controller: _batch, decoration: const InputDecoration(labelText: 'Batch (optional)'))),
            const SizedBox(width: HPSpace.sm),
            Expanded(child: TextField(key: const Key('mv-expiry'), controller: _expiry, decoration: const InputDecoration(labelText: 'Expiry (YYYY-MM-DD)'))),
          ]),
        ],
        if (_needsReason || widget.type == 'consumption') ...[
          const SizedBox(height: HPSpace.md),
          if (widget.type == 'wastage')
            Wrap(spacing: HPSpace.xs, runSpacing: HPSpace.xs, children: [
              for (final w in wastageReasons) ActionChip(label: Text(w), onPressed: () => setState(() => _reason.text = w)),
            ]),
          const SizedBox(height: HPSpace.xs),
          TextField(key: const Key('mv-reason'), controller: _reason, decoration: InputDecoration(labelText: _needsReason ? 'Reason (required)' : 'Note (optional)')),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: HPSpace.sm), child: Text(_error!, key: const Key('mv-error'), style: HPType.body(p.danger))),
      ]),
    );
  }
}

// ---------------------------------------------------------------- tabs

class _MovementsTab extends StatefulWidget {
  const _MovementsTab({super.key, required this.api});
  final ApiClient api;
  @override
  State<_MovementsTab> createState() => _MovementsTabState();
}

class _MovementsTabState extends State<_MovementsTab> {
  List<Json>? _rows;
  String? _type;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.api.invMovements(type: _type);
    if (mounted) setState(() => _rows = r.cast<Json>());
  }

  void _filter(String? type) {
    setState(() => _type = type);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    if (_rows == null) return const SkeletonBox(height: 200);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: HPSpace.xs, runSpacing: HPSpace.xs, children: [
        ChoiceChip(label: const Text('All'), selected: _type == null, onSelected: (_) => _filter(null)),
        for (final e in typeLabels.entries) ChoiceChip(key: Key('mvf-${e.key}'), label: Text(e.value), selected: _type == e.key, onSelected: (_) => _filter(e.key)),
      ]),
      const SizedBox(height: HPSpace.md),
      if (_rows!.isEmpty)
        const EmptyState(icon: Icons.history_rounded, title: 'No movements', message: 'Receipts, kitchen use, wastage, counts and sales appear here.')
      else
        Card(
          child: Column(children: [
            for (final (i, m) in _rows!.indexed) ...[
              if (i > 0) const Divider(height: 1),
              ListTile(
                dense: true,
                title: Text('${typeLabels[m['type']] ?? m['type']} · ${m['productName']}', style: HPType.label(p.text)),
                subtitle: Text(
                  [shortDate(m['createdAt']), '${m['actorName']}', if (m['reason'] != null) '${m['reason']}', if (m['reference'] != null) 'ref ${m['reference']}', if (m['batchNumber'] != null) 'batch ${m['batchNumber']}'].join(' · '),
                  style: HPType.body(p.muted),
                ),
                trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${(m['quantity'] as num) > 0 ? '+' : ''}${qtyText(m['quantity'] as num, '${m['baseUnit']}')}', style: HPType.label((m['quantity'] as num) < 0 ? p.danger : p.success)),
                  Text(rupees((m['valuePaise'] as int).abs()), style: HPType.body(p.muted).copyWith(fontSize: 12)),
                ]),
              ),
            ],
          ]),
        ),
    ]);
  }
}

class _AlertsTab extends StatelessWidget {
  const _AlertsTab({required this.alerts});
  final Json alerts;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final low = (alerts['low'] as List).cast<Json>(), neg = (alerts['negative'] as List).cast<Json>(), exp = (alerts['expiring'] as List).cast<Json>();
    if (low.isEmpty && neg.isEmpty && exp.isEmpty) return const EmptyState(icon: Icons.check_circle_outline_rounded, title: 'All good', message: 'Nothing is low, below zero or about to expire.');
    Widget section(String title, List<Widget> rows) => SectionCard(title: title, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (neg.isNotEmpty) section('Below zero — sales recorded more than was in stock', [for (final x in neg) Text('${x['name']} · ${qtyText(x['stock'] as num, '${x['unit']}')}', style: HPType.body(p.danger))]),
      if (neg.isNotEmpty) const SizedBox(height: HPSpace.lg),
      if (low.isNotEmpty) section('Low stock', [for (final x in low) Text('${x['name']} · ${qtyText(x['stock'] as num, '${x['unit']}')} (reorder at ${qtyText(x['minStock'] as num, '${x['unit']}')})', key: Key('low-${x['sku']}'), style: HPType.body(p.text))]),
      if (low.isNotEmpty) const SizedBox(height: HPSpace.lg),
      if (exp.isNotEmpty) section('Expiring within 7 days', [for (final x in exp) Text('${x['name']} · batch ${x['batchNumber'] ?? '—'} · ${x['expired'] == true ? 'EXPIRED' : 'expires'} ${x['expiryDate']} · ${qtyText(x['quantity'] as num, '${x['unit']}')}', style: HPType.body(x['expired'] == true ? p.danger : p.text))]),
    ]);
  }
}

class _RequestsTab extends StatefulWidget {
  const _RequestsTab({super.key, required this.api, required this.products, required this.canRequest, required this.canHandle});
  final ApiClient api;
  final List<Json> products;
  final bool canRequest, canHandle;
  @override
  State<_RequestsTab> createState() => _RequestsTabState();
}

class _RequestsTabState extends State<_RequestsTab> {
  List<Json>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.api.invRequests();
    if (mounted) setState(() => _rows = r.cast<Json>());
  }

  Future<void> _new() async {
    String? product = widget.products.firstOrNull?['id'] as String?;
    final qty = TextEditingController(), note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => HPDialog(
          title: 'Request stock',
          actions: [SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(d)), PrimaryButton(key: const Key('send-request'), label: 'Send', height: 56, onPressed: () => Navigator.pop(d, true))],
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<String>(initialValue: product, isExpanded: true, decoration: const InputDecoration(labelText: 'Product'), items: [for (final x in widget.products) DropdownMenuItem(value: x['id'] as String, child: Text('${x['name']}'))], onChanged: (v) => set(() => product = v)),
            const SizedBox(height: HPSpace.md),
            TextField(key: const Key('request-qty'), controller: qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Quantity (${widget.products.where((x) => x['id'] == product).firstOrNull?['purchaseUnit'] ?? ''})')),
            const SizedBox(height: HPSpace.md),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)')),
          ]),
        ),
      ),
    );
    final q = double.tryParse(qty.text.trim());
    if (ok != true || product == null || q == null || q <= 0) return;
    try {
      await widget.api.invRequest({'productId': product, 'quantity': q, 'unit': widget.products.firstWhere((x) => x['id'] == product)['purchaseUnit'], if (note.text.trim().isNotEmpty) 'note': note.text.trim()});
      await _load();
      if (mounted) showDone(context, 'Request sent');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _set(Json r, String status) async {
    try {
      await widget.api.invUpdateRequest(r['id'] as String, status);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    if (_rows == null) return const SkeletonBox(height: 160);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.canRequest) Align(alignment: Alignment.centerLeft, child: PrimaryButton(key: const Key('new-request'), label: 'Request stock', icon: Icons.add_shopping_cart_rounded, height: 44, onPressed: widget.products.isEmpty ? null : _new)),
      const SizedBox(height: HPSpace.md),
      if (_rows!.isEmpty)
        const EmptyState(icon: Icons.shopping_cart_outlined, title: 'No requests', message: 'The kitchen asks for stock here; the owner or admin orders it.')
      else
        Card(
          child: Column(children: [
            for (final (i, r) in _rows!.indexed) ...[
              if (i > 0) const Divider(height: 1),
              ListTile(
                title: Text('${(r['product'] as Json)['name']} · ${qtyText(r['quantity'] as num, '${r['unit']}')}', style: HPType.label(p.text)),
                subtitle: Text([shortDate(r['createdAt']), 'by ${r['requestedByName']}', if (r['note'] != null) '${r['note']}'].join(' · '), style: HPType.body(p.muted)),
                trailing: Wrap(spacing: HPSpace.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  StatusChip(label: '${r['status']}', tone: r['status'] == 'received' ? HPTone.success : r['status'] == 'cancelled' ? HPTone.neutral : HPTone.saffron),
                  if (widget.canHandle && r['status'] == 'requested') TextButton(onPressed: () => _set(r, 'ordered'), child: const Text('Ordered')),
                  if (widget.canHandle && (r['status'] == 'requested' || r['status'] == 'ordered')) TextButton(onPressed: () => _set(r, 'received'), child: const Text('Received')),
                  if (widget.canHandle && (r['status'] == 'requested' || r['status'] == 'ordered')) TextButton(onPressed: () => _set(r, 'cancelled'), child: const Text('Cancel')),
                ]),
              ),
            ],
          ]),
        ),
    ]);
  }
}

class _PlacesTab extends StatelessWidget {
  const _PlacesTab({required this.api, required this.locations, required this.suppliers, required this.canManage, required this.onChanged});
  final ApiClient api;
  final List<Json> locations, suppliers;
  final bool canManage;
  final Future<void> Function() onChanged;

  Future<void> _add(BuildContext context, bool supplier) async {
    final name = TextEditingController(), phone = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => HPDialog(
        title: supplier ? 'Add supplier' : 'Add storage location',
        actions: [SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(d)), PrimaryButton(key: const Key('save-place'), label: 'Save', height: 56, onPressed: () => Navigator.pop(d, true))],
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(key: const Key('place-name'), controller: name, autofocus: true, decoration: InputDecoration(labelText: supplier ? 'Supplier name' : 'Location, e.g. Walk-in cooler')),
          if (supplier) ...[const SizedBox(height: HPSpace.md), TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone (optional)'))],
        ]),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    try {
      supplier ? await api.createSupplier({'name': name.text.trim(), if (phone.text.trim().isNotEmpty) 'phone': phone.text.trim()}) : await api.createLocation(name.text.trim());
      await onChanged();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    Widget list(String title, List<Json> rows, bool supplier) => SectionCard(
          title: title,
          actions: [if (canManage) TextButton.icon(key: Key(supplier ? 'add-supplier' : 'add-location'), onPressed: () => _add(context, supplier), icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Add'))],
          child: rows.isEmpty
              ? Text('None yet.', style: HPType.body(p.muted))
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final r in rows) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text([r['name'], if (r['phone'] != null) r['phone']].join(' · '), style: HPType.body(p.text)))]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [list('Storage locations', locations, false), const SizedBox(height: HPSpace.lg), list('Suppliers', suppliers, true)]);
  }
}

class _ValuationTab extends StatefulWidget {
  const _ValuationTab({super.key, required this.api});
  final ApiClient api;
  @override
  State<_ValuationTab> createState() => _ValuationTabState();
}

class _ValuationTabState extends State<_ValuationTab> {
  Json? _v;
  @override
  void initState() {
    super.initState();
    widget.api.invValuation().then((v) {
      if (mounted) setState(() => _v = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    if (_v == null) return const SkeletonBox(height: 160);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, children: [
        SizedBox(width: 260, child: KpiCard(key: const Key('stock-value'), label: 'Stock value', value: rupees(_v!['totalPaise'] as int), caption: '${_v!['method']}', icon: Icons.inventory_2_outlined)),
        for (final c in (_v!['byCategory'] as List).cast<Json>()) SizedBox(width: 200, child: KpiCard(label: '${c['category']}', value: rupees(c['valuePaise'] as int), icon: Icons.category_outlined)),
      ]),
      const SizedBox(height: HPSpace.lg),
      Text('Stock is valued at the moving weighted-average cost of each product: every receipt with a cost updates the average; what leaves stock is valued at the average at that moment.', style: HPType.body(p.muted)),
    ]);
  }
}
