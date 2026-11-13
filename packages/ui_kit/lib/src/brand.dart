import 'package:flutter/material.dart';

/// The BhojMitra logo (assets/brand/bhojmitra_logo.png, transparent, about 1.39 : 1).
/// Shown on every sign-in screen, sidebar and top bar of the POS and the console.
/// Its navy lettering is made for a light ground, so on a dark one it sits on a white plate.
class BhojMitraLogo extends StatelessWidget {
  const BhojMitraLogo({super.key, this.height = 56, this.plate});

  /// Height of the logo itself (the plate adds a little around it).
  final double height;

  /// White plate behind the logo; null = only when the theme is dark.
  final bool? plate;

  static const asset = 'assets/brand/bhojmitra_logo.png';
  static const package = 'rsaas_ui_kit';
  static const aspect = 1232 / 884;

  @override
  Widget build(BuildContext context) {
    final img = Image.asset(
      asset,
      package: package,
      height: height,
      width: height * aspect,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'BhojMitra',
      errorBuilder: (_, _, _) => SizedBox(height: height, width: height * aspect),
    );
    final onPlate = plate ?? Theme.of(context).brightness == Brightness.dark;
    if (!onPlate) return KeyedSubtree(key: const Key('bhojmitra-logo'), child: img);
    final pad = (height * .12).clamp(3.0, 12.0);
    return Container(
      key: const Key('bhojmitra-logo'),
      padding: EdgeInsets.all(pad),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular((height * .18).clamp(6.0, 16.0))),
      child: img,
    );
  }
}
