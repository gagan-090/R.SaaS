import 'package:flutter/foundation.dart' show mergeSort;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../util/image_prep.dart';
import '../../util/money_input.dart';
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

/// Standard 40 professional categories from Restaurant_POS_Menu_With_Serving_Sizes.xlsx
const standardMenuCategories = [
  'Soups', 'Veg Starters', 'Non-Veg Starters', 'Tandoori Items',
  'Veg Main Course', 'Paneer Special', 'Dal Special', 'Non-Veg Main Course',
  'Seafood', 'Indian Breads', 'Rice', 'Biryani', 'Pulao',
  'Chinese Starters', 'Chinese Main Course', 'South Indian', 'North Indian',
  'Continental', 'Italian', 'Fast Food', 'Street Food / Chaat',
  'Breakfast', 'Snacks', 'Rolls & Wraps', 'Thali / Combos',
  'Salads', 'Raita & Curd', 'Papad & Accompaniments', 'Desserts',
  'Ice Cream', 'Cakes & Bakery', 'Hot Beverages', 'Cold Beverages',
  'Shakes & Smoothies', 'Fresh Juices', 'Mocktails', 'Packaged Beverages',
  'Kids Menu', 'Jain Food', 'Chef Specials',
];

const popularExcelCategories = [
  'Packaged Beverages',
  'Cold Beverages',
  'Hot Beverages',
  'Fast Food',
  'Biryani',
  'Veg Main Course',
  'Paneer Special',
  'Dal Special',
  'Desserts',
];

/// Smart classification of dish name to the 40 standard categories in Restaurant_POS_Menu_With_Serving_Sizes.xlsx
String? detectMenuCategory(String rawName) {
  final name = rawName.trim().toLowerCase();
  if (name.isEmpty) return null;

  // Packaged Beverages (e.g. Coke, Water, Soda, Energy drink)
  if (RegExp(r'\b(coke|cola|pepsi|sprite|fanta|thums\s*up|limca|mirinda|mountain\s*dew|red\s*bull|monster|sting|kinley|aquafina|bisleri|water\s*bottle|packaged\s*water|soda\s*can|ginger\s*ale|tonic\s*water|appy|beverage|can|tin)\b').hasMatch(name)) {
    return 'Packaged Beverages';
  }
  // Cold Beverages
  if (RegExp(r'\b(cold\s*coffee|iced\s*tea|iced\s*latte|iced\s*americano|lassi|chaas|buttermilk|lime\s*soda|lime\s*water|nimbu\s*pani|jaljeera|masala\s*soda)\b').hasMatch(name)) {
    return 'Cold Beverages';
  }
  // Shakes & Smoothies
  if (RegExp(r'\b(shake|smoothie|frappe)\b').hasMatch(name)) {
    return 'Shakes & Smoothies';
  }
  // Fresh Juices
  if (RegExp(r'\b(juice|fresh\s*juice|mosambi|orange\s*juice|watermelon\s*juice|pineapple\s*juice|apple\s*juice)\b').hasMatch(name)) {
    return 'Fresh Juices';
  }
  // Mocktails
  if (RegExp(r'\b(mojito|mocktail|colada|cooler|punch|blue\s*lagoon)\b').hasMatch(name)) {
    return 'Mocktails';
  }
  // Hot Beverages
  if (RegExp(r'\b(tea|chai|coffee|espresso|cappuccino|latte|hot\s*chocolate|kahwa|americano)\b').hasMatch(name)) {
    return 'Hot Beverages';
  }
  // Ice Cream
  if (RegExp(r'\b(ice\s*cream|sundae|scoop|kulfi)\b').hasMatch(name)) {
    return 'Ice Cream';
  }
  // Cakes & Bakery
  if (RegExp(r'\b(pastry|cake|muffin|cupcake|croissant|donut|doughnut)\b').hasMatch(name)) {
    return 'Cakes & Bakery';
  }
  // Desserts
  if (RegExp(r'\b(gulab\s*jamun|rasmalai|rasgulla|halwa|kheer|jalebi|brownie|mousse|pudding|sweet)\b').hasMatch(name)) {
    return 'Desserts';
  }
  // Soups
  if (RegExp(r'\b(soup|shorba|broth)\b').hasMatch(name)) {
    return 'Soups';
  }
  // Biryani
  if (RegExp(r'\b(biryani)\b').hasMatch(name)) {
    return 'Biryani';
  }
  // Pulao
  if (RegExp(r'\b(pulao|pilaf)\b').hasMatch(name)) {
    return 'Pulao';
  }
  // Rice
  if (RegExp(r'\b(rice|jeera\s*rice|steamed\s*rice|fried\s*rice)\b').hasMatch(name)) {
    if (name.contains('fried')) return 'Chinese Main Course';
    return 'Rice';
  }
  // Paneer Special
  if (RegExp(r'\b(paneer)\b').hasMatch(name)) {
    if (name.contains('tikka') || name.contains('chilli')) return 'Veg Starters';
    if (name.contains('pizza')) return 'Italian';
    if (name.contains('burger')) return 'Fast Food';
    if (name.contains('roll') || name.contains('wrap')) return 'Rolls & Wraps';
    return 'Paneer Special';
  }
  // Dal Special
  if (RegExp(r'\b(dal|makhani|tadka|sambar)\b').hasMatch(name)) {
    return 'Dal Special';
  }
  // Indian Breads
  if (RegExp(r'\b(roti|naan|paratha|kulcha|puri|chapati|phulka|rumali)\b').hasMatch(name)) {
    return 'Indian Breads';
  }
  // South Indian
  if (RegExp(r'\b(dosa|idli|vada|uttapam|appam|pongal)\b').hasMatch(name)) {
    return 'South Indian';
  }
  // Italian
  if (RegExp(r'\b(pizza|pasta|lasagna|lasagne|mac\s*and\s*cheese|bruschetta|garlic\s*bread|spaghetti|penne)\b').hasMatch(name)) {
    return 'Italian';
  }
  // Fast Food
  if (RegExp(r'\b(burger|fries|french\s*fries|sandwich|nuggets|nachos|wedges)\b').hasMatch(name)) {
    return 'Fast Food';
  }
  // Street Food / Chaat
  if (RegExp(r'\b(chaat|pani\s*puri|golgappa|sev\s*puri|bhel|papdi|bhelpuri|tikki)\b').hasMatch(name)) {
    return 'Street Food / Chaat';
  }
  // Rolls & Wraps
  if (RegExp(r'\b(roll|wrap|kathi|frankie)\b').hasMatch(name)) {
    return 'Rolls & Wraps';
  }
  // Thali / Combos
  if (RegExp(r'\b(thali|combo|platter|meal)\b').hasMatch(name)) {
    return 'Thali / Combos';
  }
  // Salads
  if (RegExp(r'\b(salad|kachumber)\b').hasMatch(name)) {
    return 'Salads';
  }
  // Raita & Curd
  if (RegExp(r'\b(raita|curd|dahi|tzatziki)\b').hasMatch(name)) {
    return 'Raita & Curd';
  }
  // Papad & Accompaniments
  if (RegExp(r'\b(papad|chutney|pickle|achar)\b').hasMatch(name)) {
    return 'Papad & Accompaniments';
  }
  // Seafood
  if (RegExp(r'\b(fish|prawn|crab|lobster|squid|seafood|surmai|pomfret)\b').hasMatch(name)) {
    return 'Seafood';
  }
  // Non-Veg Starters & Main Course
  if (RegExp(r'\b(chicken|mutton|egg|keema|lamb|meat|tandoori\s*chicken|lollipop|seekh)\b').hasMatch(name)) {
    if (RegExp(r'\b(tikka|kebab|65|lollipop|dry|chilli|fry|starter|wings)\b').hasMatch(name)) {
      return 'Non-Veg Starters';
    }
    return 'Non-Veg Main Course';
  }
  // Chinese
  if (RegExp(r'\b(manchurian|noodles|hakka|chowmein|schezwan|spring\s*roll|dimsum|momos)\b').hasMatch(name)) {
    if (name.contains('noodles') || name.contains('gravy') || name.contains('rice')) return 'Chinese Main Course';
    return 'Chinese Starters';
  }
  // Snacks / Breakfast
  if (RegExp(r'\b(samosa|kachori|pakora|bhajia|cutlet|poha|upma)\b').hasMatch(name)) {
    return 'Snacks';
  }
  return null;
}

bool detectMenuIsVeg(String rawName) {
  final name = rawName.trim().toLowerCase();
  return !RegExp(r'\b(chicken|mutton|egg|fish|prawn|crab|lobster|squid|meat|keema|lamb|pork|beef|bacon|seafood|non-veg|nonveg)\b').hasMatch(name);
}

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
  int _page = 0;
  int _pageSize = 24;

  ApiClient get _api => ref.read(apiProvider);
  bool get _isOwner => (ref.read(authProvider) as SignedIn).roles.contains('owner');
  bool get _canEdit {
    final a = ref.read(authProvider);
    return a is SignedIn && a.can('menu.publish');
  }

  String get _restaurantPrefix {
    final a = ref.read(authProvider);
    if (a is SignedIn) {
      final name = a.restaurantName ?? ref.read(restaurantLookProvider).valueOrNull?.name;
      return restaurantShortPrefix(name: name, fallbackCode: a.restaurantCode);
    }
    return 'RST-';
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
      barrierDismissible: false,
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

  /// Puts the categories in the order a meal is served (soups → starters → mains → breads → rice → desserts →
  /// drinks); categories of the same course keep their current order. The POS follows the saved order.
  Future<void> _arrangeByCourse() async {
    final ids = sortByCourse(_cats!, (c) => '${c['name']}').map((c) => c['id'] as String).toList();
    await _run(() => _api.orderCategories(ids), 'Menu arranged by course');
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

  Future<void> _seedCategories() async {
    if (!await confirm(context, title: 'Seed 40 standard categories?', message: 'This adds the full catalog of professional restaurant categories (Soups, Starters, Main Course, Biryani, Breads, Desserts, Beverages, etc.) to your menu.')) return;
    await _run(() async {
      final r = await _api.seedCategories();
      final created = r['created'] ?? 0;
      if (mounted) showDone(context, 'Added $created standard categories');
    });
  }

  Future<void> _quickAdd() async {
    await _ensureTax();
    if (!mounted) return;
    final defaultCat = _cats!.where((c) => c['id'] == _cat).firstOrNull?['name'] as String? ?? 'Main course';
    final category = TextEditingController(text: defaultCat);
    final rows = TextEditingController();
    String? error;
    bool busy = false;
    final saved = await showDialog<bool>(barrierDismissible: false, context: context, builder: (d) => StatefulBuilder(builder: (d, update) => HPDialog(
      title: 'Quick menu entry',
      actions: [
        SecondaryButton(label: 'Cancel', onPressed: busy ? null : () => Navigator.pop(d)),
        PrimaryButton(label: 'Create dishes', busy: busy, onPressed: busy ? null : () async {
          final items = <Json>[];
          for (final line in rows.text.split('\n').where((l) => l.trim().isNotEmpty)) {
            final rawParts = line.trim().split(RegExp(r'\t|\s*\|\s*')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
            if (rawParts.isEmpty) continue;

            String dishName = rawParts[0];
            String? dishCat;
            bool isVeg = true;
            final variants = <Json>[];
            int? singlePrice;

            var parts = [...rawParts];
            final matchCat = standardMenuCategories.firstWhere((sc) => sc.toLowerCase() == parts[0].toLowerCase(), orElse: () => '');
            if (matchCat.isNotEmpty && parts.length >= 3) {
              dishCat = matchCat;
              parts.removeAt(0);
              dishName = parts[0];
            }

            final vegIdx = parts.indexWhere((p) => RegExp(r'^(veg|vegetarian|non-?veg|non-vegetarian|egg)$', caseSensitive: false).hasMatch(p));
            if (vegIdx >= 0) {
              isVeg = !parts[vegIdx].toLowerCase().contains('non');
              parts.removeAt(vegIdx);
            }

            final valParts = parts.length > 1 ? parts.sublist(1) : <String>[];
            if (valParts.length == 1) {
              singlePrice = parseRupees(valParts[0]);
            } else if (valParts.length == 2 && parseRupees(valParts[0]) != null && parseRupees(valParts[1]) != null) {
              variants.add({'name': 'Half Plate', 'pricePaise': parseRupees(valParts[0])!, 'portionLabel': 'half', 'portionRatio': 0.5, 'isDefault': false});
              variants.add({'name': 'Full Plate', 'pricePaise': parseRupees(valParts[1])!, 'portionLabel': 'full', 'portionRatio': 1.0, 'isDefault': true});
            } else if (valParts.isNotEmpty) {
              for (final vp in valParts) {
                final subMatch = RegExp(r'^(.*?)\s*[:=]?\s*(\d+(?:\.\d+)?)$').firstMatch(vp);
                if (subMatch != null) {
                  final vName = subMatch.group(1)?.trim() ?? 'Regular';
                  final vPrice = parseRupees(subMatch.group(2)!);
                  if (vPrice != null) {
                    variants.add({'name': vName.isEmpty ? 'Regular' : vName, 'pricePaise': vPrice, 'isDefault': variants.isEmpty});
                  }
                } else {
                  final p = parseRupees(vp);
                  if (p != null) {
                    variants.add({'name': 'Size ${variants.length + 1}', 'pricePaise': p, 'isDefault': variants.isEmpty});
                  }
                }
              }
            }

            if (variants.isEmpty && singlePrice == null) {
              update(() => error = 'Could not parse price in: "$line".\nUse: Name | Price or Name | Veg/Non-Veg | HalfPrice | FullPrice');
              return;
            }

            items.add({
              'name': dishName,
              if (dishCat != null) 'categoryName': dishCat,
              'isVeg': isVeg,
              if (singlePrice != null && variants.isEmpty) 'pricePaise': singlePrice,
              if (variants.isNotEmpty) 'variants': variants,
            });
          }

          if (items.isEmpty || items.length > 200 || (category.text.trim().isEmpty && !items.any((i) => i.containsKey('categoryName')))) {
            update(() => error = 'Enter a category and 1–200 dishes.');
            return;
          }
          update(() { busy = true; error = null; });
          try {
            await _api.quickMenu({'categoryName': category.text.trim().isEmpty ? 'Main course' : category.text.trim(), 'taxRuleId': _taxes!.first['id'], 'items': items});
            if (d.mounted) Navigator.pop(d, true);
          } catch (e) {
            if (d.mounted) update(() { busy = false; error = '$e'; });
          }
        }),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: category, decoration: const InputDecoration(labelText: 'Default category (created automatically if new)')),
        const SizedBox(height: 8),
        Text('QUICK CATEGORY SUGGESTIONS', style: HPType.overline(context.hp.muted)),
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final c in ['Soups', 'Veg Starters', 'Non-Veg Starters', 'Tandoori Items', 'Veg Main Course', 'Biryani', 'Indian Breads', 'Desserts', 'Hot Beverages', 'Cold Beverages'])
            ActionChip(
              visualDensity: VisualDensity.compact,
              label: Text(c, style: const TextStyle(fontSize: 12)),
              onPressed: () => update(() => category.text = c),
            ),
        ]),
        const SizedBox(height: 16),
        TextField(
          controller: rows,
          minLines: 6,
          maxLines: 12,
          decoration: const InputDecoration(
            labelText: 'Paste names and prices from Excel, or type',
            hintText: 'Tomato Soup | Veg | 145 | 210\nPaneer Tikka | Veg | 240\nChicken Biryani | Non-Veg | Half 180 | Full 320\nButter Naan | 50',
          ),
        ),
        const SizedBox(height: 8),
        Text('Supports copying columns from Excel or typing. Single price creates Regular; 2 prices create Half & Full plate. Optional Veg/Non-Veg tag supported.', style: HPType.body(context.hp.muted).copyWith(fontSize: 12)),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: d.hp.danger))),
      ]),
    )));
    category.dispose(); rows.dispose();
    if (saved == true) { await _load(); if (mounted) showDone(context, 'Menu created'); }
  }

  Future<void> _editItem([Json? item]) async {
    try {
      await _ensureTax();
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    final defaultCat = _cat ?? (_cats!.isNotEmpty ? _cats!.first['id'] as String : 'standard:Main Course');
    final saved = await showDialog<bool>(
      barrierDismissible: false,
      context: context,
      builder: (_) => _ItemEditor(
        api: _api, item: item, categories: _cats!, taxes: _taxes!, defaultCategory: defaultCat, paletteIndex: _items!.length,
        restaurantPrefix: _restaurantPrefix,
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
    // "All dishes" lists dishes category by category, in the saved category (course) order
    final catPos = {for (final (i, c) in _cats!.indexed) c['id']: i};
    final visible = _items!
        .where((i) => _cat == null || i['categoryId'] == _cat)
        .where((i) => _q.isEmpty || '${i['name']} ${i['code'] ?? ''}'.toLowerCase().contains(_q.toLowerCase()))
        .toList();
    mergeSort(visible, compare: (a, b) => (catPos[a['categoryId']] ?? 1 << 20).compareTo(catPos[b['categoryId']] ?? 1 << 20));
    final catName = {for (final c in _cats!) c['id']: c['name']};

    final totalItems = visible.length;
    final totalPages = _pageSize > 0 ? (totalItems / _pageSize).ceil().clamp(1, 999999) : 1;
    final currentPage = _page.clamp(0, totalPages - 1);
    final paged = _pageSize > 0 ? visible.skip(currentPage * _pageSize).take(_pageSize).toList() : visible;

    final categoryRail = _CategoryList(
      cats: _cats!,
      items: _items!,
      selected: _cat,
      canEdit: edit,
      horizontal: narrow,
      onSelect: (id) => setState(() {
        _cat = id;
        _page = 0;
      }),
      onAdd: _editCategory,
      onRename: _editCategory,
      onDelete: _deleteCategory,
      onMove: _moveCategory,
      onArrange: _cats!.length > 1 ? _arrangeByCourse : null,
      onToggle: (c) => _run(() => _api.updateCategory(c['id'] as String, {'active': c['active'] == false}),
          c['active'] == false ? '${c['name']} is back on the POS' : '${c['name']} hidden from the POS'),
    );

    final topPagination = _MenuPaginationBar(
      totalItems: totalItems,
      page: currentPage,
      pageSize: _pageSize,
      compact: true,
      onPageChanged: (newPage) => setState(() => _page = newPage),
      onPageSizeChanged: (newSize) => setState(() {
        _pageSize = newSize;
        _page = 0;
      }),
    );

    final bottomPagination = _MenuPaginationBar(
      totalItems: totalItems,
      page: currentPage,
      pageSize: _pageSize,
      compact: false,
      onPageChanged: (newPage) => setState(() => _page = newPage),
      onPageSizeChanged: (newSize) => setState(() {
        _pageSize = newSize;
        _page = 0;
      }),
    );

    final grid = visible.isEmpty
        ? EmptyState(
            icon: Icons.restaurant_menu_rounded,
            title: _items!.isEmpty ? 'Your menu is empty' : 'No dishes match',
            message: _items!.isEmpty ? 'Add categories and dishes. Photos are optional — every dish gets an illustrated plate.' : null,
            action: edit && _items!.isEmpty ? PrimaryButton(label: 'Add your first dish', icon: Icons.add_rounded, onPressed: () => _editItem()) : null,
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              topPagination,
              const SizedBox(height: HPSpace.md),
              LayoutBuilder(builder: (c, box) {
                final cols = (box.maxWidth / 300).floor().clamp(1, 4);
                const gap = HPSpace.md;
                final w = (box.maxWidth - gap * (cols - 1)) / cols;
                return Wrap(spacing: gap, runSpacing: gap, children: [
                  for (final i in paged)
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
              }),
              const SizedBox(height: HPSpace.md),
              bottomPagination,
            ],
          );

    return PageFrame(
      title: 'Menu',
      subtitle: '${_items!.length} dishes · ${_cats!.length} categories · changes reach your terminals within a minute',
      actions: [
        SizedBox(
          width: narrow ? double.infinity : 260,
          child: HPSearchField(
            hint: 'Search dishes',
            onChanged: (v) => setState(() {
              _q = v;
              _page = 0;
            }),
          ),
        ),
        if (edit && (_can('import.run') || _isOwner))
          SecondaryButton(key: const Key('import-menu'), label: 'Import Excel', icon: _can('import.run') ? Icons.upload_file_rounded : Icons.lock_outline_rounded, onPressed: () async {
            if (!_can('import.run')) {
              showError(context, 'Excel import is not in your plan. Ask the Super Admin to enable "Excel import (menu & inventory)" in Plans, then sign in again.');
              return;
            }
            final done = await showDialog<bool>(barrierDismissible: false, context: context, builder: (_) => ImportDialog(api: _api, kind: 'menu'));
            if (done == true) await _load();
          }),
        if (edit) ...[
          SecondaryButton(label: 'Seed 40 categories', icon: Icons.playlist_add_check_rounded, onPressed: _seedCategories),
          SecondaryButton(label: 'Quick add / paste', onPressed: _quickAdd),
        ],
        PrimaryButton(key: const Key('add-dish'), label: 'Add dish', icon: Icons.add_rounded, height: 48, onPressed: () => _editItem()),
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

class _MenuPaginationBar extends StatelessWidget {
  const _MenuPaginationBar({
    required this.totalItems,
    required this.page,
    required this.pageSize,
    required this.onPageChanged,
    required this.onPageSizeChanged,
    this.compact = false,
  });

  final int totalItems;
  final int page;
  final int pageSize;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<int> onPageSizeChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final totalPages = pageSize > 0 ? (totalItems / pageSize).ceil().clamp(1, 999999) : 1;
    final currentPage = page.clamp(0, totalPages - 1);
    final start = totalItems == 0 ? 0 : currentPage * pageSize + 1;
    final end = pageSize > 0 ? (currentPage * pageSize + pageSize).clamp(0, totalItems) : totalItems;

    final pageButtons = <int>[];
    if (totalPages <= 7) {
      pageButtons.addAll(List.generate(totalPages, (i) => i));
    } else {
      final startPage = (currentPage - 2).clamp(0, totalPages - 5);
      final endPage = (startPage + 4).clamp(4, totalPages - 1);
      for (var i = startPage; i <= endPage; i++) {
        pageButtons.add(i);
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: HPSpace.md, vertical: 8),
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line.withValues(alpha: 0.5)),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: HPSpace.sm,
        spacing: HPSpace.md,
        children: [
          Text(
            totalItems == 0
                ? '0 dishes'
                : 'Showing $start–$end of $totalItems ${totalItems == 1 ? 'dish' : 'dishes'}',
            style: HPType.label(p.text).copyWith(fontSize: 13),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Per page:', style: HPType.body(p.muted).copyWith(fontSize: 12)),
                  const SizedBox(width: 6),
                  DropdownButton<int>(
                    key: Key(compact ? 'page-size-top' : 'page-size-bottom'),
                    value: pageSize,
                    underline: const SizedBox.shrink(),
                    isDense: true,
                    style: HPType.label(p.text).copyWith(fontSize: 13),
                    items: const [
                      DropdownMenuItem(value: 24, child: Text('24')),
                      DropdownMenuItem(value: 48, child: Text('48')),
                      DropdownMenuItem(value: 96, child: Text('96')),
                      DropdownMenuItem(value: 0, child: Text('All')),
                    ],
                    onChanged: (v) {
                      if (v != null) onPageSizeChanged(v);
                    },
                  ),
                ],
              ),
              const SizedBox(width: HPSpace.md),
              if (totalPages > 1) ...[
                IconButton(
                  key: Key(compact ? 'page-first-top' : 'page-first-bottom'),
                  icon: const Icon(Icons.first_page_rounded, size: 20),
                  tooltip: 'First page',
                  visualDensity: VisualDensity.compact,
                  onPressed: currentPage > 0 ? () => onPageChanged(0) : null,
                ),
                IconButton(
                  key: Key(compact ? 'page-prev-top' : 'page-prev-bottom'),
                  icon: const Icon(Icons.chevron_left_rounded, size: 20),
                  tooltip: 'Previous page',
                  visualDensity: VisualDensity.compact,
                  onPressed: currentPage > 0 ? () => onPageChanged(currentPage - 1) : null,
                ),
                if (!compact) ...[
                  if (pageButtons.isNotEmpty && pageButtons.first > 0) ...[
                    _pagePill(context, 0, false, p),
                    if (pageButtons.first > 1)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text('…', style: TextStyle(color: p.muted, fontSize: 13)),
                      ),
                  ],
                  for (final pNum in pageButtons)
                    _pagePill(context, pNum, pNum == currentPage, p),
                  if (pageButtons.isNotEmpty && pageButtons.last < totalPages - 1) ...[
                    if (pageButtons.last < totalPages - 2)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text('…', style: TextStyle(color: p.muted, fontSize: 13)),
                      ),
                    _pagePill(context, totalPages - 1, false, p),
                  ],
                ] else ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '${currentPage + 1} / $totalPages',
                      style: HPType.label(p.text).copyWith(fontSize: 13),
                    ),
                  ),
                ],
                IconButton(
                  key: Key(compact ? 'page-next-top' : 'page-next-bottom'),
                  icon: const Icon(Icons.chevron_right_rounded, size: 20),
                  tooltip: 'Next page',
                  visualDensity: VisualDensity.compact,
                  onPressed: currentPage < totalPages - 1 ? () => onPageChanged(currentPage + 1) : null,
                ),
                IconButton(
                  key: Key(compact ? 'page-last-top' : 'page-last-bottom'),
                  icon: const Icon(Icons.last_page_rounded, size: 20),
                  tooltip: 'Last page',
                  visualDensity: VisualDensity.compact,
                  onPressed: currentPage < totalPages - 1 ? () => onPageChanged(totalPages - 1) : null,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _pagePill(BuildContext context, int pageIndex, bool isCurrent, dynamic p) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        key: Key('page-pill-${pageIndex + 1}'),
        borderRadius: BorderRadius.circular(6),
        onTap: isCurrent ? null : () => onPageChanged(pageIndex),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isCurrent ? p.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: isCurrent ? p.accent : p.line.withValues(alpha: 0.5)),
          ),
          child: Text(
            '${pageIndex + 1}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent ? Colors.white : p.text,
            ),
          ),
        ),
      ),
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
    this.onArrange,
  });
  final List<Json> cats, items;
  final String? selected;
  final bool canEdit, horizontal;
  final ValueChanged<String?> onSelect;
  final VoidCallback onAdd;
  final ValueChanged<Json> onRename, onDelete, onToggle;
  final void Function(Json c, int by) onMove;
  final VoidCallback? onArrange;

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
          if (canEdit && onArrange != null)
            Padding(
              padding: const EdgeInsets.only(left: HPSpace.sm),
              child: ActionChip(key: const Key('arrange-by-course'), avatar: const Icon(Icons.sort_rounded, size: 18), label: const Text('Arrange by course'), onPressed: onArrange),
            ),
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
            if (onArrange != null)
              TextButton.icon(key: const Key('arrange-by-course'), onPressed: onArrange, icon: const Icon(Icons.sort_rounded), label: const Text('Arrange by course')),
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
    final code = '${item['code'] ?? ''}'.trim();
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
                Row(children: [
                  Expanded(child: Text(category, style: HPType.body(p.muted).copyWith(fontSize: 12), overflow: TextOverflow.ellipsis)),
                  if (code.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Click to copy SKU: $code',
                      child: InkWell(
                        key: Key('copy-sku-$code'),
                        borderRadius: BorderRadius.circular(4),
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: code));
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied SKU $code to clipboard'), duration: const Duration(milliseconds: 1500)));
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(4), border: Border.all(color: p.faint.withValues(alpha: .4))),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(code, style: HPType.mono(p.muted).copyWith(fontSize: 11, fontWeight: FontWeight.w600)),
                            const SizedBox(width: 4),
                            Icon(Icons.copy_rounded, size: 11, color: p.muted),
                          ]),
                        ),
                      ),
                    ),
                  ],
                ]),
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
                  onSelected: (v) {
                    if (v == 'edit') {
                      onEdit();
                    } else if (v == 'copy_sku' && code.isNotEmpty) {
                      Clipboard.setData(ClipboardData(text: code));
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied SKU $code to clipboard'), duration: const Duration(milliseconds: 1500)));
                    } else if (v == 'delete') {
                      onDelete();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit & photo')),
                    if (code.isNotEmpty) const PopupMenuItem(value: 'copy_sku', child: Text('Copy SKU / Code')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
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
  const _ItemEditor({
    required this.api,
    required this.item,
    required this.categories,
    required this.taxes,
    required this.defaultCategory,
    required this.paletteIndex,
    this.restaurantPrefix = '',
    this.canMapRecipes = false,
  });
  final ApiClient api;
  final bool canMapRecipes;
  final Json? item;
  final List<Json> categories, taxes;
  final String defaultCategory;
  final int paletteIndex;
  final String restaurantPrefix;
  @override
  State<_ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<_ItemEditor> {
  late final _name = TextEditingController(text: widget.item?['name'] as String? ?? '');
  late final _code = TextEditingController(text: widget.item?['code'] as String? ?? '');
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
  String? _detectedCategory;
  bool _userChangedCategory = false;

  @override
  void initState() {
    super.initState();
    // Do not pre-fill code with long prefix that truncates; keep clean hint text instead
  }

  void _onNameChanged(String val) {
    final detected = detectMenuCategory(val);
    final isVeg = detectMenuIsVeg(val);
    setState(() {
      _detectedCategory = detected;
      _veg = isVeg;
      if (!_userChangedCategory && detected != null) {
        final match = widget.categories.cast<Json?>().firstWhere(
          (c) => (c?['name'] as String?)?.trim().toLowerCase() == detected.trim().toLowerCase(),
          orElse: () => null,
        );
        if (match != null) {
          _category = match['id'] as String;
        } else if (widget.categories.length > 1 || widget.categories.isEmpty) {
          _category = 'standard:$detected';
        }
      }
    });
  }

  void _selectCategoryByName(String catName, {bool userInitiated = true}) {
    if (userInitiated) _userChangedCategory = true;
    final match = widget.categories.cast<Json?>().firstWhere(
      (c) => (c?['name'] as String?)?.trim().toLowerCase() == catName.trim().toLowerCase(),
      orElse: () => null,
    );
    setState(() {
      if (match != null) {
        _category = match['id'] as String;
      } else {
        _category = 'standard:$catName';
      }
    });
  }

  bool _isCategorySelected(String catName) {
    if (_category.startsWith('standard:')) {
      return _category.substring('standard:'.length).toLowerCase() == catName.toLowerCase();
    }
    final current = widget.categories.cast<Json?>().firstWhere(
      (c) => c?['id'] == _category,
      orElse: () => null,
    );
    return (current?['name'] as String?)?.toLowerCase() == catName.toLowerCase();
  }

  List<DropdownMenuItem<String>> _buildCategoryDropdownItems() {
    final items = <DropdownMenuItem<String>>[];
    final seen = <String>{};

    for (final c in widget.categories) {
      final name = (c['name'] as String?)?.trim() ?? '';
      final id = c['id'] as String;
      if (name.isNotEmpty && !seen.contains(name.toLowerCase())) {
        seen.add(name.toLowerCase());
        items.add(DropdownMenuItem(value: id, child: Text(name, overflow: TextOverflow.ellipsis)));
      }
    }

    for (final std in standardMenuCategories) {
      if (!seen.contains(std.toLowerCase())) {
        seen.add(std.toLowerCase());
        items.add(DropdownMenuItem(
          value: 'standard:$std',
          child: Row(
            children: [
              Expanded(child: Text(std, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(color: HPColors.cardamom.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
                child: const Text('Excel Standard', style: TextStyle(fontSize: 10, color: HPColors.cardamom, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ));
      }
    }

    if (!items.any((item) => item.value == _category)) {
      items.insert(0, DropdownMenuItem(value: _category, child: Text(_category.replaceFirst('standard:', ''))));
    }
    return items;
  }

  String _deriveCode() {
    final raw = _name.text.trim();
    final pfx = widget.restaurantPrefix.isNotEmpty ? widget.restaurantPrefix : 'DISH-';
    if (raw.isEmpty) return '${pfx}001';
    final words = raw
        .split(RegExp(r'\s+'))
        .map((w) => w.replaceAll(RegExp(r'[^A-Za-z0-9]'), ''))
        .where((w) => w.isNotEmpty)
        .toList();
    String sfx;
    if (words.length == 1) {
      final w = words.first.toUpperCase();
      sfx = w.length <= 8 ? w : w.substring(0, 6);
    } else {
      final initials = words.map((w) => w[0].toUpperCase()).join();
      if (initials.length >= 2 && initials.length <= 4) {
        sfx = '${initials}01';
      } else {
        final w = words.first.toUpperCase();
        sfx = w.length <= 5 ? w : w.substring(0, 5);
      }
    }
    return '$pfx$sfx';
  }

  void _autoGenerateCode() {
    setState(() => _code.text = _deriveCode());
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
      if (_category.startsWith('standard:')) {
        final stdName = _category.substring('standard:'.length);
        final created = await widget.api.createCategory(stdName, sortOrder: widget.categories.length * 10);
        _category = created['id'] as String;
      }
      final variants = [for (final s in _sizes) s.toJson()];
      String? itemCode = _code.text.trim().isNotEmpty ? _code.text.trim().toUpperCase() : null;
      if (itemCode == null && widget.item == null && _name.text.trim().isNotEmpty) {
        itemCode = _deriveCode();
      }
      final body = {
        'name': _name.text.trim(),
        'categoryId': _category,
        'taxRuleId': _tax,
        'isVeg': _veg,
        'available': _available,
        if (itemCode != null && itemCode.isNotEmpty) 'code': itemCode,
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
    final isMobile = MediaQuery.sizeOf(context).width < 600;

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
        const SizedBox(height: HPSpace.md),

        // Row 1: Dish name & SKU / Code
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                key: const Key('dish-name'),
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Dish name',
                  hintText: 'e.g. Coke, Butter Chicken, Cold Coffee, Paneer Tikka',
                  suffixIcon: _detectedCategory != null
                      ? Tooltip(
                          message: 'Auto-detected category: $_detectedCategory',
                          child: const Icon(Icons.auto_awesome_rounded, color: HPColors.cardamom, size: 18),
                        )
                      : null,
                ),
                onChanged: _onNameChanged,
              ),
            ),
            const SizedBox(width: HPSpace.md),
            Expanded(
              flex: 2,
              child: TextField(
                key: const Key('dish-code'),
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: 'SKU / Code',
                  hintText: widget.restaurantPrefix.isNotEmpty
                      ? (_name.text.trim().isNotEmpty
                          ? 'e.g. ${widget.restaurantPrefix}${_name.text.trim().split(RegExp(r'\s+')).first.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '')}'
                          : 'e.g. ${widget.restaurantPrefix}001')
                      : 'e.g. RST-001',
                  suffixIcon: Tooltip(
                    message: 'Auto-generate SKU',
                    child: IconButton(
                      icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                      onPressed: _autoGenerateCode,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: HPSpace.sm),

        // Quick Category Suggestions / Popular Chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final cat in popularExcelCategories)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(cat, style: TextStyle(fontSize: 11, fontWeight: _isCategorySelected(cat) ? FontWeight.bold : FontWeight.normal)),
                    backgroundColor: _isCategorySelected(cat) ? p.accent.withValues(alpha: 0.15) : null,
                    side: _isCategorySelected(cat) ? BorderSide(color: p.accent) : BorderSide(color: p.line.withValues(alpha: 0.5)),
                    onPressed: () => _selectCategoryByName(cat),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: HPSpace.sm),

        // Category & GST side-by-side on wide screens, stacked on mobile (without invalid vertical Expanded)
        if (isMobile) ...[
          DropdownButtonFormField<String>(
            value: _category,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Category',
              helperText: _detectedCategory != null ? 'Auto-detected: $_detectedCategory' : 'All 40 standard categories from Excel catalog',
              helperStyle: TextStyle(color: _detectedCategory != null ? p.success : p.muted, fontSize: 11),
            ),
            items: _buildCategoryDropdownItems(),
            onChanged: (v) {
              if (v != null) setState(() {
                _category = v;
                _userChangedCategory = true;
              });
            },
          ),
          const SizedBox(height: HPSpace.sm),
          DropdownButtonFormField<String>(
            initialValue: _tax,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'GST Rate', helperText: 'Split as CGST + SGST'),
            items: [for (final t in widget.taxes) DropdownMenuItem(value: t['id'] as String, child: Text('${t['name']}', overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => _tax = v!),
          ),
        ] else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  value: _category,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Category',
                    helperText: _detectedCategory != null ? 'Auto-detected: $_detectedCategory' : 'All 40 standard categories from Excel catalog',
                    helperStyle: TextStyle(color: _detectedCategory != null ? p.success : p.muted, fontSize: 11),
                  ),
                  items: _buildCategoryDropdownItems(),
                  onChanged: (v) {
                    if (v != null) setState(() {
                      _category = v;
                      _userChangedCategory = true;
                    });
                  },
                ),
              ),
              const SizedBox(width: HPSpace.md),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  initialValue: _tax,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'GST Rate', helperText: 'Split as CGST + SGST'),
                  items: [for (final t in widget.taxes) DropdownMenuItem(value: t['id'] as String, child: Text('${t['name']}', overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => setState(() => _tax = v!),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: HPSpace.lg),

        // Sizes & Pricing Header
        Row(children: [
          Expanded(child: Text('SIZES & PRICING', style: HPType.overline(p.muted))),
          TextButton.icon(
            key: const Key('add-size'),
            onPressed: _sizes.length >= 20 ? null : () => setState(() => _sizes.add(_SizeDraft.blank())),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add size'),
          ),
        ]),
        const SizedBox(height: 2),
        Text('For single items (e.g. 1 Coke), just type the price below. Click presets for multi-size portions.', style: HPType.body(p.muted).copyWith(fontSize: 12)),
        const SizedBox(height: HPSpace.sm),
        Wrap(spacing: 8, runSpacing: 6, children: [
          TextButton(onPressed: () => setState(() { _sizes.clear(); for (final quantity in [200, 300, 500, 1000]) { _sizes.add(_SizeDraft(name: '$quantity ml', qty: '$quantity', unit: 'ml', isDefault: quantity == 300)); } }), child: const Text('🥤 Drinks: 200 / 300 / 500 ml / 1 L')),
          TextButton(onPressed: () => setState(() { _sizes.clear(); for (final (name, ratio) in [('Half', .5), ('Full', 1.0)]) { _sizes.add(_SizeDraft(name: '$name plate', portion: name.toLowerCase(), ratio: '$ratio', qty: '$ratio', unit: 'plate', isDefault: ratio == 1)); } }), child: const Text('🍛 Half / Full Plate')),
          TextButton(onPressed: () => setState(() { _sizes.clear(); _sizes.add(_SizeDraft(name: 'Cup 150 ml', qty: '150', unit: 'ml', isDefault: false)); _sizes.add(_SizeDraft(name: 'Bowl 250 ml', qty: '250', unit: 'ml', isDefault: true)); }), child: const Text('🍵 Cup 150 ml / Bowl 250 ml')),
          TextButton(onPressed: () => setState(() { _sizes.clear(); for (final s in ['Small 7"', 'Medium 10"', 'Large 12"']) { _sizes.add(_SizeDraft(name: s, unit: 'piece', isDefault: s.startsWith('Medium'))); } }), child: const Text('🍕 Pizza: 7" / 10" / 12"')),
          TextButton(onPressed: () => setState(() { _sizes.clear(); for (final s in ['1 Scoop', '2 Scoops', '3 Scoops']) { _sizes.add(_SizeDraft(name: s, unit: 'scoop', isDefault: s.startsWith('1'))); } }), child: const Text('🍨 Ice cream: 1 / 2 / 3 scoops')),
          TextButton(onPressed: () => setState(() { _sizes.clear(); for (final p in ['1 Piece', '2 Pieces', '4 Pieces']) { _sizes.add(_SizeDraft(name: p, unit: 'piece', isDefault: p.startsWith('2'))); } }), child: const Text('Pieces: 1 / 2 / 4')),
          TextButton(onPressed: () => setState(() { _sizes.clear(); _sizes.add(_SizeDraft(name: '1 Thali / Combo', unit: 'combo', isDefault: true)); }), child: const Text('🍱 1 Thali / Combo')),
        ]),
        const SizedBox(height: HPSpace.sm),
        for (final (i, s) in _sizes.indexed)
          _SizeRow(
            key: ObjectKey(s),
            index: i,
            size: s,
            restaurantPrefix: widget.restaurantPrefix,
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
                ? () => showDialog<void>(barrierDismissible: false, context: context, builder: (_) => RecipeDialog(api: widget.api, variantId: s.id!, title: '${_name.text.trim()} · ${s.name.text.trim()}'))
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

/// Where a category sits in a meal: 0 soups, 1 starters & snacks, 2 mains (anything unrecognised), 3 breads,
/// 4 rice & biryani, 5 accompaniments, 6 desserts, 7 drinks. Checked in this order, so "Chinese Starters" is a
/// starter and "Cold Beverages" a drink.
int courseRank(String category) {
  final n = category.toLowerCase();
  bool any(List<String> words) => words.any(n.contains);
  if (any(['soup', 'shorba'])) return 0;
  if (any(['beverage', 'drink', 'juice', 'shake', 'smoothie', 'mocktail', 'cocktail', 'lassi', 'chaas', 'tea', 'coffee', 'water', 'soda', 'cooler'])) return 7;
  if (any(['dessert', 'sweet', 'ice cream', 'kulfi', 'cake', 'bakery', 'pastry', 'mithai'])) return 6;
  if (any(['raita', 'curd', 'papad', 'accompaniment', 'pickle', 'chutney'])) return 5;
  if (any(['rice', 'biryani', 'pulao', 'khichdi'])) return 4;
  if (any(['bread', 'naan', 'roti', 'paratha', 'kulcha'])) return 3;
  if (any(['starter', 'appetiser', 'appetizer', 'tandoor', 'kebab', 'snack', 'chaat', 'street', 'fast food', 'roll', 'wrap', 'salad', 'breakfast', 'momo'])) return 1;
  return 2;
}

/// Stable sort by [courseRank]: same-course categories keep their relative order.
List<T> sortByCourse<T>(List<T> cats, String Function(T) name) {
  final out = [...cats];
  mergeSort(out, compare: (a, b) => courseRank(name(a)).compareTo(courseRank(name(b))));
  return out;
}

const servingUnits = ['ml', 'l', 'g', 'kg', 'piece', 'plate', 'bowl', 'glass', 'cup', 'portion', 'bottle', 'can', 'packet'];
const portionLabels = ['half', 'full'];

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
  const _SizeRow({
    super.key,
    required this.index,
    required this.size,
    required this.canRemove,
    required this.onDefault,
    required this.onRemove,
    required this.onChanged,
    this.restaurantPrefix = '',
    this.onRecipe,
  });
  final int index;
  final _SizeDraft size;
  final bool canRemove;
  final String restaurantPrefix;
  final VoidCallback onDefault, onRemove, onChanged;
  final VoidCallback? onRecipe;

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    final volumeOrQtyLabel = (size.unit == 'ml' || size.unit == 'l')
        ? 'Volume'
        : (size.unit == 'g' || size.unit == 'kg' ? 'Weight' : 'Portion qty');

    return Card(
      margin: const EdgeInsets.only(bottom: HPSpace.sm),
      color: p.raised,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: size.isDefault ? p.accent.withValues(alpha: 0.5) : p.line.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(HPSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Row 1: Primary Inputs (Size name & Price)
            if (isMobile) ...[
              TextField(
                key: Key('size-name-$index'),
                controller: size.name,
                decoration: const InputDecoration(labelText: 'Size / portion', hintText: 'e.g. Regular, 300 ml, Half plate'),
                onChanged: (_) => onChanged(),
              ),
              const SizedBox(height: HPSpace.sm),
              TextField(
                key: Key('size-price-$index'),
                controller: size.price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Price', prefixText: '₹ '),
                onChanged: (_) => onChanged(),
              ),
            ] else ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      key: Key('size-name-$index'),
                      controller: size.name,
                      decoration: const InputDecoration(labelText: 'Size / portion', hintText: 'e.g. Regular, 300 ml, Half plate'),
                      onChanged: (_) => onChanged(),
                    ),
                  ),
                  const SizedBox(width: HPSpace.sm),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      key: Key('size-price-$index'),
                      controller: size.price,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Price', prefixText: '₹ '),
                      onChanged: (_) => onChanged(),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: HPSpace.sm),

            // Row 2: Secondary / Portion Measurements (Qty, Unit, Portion, Ratio, Code)
            Wrap(
              spacing: HPSpace.sm,
              runSpacing: HPSpace.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    key: Key('size-qty-$index'),
                    controller: size.qty,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: volumeOrQtyLabel,
                      hintText: (size.unit == 'ml' || size.unit == 'l') ? 'e.g. 200' : 'e.g. 1',
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                SizedBox(
                  width: 105,
                  child: DropdownButtonFormField<String?>(
                    key: Key('size-unit-$index'),
                    initialValue: size.unit,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Unit'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('—')),
                      for (final u in servingUnits) DropdownMenuItem<String?>(value: u, child: Text(u)),
                    ],
                    onChanged: (v) {
                      size.unit = v;
                      onChanged();
                    },
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: DropdownButtonFormField<String?>(
                    initialValue: size.portion,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Portion'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('—')),
                      // an older dish may carry a label no longer offered (e.g. quarter): keep it selectable
                      for (final l in {...portionLabels, if (size.portion != null) size.portion!}) DropdownMenuItem<String?>(value: l, child: Text(l.isEmpty ? '—' : '${l[0].toUpperCase()}${l.substring(1)}')),
                    ],
                    onChanged: (v) {
                      size.portion = v;
                      onChanged();
                    },
                  ),
                ),
                SizedBox(
                  width: 90,
                  child: Tooltip(
                    message: 'Default recipe scale vs the full portion (1 = full). Prices are never derived from it.',
                    child: TextField(
                      controller: size.ratio,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Ratio'),
                      onChanged: (_) => onChanged(),
                    ),
                  ),
                ),
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: size.code,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: 'Code (optional)',
                      hintText: restaurantPrefix.isNotEmpty ? 'e.g. ${restaurantPrefix}500' : 'e.g. COLA-500',
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: HPSpace.sm),

            // Row 3: Action Controls (Default, Available, Recipe, Remove)
            Wrap(
              spacing: HPSpace.md,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Radio<bool>(
                    key: Key('size-default-$index'),
                    value: true,
                    groupValue: size.isDefault,
                    onChanged: (_) => onDefault(), // ignore: deprecated_member_use
                  ),
                  Text('Default', style: HPType.body(p.text).copyWith(fontSize: 13)),
                ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Switch(
                    value: size.available,
                    onChanged: (v) {
                      size.available = v;
                      onChanged();
                    },
                  ),
                  Text(size.available ? 'In stock' : 'Sold out', style: HPType.body(p.text).copyWith(fontSize: 13)),
                ]),
                if (onRecipe != null)
                  TextButton.icon(
                    key: Key('size-recipe-$index'),
                    onPressed: onRecipe,
                    icon: const Icon(Icons.blender_outlined, size: 16),
                    label: const Text('Recipe', style: TextStyle(fontSize: 12)),
                  ),
                if (canRemove)
                  TextButton.icon(
                    key: Key('size-remove-$index'),
                    onPressed: onRemove,
                    icon: Icon(Icons.delete_outline_rounded, size: 16, color: p.danger),
                    label: Text('Remove', style: TextStyle(fontSize: 12, color: p.danger)),
                  ),
              ],
            ),
          ],
        ),
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
