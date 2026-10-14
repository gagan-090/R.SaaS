import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../util/image_prep.dart';
import '../../widgets/common.dart';
import 'dashboard_screen.dart' show rupees;
import 'import_dialog.dart';

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
  bool get _isOwner => (ref.read(authProvider) as SignedIn).roles.contains('owner');
  bool get _canEdit {
    final a = ref.read(authProvider);
    return a is SignedIn && a.can('menu.publish');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool _can(String perm) {
    final a = ref.read(authProvider);
    return a is SignedIn && a.can(perm);
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

  /// Moves a category one place up or down; the POS shows categories in this order.
  Future<void> _moveCategory(Json c, int by) async {
    final ids = _cats!.map((x) => x['id'] as String).toList();
    final i = ids.indexOf(c['id'] as String), j = i + by;
    if (j < 0 || j >= ids.length) return;
    ids
      ..removeAt(i)
      ..insert(j, c['id'] as String);
    await _run(() => _api.orderCategories(ids), 'Order saved');
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
      builder: (_) => _ItemEditor(
        api: _api, item: item, categories: _cats!, taxes: _taxes!, defaultCategory: _cat ?? _cats!.first['id'] as String, paletteIndex: _items!.length,
        canMapRecipes: ref.read(authProvider) is SignedIn && (ref.read(authProvider) as SignedIn).can('inventory.manage'),
      ),
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
      onMove: _moveCategory,
      onToggle: (c) => _run(() => _api.updateCategory(c['id'] as String, {'active': c['active'] == false}),
          c['active'] == false ? '${c['name']} is back on the POS' : '${c['name']} hidden from the POS'),
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
        if (edit && (_can('import.run') || _isOwner))
          SecondaryButton(key: const Key('import-menu'), label: 'Import Excel', icon: _can('import.run') ? Icons.upload_file_rounded : Icons.lock_outline_rounded, onPressed: () async {
            if (!_can('import.run')) {
              showError(context, 'Excel import is not in your plan. Ask the Super Admin to enable "Excel import (menu & inventory)" in Plans, then sign in again.');
              return;
            }
            final done = await showDialog<bool>(context: context, builder: (_) => ImportDialog(api: _api, kind: 'menu'));
            if (done == true) await _load();
          }),
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
    required this.onMove,
    required this.onToggle,
  });
  final List<Json> cats, items;
  final String? selected;
  final bool canEdit, horizontal;
  final ValueChanged<String?> onSelect;
  final VoidCallback onAdd;
  final ValueChanged<Json> onRename, onDelete, onToggle;
  final void Function(Json c, int by) onMove;

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
      final cat = id == null ? null : cats.firstWhere((c) => c['id'] == id);
      final hidden = cat?['active'] == false;
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: sel ? p.raised : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: ListTile(
            key: Key('category-$name'),
            dense: true,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: Text(hidden ? '$name · hidden' : name, style: HPType.label(hidden ? p.faint : (sel ? p.text : p.muted))),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${_count(id)}', style: HPType.body(p.faint)),
              if (canEdit && id != null)
                PopupMenuButton<String>(
                  tooltip: 'Category actions',
                  icon: Icon(Icons.more_vert_rounded, size: 18, color: p.muted),
                  onSelected: (v) => switch (v) {
                    'rename' => onRename(cat!),
                    'up' => onMove(cat!, -1),
                    'down' => onMove(cat!, 1),
                    'toggle' => onToggle(cat!),
                    _ => onDelete(cat!),
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    const PopupMenuItem(value: 'up', child: Text('Move up')),
                    const PopupMenuItem(value: 'down', child: Text('Move down')),
                    PopupMenuItem(value: 'toggle', child: Text(hidden ? 'Show on the POS' : 'Hide from the POS')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
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
                Text(_tilePrice(item), style: HPType.label(p.text)),
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
  const _ItemEditor({required this.api, required this.item, required this.categories, required this.taxes, required this.defaultCategory, required this.paletteIndex, this.canMapRecipes = false});
  final ApiClient api;
  final bool canMapRecipes;
  final Json? item;
  final List<Json> categories, taxes;
  final String defaultCategory;
  final int paletteIndex;
  @override
  State<_ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<_ItemEditor> {
  late final _name = TextEditingController(text: widget.item?['name'] as String? ?? '');
  late final List<_SizeDraft> _sizes = [
    for (final v in ((widget.item?['variants'] as List?) ?? const []).cast<Json>()) _SizeDraft.from(v),
    if (((widget.item?['variants'] as List?) ?? const []).isEmpty) _SizeDraft.blank(isDefault: true),
  ];
  late final _desc = TextEditingController(text: widget.item?['description'] as String? ?? '');
  late String _category = widget.item?['categoryId'] as String? ?? widget.defaultCategory;
  late String _tax = widget.item?['taxRuleId'] as String? ?? (widget.taxes.firstWhere((t) => t['rateBp'] == 500, orElse: () => widget.taxes.first)['id'] as String);
  late bool _veg = widget.item?['isVeg'] as bool? ?? true;
  late bool _available = widget.item?['available'] as bool? ?? true;
  late final String? _imageId = widget.item?['imageId'] as String?;
  PreparedImage? _newPhoto;
  bool _removePhoto = false, _busy = false;
  String? _error;


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
    if (_name.text.trim().isEmpty) return setState(() => _error = 'Give the dish a name');
    final problem = _sizes.map((s) => s.problem).whereType<String>().firstOrNull;
    if (problem != null) return setState(() => _error = problem);
    final codes = _sizes.map((s) => s.code.text.trim().toUpperCase()).where((c) => c.isNotEmpty).toList();
    if (codes.toSet().length != codes.length) return setState(() => _error = 'Two sizes have the same code');
    if (!_sizes.any((s) => s.isDefault)) _sizes.first.isDefault = true;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final variants = [for (final s in _sizes) s.toJson()];
      final body = {
        'name': _name.text.trim(), 'categoryId': _category, 'taxRuleId': _tax, 'isVeg': _veg, 'available': _available,
        if (_desc.text.trim().isNotEmpty) 'description': _desc.text.trim(),
      };
      final Json saved;
      if (widget.item == null) {
        saved = await widget.api.createItem({...body, 'plateColors': _plate(), 'variants': variants});
      } else {
        await widget.api.updateItem(widget.item!['id'] as String, body);
        saved = await widget.api.setVariants(widget.item!['id'] as String, variants);
      }
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
        const SizedBox(height: HPSpace.lg),
        Row(children: [
          Expanded(child: Text('SIZES & PORTIONS', style: HPType.overline(p.muted))),
          TextButton.icon(key: const Key('add-size'), onPressed: _sizes.length >= 20 ? null : () => setState(() => _sizes.add(_SizeDraft.blank())), icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Add size')),
        ]),
        Text('Each size has its own price (before GST). A half plate does not have to cost half.', style: HPType.body(p.muted).copyWith(fontSize: 12)),
        const SizedBox(height: HPSpace.sm),
        for (final (i, s) in _sizes.indexed)
          _SizeRow(
            key: ObjectKey(s),
            index: i,
            size: s,
            canRemove: _sizes.length > 1,
            onDefault: () => setState(() {
              for (final x in _sizes) {
                x.isDefault = identical(x, s);
              }
            }),
            onRemove: () => setState(() {
              _sizes.remove(s);
              if (!_sizes.any((x) => x.isDefault)) _sizes.first.isDefault = true;
            }),
            onChanged: () => setState(() {}),
            onRecipe: widget.canMapRecipes && s.id != null
                ? () => showDialog<void>(context: context, builder: (_) => RecipeDialog(api: widget.api, variantId: s.id!, title: '${_name.text.trim()} · ${s.name.text.trim()}'))
                : null,
          ),
        if (widget.canMapRecipes && _sizes.any((s) => s.id == null))
          Text('Save the dish first, then map each size to its ingredients with "Recipe".', style: HPType.body(p.muted).copyWith(fontSize: 12)),
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

const servingUnits = ['ml', 'l', 'g', 'kg', 'piece', 'plate', 'bowl', 'glass', 'cup', 'portion', 'bottle', 'can', 'packet'];
const portionLabels = ['quarter', 'half', 'full', 'custom'];

/// One size / portion being edited. Prices are typed in rupees and sent as integer paise.
class _SizeDraft {
  _SizeDraft({this.id, String code = '', String name = '', String price = '', String qty = '', this.unit, this.portion, String ratio = '', this.available = true, this.isDefault = false})
      : code = TextEditingController(text: code),
        name = TextEditingController(text: name),
        price = TextEditingController(text: price),
        qty = TextEditingController(text: qty),
        ratio = TextEditingController(text: ratio);
  factory _SizeDraft.blank({bool isDefault = false}) => _SizeDraft(name: 'Regular', isDefault: isDefault);
  factory _SizeDraft.from(Json v) {
    String n(Object? x) => x == null ? '' : ((x as num) % 1 == 0 ? '${x.toInt()}' : '$x');
    final paise = v['pricePaise'] as int;
    return _SizeDraft(
      id: v['id'] as String?, code: '${v['code'] ?? ''}', name: '${v['name']}', price: paise % 100 == 0 ? '${paise ~/ 100}' : (paise / 100).toStringAsFixed(2),
      qty: n(v['servingQuantity']), unit: v['servingUnit'] as String?, portion: v['portionLabel'] as String?, ratio: n(v['portionRatio']),
      available: v['available'] != false, isDefault: v['isDefault'] == true,
    );
  }
  final String? id;
  final TextEditingController code, name, price, qty, ratio;
  String? unit, portion;
  bool available, isDefault;

  int? get paise {
    final v = double.tryParse(price.text.trim().replaceAll(',', ''));
    return v == null || v < 0 ? null : (v * 100).round();
  }

  String? get problem {
    if (name.text.trim().isEmpty) return 'Every size needs a name, e.g. "500 ml" or "Half plate"';
    if (paise == null) return 'Enter a price in rupees for ${name.text.trim()}, e.g. 249';
    final q = qty.text.trim();
    if (q.isNotEmpty && (double.tryParse(q) == null || double.parse(q) <= 0)) return 'Serving quantity for ${name.text.trim()} must be a number above 0';
    if ((q.isEmpty) != (unit == null)) return 'Give ${name.text.trim()} both a serving quantity and a unit, or neither';
    final r = ratio.text.trim();
    if (r.isNotEmpty && (double.tryParse(r) == null || double.parse(r) <= 0)) return 'Portion ratio for ${name.text.trim()} must be above 0 (1 = full portion)';
    return null;
  }

  Json toJson() => {
        if (id != null) 'id': id,
        if (code.text.trim().isNotEmpty) 'code': code.text.trim().toUpperCase(),
        'name': name.text.trim(),
        'pricePaise': paise,
        'portionLabel': portion,
        'servingQuantity': qty.text.trim().isEmpty ? null : double.parse(qty.text.trim()),
        'servingUnit': unit,
        'portionRatio': ratio.text.trim().isEmpty ? null : double.parse(ratio.text.trim()),
        'available': available,
        'isDefault': isDefault,
      };
}

class _SizeRow extends StatelessWidget {
  const _SizeRow({super.key, required this.index, required this.size, required this.canRemove, required this.onDefault, required this.onRemove, required this.onChanged, this.onRecipe});
  final int index;
  final _SizeDraft size;
  final bool canRemove;
  final VoidCallback onDefault, onRemove, onChanged;
  final VoidCallback? onRecipe;

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    Widget box(double w, Widget child) => SizedBox(width: w, child: child);
    return Card(
      margin: const EdgeInsets.only(bottom: HPSpace.sm),
      color: p.raised,
      child: Padding(
        padding: const EdgeInsets.all(HPSpace.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
            box(170, TextField(key: Key('size-name-$index'), controller: size.name, decoration: const InputDecoration(labelText: 'Size / portion', hintText: '500 ml'), onChanged: (_) => onChanged())),
            box(120, TextField(key: Key('size-price-$index'), controller: size.price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Price', prefixText: '₹ '))),
            box(100, TextField(key: Key('size-qty-$index'), controller: size.qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Serves'))),
            box(110, DropdownButtonFormField<String?>(
              key: Key('size-unit-$index'),
              initialValue: size.unit,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Unit'),
              items: [const DropdownMenuItem<String?>(value: null, child: Text('—')), for (final u in servingUnits) DropdownMenuItem<String?>(value: u, child: Text(u))],
              onChanged: (v) {
                size.unit = v;
                onChanged();
              },
            )),
            box(120, DropdownButtonFormField<String?>(
              initialValue: size.portion,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Portion'),
              items: [const DropdownMenuItem<String?>(value: null, child: Text('—')), for (final l in portionLabels) DropdownMenuItem<String?>(value: l, child: Text(l))],
              onChanged: (v) {
                size.portion = v;
                onChanged();
              },
            )),
            box(100, Tooltip(
              message: 'Default recipe scale vs the full portion (1 = full). Prices are never derived from it.',
              child: TextField(controller: size.ratio, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Ratio')),
            )),
            box(150, TextField(controller: size.code, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Code (optional)', hintText: 'COLA-500'))),
          ]),
          Wrap(spacing: HPSpace.md, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Radio<bool>(key: Key('size-default-$index'), value: true, groupValue: size.isDefault, onChanged: (_) => onDefault()), // ignore: deprecated_member_use
              Text('Default', style: HPType.body(p.text)),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(value: size.available, onChanged: (v) {
                size.available = v;
                onChanged();
              }),
              Text(size.available ? 'Available' : 'Sold out', style: HPType.body(p.text)),
            ]),
            if (onRecipe != null) TextButton.icon(key: Key('size-recipe-$index'), onPressed: onRecipe, icon: const Icon(Icons.blender_outlined, size: 18), label: const Text('Recipe')),
            if (canRemove) TextButton.icon(key: Key('size-remove-$index'), onPressed: onRemove, icon: const Icon(Icons.delete_outline_rounded, size: 18), label: const Text('Remove')),
          ]),
        ]),
      ),
    );
  }
}

/// "₹340" for one size; "₹30 – ₹90 · 3 sizes" when the dish comes in several.
String _tilePrice(Json item) {
  final vs = ((item['variants'] as List?) ?? const []).cast<Json>();
  if (vs.length <= 1) return rupees((vs.firstOrNull?['pricePaise'] ?? item['pricePaise']) as int);
  final prices = vs.map((v) => v['pricePaise'] as int).toList()..sort();
  return '${rupees(prices.first)} – ${rupees(prices.last)} · ${vs.length} sizes';
}

/// What one sold unit of a size uses from stock. Without its own recipe a size uses the full portion's recipe scaled
/// by its portion ratio; saving here gives it its own. Shows the cost of one serving next to its selling price.
class RecipeDialog extends StatefulWidget {
  const RecipeDialog({super.key, required this.api, required this.variantId, required this.title});
  final ApiClient api;
  final String variantId, title;
  @override
  State<RecipeDialog> createState() => _RecipeDialogState();
}

class _RecipeDialogState extends State<RecipeDialog> {
  Json? _recipe;
  List<Json>? _products;
  final _lines = <({String? productId, TextEditingController qty, String unit})>[];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([widget.api.recipe(widget.variantId), widget.api.invProducts()]);
      if (!mounted) return;
      setState(() {
        _recipe = r[0] as Json;
        _products = (r[1] as List).cast<Json>();
        _lines
          ..clear()
          ..addAll([
            for (final l in ((_recipe!['lines'] as List).cast<Json>()))
              (productId: l['productId'] as String?, qty: TextEditingController(text: '${l['quantity']}'), unit: '${l['unit']}'),
          ]);
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _save() async {
    final out = <Json>[];
    for (final l in _lines) {
      final q = double.tryParse(l.qty.text.trim());
      if (l.productId == null || q == null || q <= 0) return setState(() => _error = 'Every ingredient needs a product and a quantity above 0');
      out.add({'productId': l.productId, 'quantity': q, 'unit': l.unit});
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.setRecipe(widget.variantId, out);
      if (mounted) {
        setState(() => _recipe = r);
        Navigator.pop(context);
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return HPDialog(
      title: 'Recipe · ${widget.title}',
      actions: [
        SecondaryButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        PrimaryButton(key: const Key('save-recipe'), label: 'Save recipe', busy: _busy, height: 56, onPressed: _products == null ? null : _save),
      ],
      child: _recipe == null
          ? (_error == null ? const LinearProgressIndicator() : Text(_error!, style: HPType.body(p.danger)))
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                _recipe!['own'] == true
                    ? 'One sold serving uses:'
                    : (_lines.isEmpty ? 'No recipe yet: selling it takes nothing from stock.' : 'Using the full portion × this size\'s ratio. Save to give this size its own amounts.'),
                style: HPType.body(p.muted),
              ),
              const SizedBox(height: HPSpace.sm),
              for (final (i, l) in _lines.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: HPSpace.sm),
                  child: Row(children: [
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        key: Key('recipe-product-$i'),
                        initialValue: l.productId,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Ingredient'),
                        items: [for (final x in _products!) DropdownMenuItem(value: x['id'] as String, child: Text('${x['name']} (${x['sku']})', overflow: TextOverflow.ellipsis))],
                        onChanged: (v) => setState(() => _lines[i] = (productId: v, qty: l.qty, unit: '${_products!.firstWhere((x) => x['id'] == v)['baseUnit']}')),
                      ),
                    ),
                    const SizedBox(width: HPSpace.sm),
                    SizedBox(width: 90, child: TextField(key: Key('recipe-qty-$i'), controller: l.qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Qty'))),
                    const SizedBox(width: HPSpace.sm),
                    SizedBox(
                      width: 96,
                      child: DropdownButtonFormField<String>(
                        initialValue: l.unit,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Unit'),
                        items: [for (final u in {l.unit, 'g', 'kg', 'ml', 'l', 'piece', 'bottle', 'can', 'packet'}) DropdownMenuItem(value: u, child: Text(u))],
                        onChanged: (v) => setState(() => _lines[i] = (productId: l.productId, qty: l.qty, unit: v!)),
                      ),
                    ),
                    IconButton(tooltip: 'Remove', icon: const Icon(Icons.close_rounded), onPressed: () => setState(() => _lines.removeAt(i))),
                  ]),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('add-ingredient'),
                  onPressed: (_products ?? const []).isEmpty ? null : () => setState(() => _lines.add((productId: null, qty: TextEditingController(), unit: 'g'))),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text((_products ?? const []).isEmpty ? 'Add products in Inventory first' : 'Add ingredient'),
                ),
              ),
              const Divider(),
              Text('Cost of one serving ${rupees(_recipe!['costPaise'] as int)} · sells for ${rupees(_recipe!['pricePaise'] as int)}', key: const Key('recipe-cost'), style: HPType.label(p.text)),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: HPSpace.sm), child: Text(_error!, style: HPType.body(p.danger))),
            ]),
    );
  }
}
