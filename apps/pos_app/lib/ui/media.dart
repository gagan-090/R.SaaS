import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';
import '../state/app_state.dart';

/// Photo bytes by image id, fetched once per app session from the hub (which caches them from the cloud).
final _photoCache = Provider<Map<String, Future<Uint8List?>>>((ref) {
  ref.watch(hubApiProvider); // a new hub pairing starts a fresh cache
  ref.watch(refreshTickProvider); // pull-down-to-refresh fetches photos again
  return {};
});

Color hexColor(Object? v, Color fallback) {
  final s = '${v ?? ''}'.replaceAll('#', '');
  return s.length == 6 ? Color(int.parse('FF$s', radix: 16)) : fallback;
}

/// The dish's photo (cropped into the plate) once it has loaded, the illustrated plate until then.
class MenuDishImage extends ConsumerWidget {
  const MenuDishImage({super.key, required this.item, this.size = 60});
  final Json item;
  final double size;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pc = item['plate_colors'] as Map?;
    Widget plate(ImageProvider? img) => DishImage(
          image: img,
          base: hexColor(pc?['base'], HPColors.saffron),
          sauce: hexColor(pc?['sauce'], HPColors.ghee),
          garnish: hexColor(pc?['garnish'], HPColors.cardamom),
          size: size,
        );
    final id = item['image_id'] as String?;
    final api = ref.watch(hubApiProvider);
    if (id == null || api == null) return plate(null);
    final f = ref.watch(_photoCache).putIfAbsent(id, () => api.media(id));
    return FutureBuilder<Uint8List?>(future: f, builder: (_, s) => plate(s.data == null ? null : MemoryImage(s.data!)));
  }
}

/// Menu card with the hub photo when there is one (STYLE.md DishCard).
class MenuDishCard extends ConsumerWidget {
  const MenuDishCard({super.key, required this.item, required this.qty, required this.enabled, required this.onTap});
  final Json item;
  final int qty;
  final bool enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pc = item['plate_colors'] as Map?;
    final id = item['image_id'] as String?;
    final api = ref.watch(hubApiProvider);
    Widget card(ImageProvider? img) => DishCard(
          name: '${item['name']}',
          price: formatPaise(item['price_paise'] as int).replaceAll('.00', ''),
          isVeg: item['is_veg'] == 1 || item['is_veg'] == true,
          base: hexColor(pc?['base'], HPColors.saffron),
          sauce: hexColor(pc?['sauce'], HPColors.ghee),
          garnish: hexColor(pc?['garnish'], HPColors.cardamom),
          image: img,
          qty: qty,
          available: item['available'] == 1 || item['available'] == true,
          onTap: enabled ? onTap : null,
        );
    if (id == null || api == null) return card(null);
    final f = ref.watch(_photoCache).putIfAbsent(id, () => api.media(id));
    return FutureBuilder<Uint8List?>(future: f, builder: (_, s) => card(s.data == null ? null : MemoryImage(s.data!)));
  }
}

/// The restaurant's logo (plan feature "branding"), served and cached by the hub; [fallback] when there is none.
class BrandLogo extends ConsumerWidget {
  const BrandLogo({super.key, required this.height, this.maxWidth = 160, this.fallback = const SizedBox.shrink()});
  final double height, maxWidth;
  final Widget fallback;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(posLookProvider).valueOrNull?.brand?.logoImageId;
    final api = ref.watch(hubApiProvider);
    if (id == null || api == null) return fallback;
    final f = ref.watch(_photoCache).putIfAbsent(id, () => api.media(id));
    return FutureBuilder<Uint8List?>(
      future: f,
      builder: (_, s) => s.data == null
          ? fallback
          : ConstrainedBox(
              constraints: BoxConstraints(maxHeight: height, maxWidth: maxWidth),
              child: Image.memory(s.data!, key: const Key('brand-logo'), fit: BoxFit.contain),
            ),
    );
  }
}
