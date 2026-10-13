import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../util/image_prep.dart';
import '../../widgets/common.dart';
import 'dashboard_screen.dart' show rupees;

Color hexColor(Object? v, Color fallback) {
  final s = '${v ?? ''}'.replaceAll('#', '');
  return s.length == 6 ? Color(int.parse('FF$s', radix: 16)) : fallback;
}

/// Plate colours for new dishes, so a menu looks appetising before any photo is uploaded (STYLE.md §6).
const _palettes = [
  ['#D9622B', '#F2C27B', '#4F8A3B'], ['#8A3B1F', '#F5E3C3', '#6FA14A'], ['#6B2E1E', '#E8D2A8', '#3F7D3A'], ['#E7C27D', '#B9823A', '#5E8F3E'],
  ['#D99A2B', '#8B4A2B', '#F2E4C2'], ['#F2B33D', '#F7D27A', '#E07A2E'], ['#EFE8D6', '#CFE3C2', '#6E9B4E'], ['#6E2A12', '#9C4520', '#E9C46A'],
];

/// O3 Menu: categories, dishes with price / GST / veg / availability, and photos. Changes reach the hub on its next pull.
class MenuScreen extends ConsumerStatefulWidget {
  const MenuScreen({super.key});
  @override
  ConsumerState<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends ConsumerState<MenuScreen> {
  List<Json>? _cats, _items, _taxes;
  Object? _error;
  String? _cat; // null = all
  String _q = '';

  ApiClient get _api => ref.read(apiProvider);
  bool get _canEdit {
    final a = ref.read(authProvider);
    return a is SignedIn && a.can('menu.publish');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([_api.categories(), _api.items(), _api.taxRules()]);
      if (!mounted) return;
      setState(() {
        _cats = r[0].cast<Json>();
        _items = r[1].cast<Json>();
        _taxes = r[2].cast<Json>();
        _error = null;
        if (_cat != null && !_cats!.any((c) => c['id'] == _cat)) _cat = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _run(Future<void> Function() f, [String? done]) async {
    try {
      await f();
      await _load();
      if (done != null && mounted) showDone(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  // ---------------- categories

  Future<void> _editCategory([Json? c]) async {
    final name = TextEditingController(text: c?['name'] as String? ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => HPDialog(
        title: c == null ? 'New category' : 'Rename category',
        actions: [
          SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(d)),
          PrimaryButton(label: 'Save', height: 56, onPressed: () => Navigator.pop(d, true)),
        ],
        child: TextField(key: const Key('category-name'), controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Name, e.g. Starters'), onSubmitted: (_) => Navigator.pop(d, true)),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    await _run(
      () async => c == null ? await _api.createCategory(name.text.trim(), sortOrder: _cats?.length ?? 0) : await _api.updateCategory(c['id'] as String, {'name': name.text.trim()}),
      c == null ? 'Category added' : 'Category renamed',
    );
  }

  Future<void> _deleteCategory(Json c) async {
    if (!await confirm(context, title: 'Delete ${c['name']}?', message: 'Only empty categories can be deleted. Terminals remove it on their next sync.')) return;
    await _run(() => _api.deleteCategory(c['id'] as String), 'Category deleted');
  }

  // ---------------- dishes

  Future<void> _ensureTax() async {
    if (_taxes!.isNotEmpty) return;
    await _api.createTaxRule('GST 5%', 500);
    _taxes = (await _api.taxRules()).cast<Json>();
  }

  Future<void> _editItem([Json? item]) async {
    if (_cats!.isEmpty) {
      showError(context, 'Add a category first (for example "Starters").');
      return;
    }
    try {
      await _ensureTax();
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ItemEditor(api: _api, item: item, categories: _cats!, taxes: _taxes!, defaultCategory: _cat ?? _cats!.first['id'] as String, paletteIndex: _items!.length),
    );
    if (saved == true) {
      await _load();
      if (mounted) showDone(context, item == null ? 'Dish added' : 'Dish saved');
    }
  }

  Future<void> _toggle(Json item, bool available) => _run(() => _api.updateItem(item['id'] as String, {'available': available}), available ? '${item['name']} is back on' : '${item['name']} marked sold out');

  @override
  Widget build(BuildContext context) {
    if (_error != null) return ErrorState(message: '$_error', onRetry: _load);
    if (_cats == null) return const SkeletonGrid(maxExtent: 260, aspect: 1.4);
    final narrow = isNarrowWeb(context);
    final edit = _canEdit;
    final visible = _items!
        .where((i) => _cat == null || i['categoryId'] == _cat)
        .where((i) => _q.isEmpty || '${i['name']}'.toLowerCase().contains(_q.toLowerCase()))
        .toList();
    final catName = {for (final c in _cats!) c['id']: c['name']};

    final categoryRail = _CategoryList(
      cats: _cats!,
      items: _items!,
      selected: _cat,
      canEdit: edit,
      horizontal: narrow,
      onSelect: (id) => setState(() => _cat = id),
      onAdd: _editCategory,
      onRename: _editCategory,
      onDelete: _deleteCategory,
    );

    final grid = visible.isEmpty
        ? EmptyState(
            icon: Icons.restaurant_menu_rounded,
            title: _items!.isEmpty ? 'Your menu is empty' : 'No dishes match',
            message: _items!.isEmpty ? 'Add categories and dishes. Photos are optional — every dish gets an illustrated plate.' : null,
            action: edit && _items!.isEmpty ? PrimaryButton(label: 'Add your first dish', icon: Icons.add_rounded, onPressed: () => _editItem()) : null,
          )
        : LayoutBuilder(builder: (c, box) {
            final cols = (box.maxWidth / 300).floor().clamp(1, 4);
            const gap = HPSpace.md;
            final w = (box.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(spacing: gap, runSpacing: gap, children: [
              for (final i in visible)
                SizedBox(
                  width: w,
                  child: _ItemTile(
                    key: Key('item-${i['name']}'),
                    item: i,
                    category: '${catName[i['categoryId']] ?? ''}',
                    imageUrl: i['imageId'] == null ? null : _api.mediaUrl(i['imageId'] as String),
                    canEdit: edit,
                    onEdit: () => _editItem(i),
                    onToggle: (v) => _toggle(i, v),
                    onDelete: () async {
                      if (await confirm(context, title: 'Delete ${i['name']}?', message: 'It disappears from every terminal on the next sync. Past bills keep their copy of the name and price.')) {
                        await _run(() => _api.deleteItem(i['id'] as String), 'Dish deleted');
                      }
                    },
                  ),
                ),
            ]);
          });

    return PageFrame(
      title: 'Menu',
      subtitle: '${_items!.length} dishes · ${_cats!.length} categories · changes reach your terminals within a minute',
      actions: [
        SizedBox(width: narrow ? double.infinity : 260, child: HPSearchField(hint: 'Search dishes', onChanged: (v) => setState(() => _q = v))),
        if (edit) PrimaryButton(key: const Key('add-dish'), label: 'Add dish', icon: Icons.add_rounded, height: 48, onPressed: () => _editItem()),
      ],
      child: narrow
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [categoryRail, const SizedBox(height: HPSpace.lg), grid])
          : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 240, child: categoryRail),
              const SizedBox(width: HPSpace.x2),
              Expanded(child: grid),
            ]),
    );
  }
}

class _CategoryList extends StatelessWidget {
  const _CategoryList({
    required this.cats,
    required this.items,
    required this.selected,
    required this.canEdit,
    required this.horizontal,
    required this.onSelect,
    required this.onAdd,
    required this.onRename,
    required this.onDelete,
  });
  final List<Json> cats, items;
  final String? selected;
  final bool canEdit, horizontal;
  final ValueChanged<String?> onSelect;
  final VoidCallback onAdd;
  final ValueChanged<Json> onRename, onDelete;

  int _count(String? id) => items.where((i) => id == null || i['categoryId'] == id).length;

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    if (horizontal) {
      return SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          Padding(padding: const EdgeInsets.only(right: HPSpace.sm), child: CategoryChip(label: 'All', count: _count(null), selected: selected == null, onTap: () => onSelect(null))),
          for (final c in cats)
            Padding(
              padding: const EdgeInsets.only(right: HPSpace.sm),
              child: GestureDetector(
                onLongPress: canEdit ? () => onRename(c) : null,
                child: CategoryChip(label: '${c['name']}', count: _count(c['id'] as String), selected: selected == c['id'], onTap: () => onSelect(c['id'] as String)),
              ),
            ),
          if (canEdit) ActionChip(key: const Key('add-category'), avatar: const Icon(Icons.add_rounded, size: 18), label: const Text('Category'), onPressed: onAdd),
        ]),
      );
    }
    Widget row(String? id, String name) {
      final sel = selected == id;
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: sel ? p.raised : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: ListTile(
            key: Key('category-$name'),
            dense: true,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: Text(name, style: HPType.label(sel ? p.text : p.muted)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${_count(id)}', style: HPType.body(p.faint)),
              if (canEdit && id != null)
                PopupMenuButton<String>(
                  tooltip: 'Category actions',
                  icon: Icon(Icons.more_vert_rounded, size: 18, color: p.muted),
                  onSelected: (v) => v == 'rename' ? onRename(cats.firstWhere((c) => c['id'] == id)) : onDelete(cats.firstWhere((c) => c['id'] == id)),
                  itemBuilder: (_) => const [PopupMenuItem(value: 'rename', child: Text('Rename')), PopupMenuItem(value: 'delete', child: Text('Delete'))],
                ),
            ]),
            onTap: () => onSelect(id),
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HPSpace.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.fromLTRB(HPSpace.md, HPSpace.sm, HPSpace.md, HPSpace.sm), child: Text('CATEGORIES', style: HPType.overline(p.muted))),
          row(null, 'All dishes'),
          for (final c in cats) row(c['id'] as String, '${c['name']}'),
          if (canEdit) ...[
            const SizedBox(height: HPSpace.sm),
            TextButton.icon(key: const Key('add-category'), onPressed: onAdd, icon: const Icon(Icons.add_rounded), label: const Text('Add category')),
          ],
        ]),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({super.key, required this.item, required this.category, required this.imageUrl, required this.canEdit, required this.onEdit, required this.onToggle, required this.onDelete});
  final Json item;
  final String category;
  final String? imageUrl;
  final bool canEdit;
  final VoidCallback onEdit, onDelete;
  final ValueChanged<bool> onToggle;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final pc = item['plateColors'] as Map?;
    final available = item['available'] == true;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: canEdit ? onEdit : null,
        child: Padding(
          padding: const EdgeInsets.all(HPSpace.lg),
          child: Row(children: [
            AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: available ? 1 : .45,
              child: DishImage(
                image: imageUrl == null ? null : NetworkImage(imageUrl!),
                base: hexColor(pc?['base'], HPColors.saffron),
                sauce: hexColor(pc?['sauce'], HPColors.ghee),
                garnish: hexColor(pc?['garnish'], HPColors.cardamom),
                size: 64,
              ),
            ),
            const SizedBox(width: HPSpace.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  VegMark(isVeg: item['isVeg'] == true, size: 14),
                  const SizedBox(width: 6),
                  Expanded(child: Text('${item['name']}', style: HPType.titleCard(p.text).copyWith(fontSize: 17), overflow: TextOverflow.ellipsis)),
                ]),
                const SizedBox(height: 2),
                Text(category, style: HPType.body(p.muted).copyWith(fontSize: 12), overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text(rupees(item['pricePaise'] as int), style: HPType.label(p.text)),
              ]),
            ),
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Tooltip(
                message: available ? 'On the menu — switch off when sold out' : 'Sold out — switch on to sell again',
                child: Switch(key: Key('available-${item['name']}'), value: available, onChanged: canEdit ? onToggle : null),
              ),
              if (canEdit)
                PopupMenuButton<String>(
                  tooltip: 'Dish actions',
                  icon: Icon(Icons.more_horiz_rounded, color: p.muted),
                  onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                  itemBuilder: (_) => const [PopupMenuItem(value: 'edit', child: Text('Edit & photo')), PopupMenuItem(value: 'delete', child: Text('Delete'))],
                ),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Add / edit a dish, with photo upload (cropped and compressed in the browser) or the illustrated plate.
class _ItemEditor extends StatefulWidget {
  const _ItemEditor({required this.api, required this.item, required this.categories, required this.taxes, required this.defaultCategory, required this.paletteIndex});
  final ApiClient api;
  final Json? item;
  final List<Json> categories, taxes;
  final String defaultCategory;
  final int paletteIndex;
  @override
  State<_ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<_ItemEditor> {
  late final _name = TextEditingController(text: widget.item?['name'] as String? ?? '');
  late final _price = TextEditingController(text: widget.item == null ? '' : _plain(widget.item!['pricePaise'] as int));
  late final _desc = TextEditingController(text: widget.item?['description'] as String? ?? '');
  late String _category = widget.item?['categoryId'] as String? ?? widget.defaultCategory;
  late String _tax = widget.item?['taxRuleId'] as String? ?? (widget.taxes.firstWhere((t) => t['rateBp'] == 500, orElse: () => widget.taxes.first)['id'] as String);
  late bool _veg = widget.item?['isVeg'] as bool? ?? true;
  late bool _available = widget.item?['available'] as bool? ?? true;
  late final String? _imageId = widget.item?['imageId'] as String?;
  PreparedImage? _newPhoto;
  bool _removePhoto = false, _busy = false;
  String? _error;

  static String _plain(int paise) => paise % 100 == 0 ? '${paise ~/ 100}' : (paise / 100).toStringAsFixed(2);

  int? get _paise {
    final v = double.tryParse(_price.text.trim().replaceAll(',', ''));
    return v == null || v < 0 ? null : (v * 100).round();
  }

  Future<void> _pick() async {
    try {
      final raw = await pickPhoto();
      if (raw == null) return;
      final prepared = prepareDishPhoto(raw);
      setState(() {
        _newPhoto = prepared;
        _removePhoto = false;
        _error = null;
      });
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _save() async {
    final paise = _paise;
    if (_name.text.trim().isEmpty) return setState(() => _error = 'Give the dish a name');
    if (paise == null) return setState(() => _error = 'Enter a price in rupees, e.g. 249');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = {
        'name': _name.text.trim(), 'categoryId': _category, 'pricePaise': paise, 'taxRuleId': _tax, 'isVeg': _veg, 'available': _available,
        if (_desc.text.trim().isNotEmpty) 'description': _desc.text.trim(),
      };
      final saved = widget.item == null
          ? await widget.api.createItem({...body, 'plateColors': _plate()})
          : await widget.api.updateItem(widget.item!['id'] as String, body);
      final id = saved['id'] as String;
      if (_newPhoto != null) {
        await widget.api.setItemImage(id, _newPhoto!.contentType, _newPhoto!.base64);
      } else if (_removePhoto && _imageId != null) {
        await widget.api.removeItemImage(id);
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Side by side on wide dialogs, stacked on phones.
  Widget _flexible(Widget child) => MediaQuery.sizeOf(context).width < 600 ? child : Expanded(child: child);

  Map<String, String> _plate() {
    final c = _palettes[widget.paletteIndex % _palettes.length];
    return {'base': c[0], 'sauce': c[1], 'garnish': c[2]};
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final pc = (widget.item?['plateColors'] as Map?) ?? _plate();
    final ImageProvider? photo = _newPhoto != null
        ? MemoryImage(_newPhoto!.bytes)
        : (!_removePhoto && _imageId != null ? NetworkImage(widget.api.mediaUrl(_imageId)) : null);
    return HPDialog(
      title: widget.item == null ? 'Add a dish' : 'Edit ${widget.item!['name']}',
      actions: [
        SecondaryButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        PrimaryButton(key: const Key('save-dish'), label: 'Save', busy: _busy, height: 56, onPressed: _save),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          DishImage(image: photo, base: hexColor(pc['base'], HPColors.saffron), sauce: hexColor(pc['sauce'], HPColors.ghee), garnish: hexColor(pc['garnish'], HPColors.cardamom), size: 88),
          const SizedBox(width: HPSpace.lg),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(photo == null ? 'Illustrated plate' : 'Photo', style: HPType.label(p.text)),
              Text('Square photos look best. We crop and compress it for you.', style: HPType.body(p.muted).copyWith(fontSize: 12)),
              const SizedBox(height: HPSpace.sm),
              Wrap(spacing: HPSpace.sm, children: [
                OutlinedButton.icon(key: const Key('pick-photo'), onPressed: _busy ? null : _pick, icon: const Icon(Icons.photo_camera_outlined, size: 18), label: Text(photo == null ? 'Upload photo' : 'Change')),
                if (photo != null)
                  TextButton(onPressed: _busy ? null : () => setState(() { _newPhoto = null; _removePhoto = true; }), child: const Text('Remove')),
              ]),
            ]),
          ),
        ]),
        const SizedBox(height: HPSpace.lg),
        TextField(key: const Key('dish-name'), controller: _name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Dish name')),
        const SizedBox(height: HPSpace.md),
        Flex(
          direction: MediaQuery.sizeOf(context).width < 600 ? Axis.vertical : Axis.horizontal,
          crossAxisAlignment: MediaQuery.sizeOf(context).width < 600 ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
          children: [
          _flexible(
            TextField(
              key: const Key('dish-price'),
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Price', prefixText: '₹ ', helperText: 'Before GST'),
            ),
          ),
          const SizedBox(width: HPSpace.md, height: HPSpace.md),
          _flexible(
            DropdownButtonFormField<String>(
              initialValue: _tax,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'GST', helperText: 'Split as CGST + SGST'),
              items: [for (final t in widget.taxes) DropdownMenuItem(value: t['id'] as String, child: Text('${t['name']}', overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => _tax = v!),
            ),
          ),
        ]),
        const SizedBox(height: HPSpace.md),
        DropdownButtonFormField<String>(
          initialValue: _category,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Category'),
          items: [for (final c in widget.categories) DropdownMenuItem(value: c['id'] as String, child: Text('${c['name']}'))],
          onChanged: (v) => setState(() => _category = v!),
        ),
        const SizedBox(height: HPSpace.md),
        TextField(controller: _desc, maxLines: 2, decoration: const InputDecoration(labelText: 'Description (optional)')),
        const SizedBox(height: HPSpace.sm),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Vegetarian'), secondary: VegMark(isVeg: _veg), value: _veg, onChanged: (v) => setState(() => _veg = v)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Available now'), subtitle: const Text('Turn off when it is sold out'), value: _available, onChanged: (v) => setState(() => _available = v)),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: HPSpace.sm), child: Text(_error!, key: const Key('dish-error'), style: HPType.body(p.danger))),
      ]),
    );
  }
}
