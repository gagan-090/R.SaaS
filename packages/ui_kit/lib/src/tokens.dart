import 'package:flutter/material.dart';

/// Colour tokens from STYLE.md §3. Screens use these names, never raw hex.
abstract final class HPColors {
  // service (dark)
  static const espresso = Color(0xFF140D0C);
  static const kitchen = Color(0xFF0C0807);
  static const ember = Color(0xFF1F1615);
  static const emberRaised = Color(0xFF2A1E1C);
  static const clayLine = Color(0xFF3A2B28);
  static const outline = Color(0xFF4A3733);
  static const ghee = Color(0xFFF6EBDD);
  static const husk = Color(0xFFB8A595);
  static const smoke = Color(0xFF8F7D6E);
  static const saffron = Color(0xFFF0A93B);
  static const saffronTint = Color(0xFFF5C779);
  static const chili = Color(0xFFE2553E);
  static const cardamom = Color(0xFF7FB685);
  static const jamun = Color(0xFFB48BD6);
  // back office (light)
  static const wine = Color(0xFF6B1F2A);
  static const wineDeep = Color(0xFF3A1119);
  static const paper = Color(0xFFFBF6EC);
  static const paperCard = Color(0xFFFFFDF8);
  static const paperLine = Color(0xFFE4D8C2);
  static const ink = Color(0xFF2A211C);
  static const inkMuted = Color(0xFF6F6155);
  static const olive = Color(0xFF55663A);
  static const vegGreen = Color(0xFF4CAF50);
  // text on filled colours
  static const onSaffron = Color(0xFF1A0F0C);
  static const onCardamom = Color(0xFF10210F);
  static const onJamun = Color(0xFF1E1028);
  static const onChili = Color(0xFFFFF1EA);
}

/// 8-point spacing scale (STYLE.md §5).
abstract final class HPSpace {
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 20.0, x2 = 24.0, x3 = 28.0, x4 = 32.0, x5 = 40.0;
}

abstract final class HPRadius {
  static const key = 12.0, button = 16.0, card = 20.0, panel = 24.0, pill = 999.0;
}

/// Status tones. Status is always colour + a word or icon, never colour alone.
enum HPTone { neutral, saffron, success, danger, pending }

extension HPToneColors on HPTone {
  Color get color => switch (this) {
        HPTone.neutral => HPColors.husk,
        HPTone.saffron => HPColors.saffron,
        HPTone.success => HPColors.cardamom,
        HPTone.danger => HPColors.chili,
        HPTone.pending => HPColors.jamun,
      };
  Color get onColor => switch (this) {
        HPTone.neutral => HPColors.espresso,
        HPTone.saffron => HPColors.onSaffron,
        HPTone.success => HPColors.onCardamom,
        HPTone.danger => HPColors.onChili,
        HPTone.pending => HPColors.onJamun,
      };
  Color get tint => Color.lerp(color, Colors.white, .35)!;
}

/// Semantic colours for the current theme (STYLE.md §2–3). Screens read these through `context.hp` so the same
/// widget works in Midnight Masala (dark) and Daylight (light) and follows the device setting.
@immutable
class HPPalette extends ThemeExtension<HPPalette> {
  const HPPalette({
    required this.ground,
    required this.surface,
    required this.raised,
    required this.line,
    required this.outline,
    required this.text,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.onAccent,
    required this.accentInk,
    required this.success,
    required this.danger,
    required this.pending,
    required this.note,
    required this.brand,
    required this.onBrand,
    required this.sidebar,
    required this.isDark,
  });

  /// Page background.
  final Color ground;

  /// Cards, panels, inputs.
  final Color surface;

  /// Chips, keys, hover, selected rows.
  final Color raised;
  final Color line;
  final Color outline;
  final Color text;
  final Color muted;
  final Color faint;

  /// Saffron: fills (with [onAccent] text) — the one primary action per region.
  final Color accent;
  final Color onAccent;

  /// Accent used as text/icons on [ground]; darker on light so contrast stays ≥ 4.5:1.
  final Color accentInk;
  final Color success;
  final Color danger;
  final Color pending;

  /// Kitchen notes ("less spicy").
  final Color note;

  /// Back-office brand (wine) and the text on it.
  final Color brand;
  final Color onBrand;
  final Color sidebar;
  final bool isDark;

  /// Midnight Masala — service, dark.
  static const serviceDark = HPPalette(
    ground: HPColors.espresso, surface: HPColors.ember, raised: HPColors.emberRaised, line: HPColors.clayLine, outline: HPColors.outline,
    text: HPColors.ghee, muted: HPColors.husk, faint: HPColors.smoke, accent: HPColors.saffron, onAccent: HPColors.onSaffron,
    accentInk: HPColors.saffron, success: HPColors.cardamom, danger: HPColors.chili, pending: HPColors.jamun, note: HPColors.saffronTint,
    brand: HPColors.saffron, onBrand: HPColors.onSaffron, sidebar: HPColors.kitchen, isDark: true,
  );

  /// Daylight — service, light (same layout, paper ground; saffron stays the fill, text accents darken for contrast).
  static const serviceLight = HPPalette(
    ground: HPColors.paper, surface: HPColors.paperCard, raised: Color(0xFFF3EADB), line: HPColors.paperLine, outline: Color(0xFFCDBDA4),
    text: HPColors.ink, muted: HPColors.inkMuted, faint: Color(0xFF9A8B7C), accent: HPColors.saffron, onAccent: HPColors.onSaffron,
    accentInk: Color(0xFF9A5A00), success: Color(0xFF3E7D46), danger: Color(0xFFC2402B), pending: Color(0xFF7B52A8), note: Color(0xFF9A5A00),
    brand: HPColors.saffron, onBrand: HPColors.onSaffron, sidebar: Color(0xFFF3EADB), isDark: false,
  );

  /// Back office, light (wine brand).
  static const backOfficeLight = HPPalette(
    ground: HPColors.paper, surface: HPColors.paperCard, raised: Color(0xFFF3EADB), line: HPColors.paperLine, outline: Color(0xFFCDBDA4),
    text: HPColors.ink, muted: HPColors.inkMuted, faint: Color(0xFF9A8B7C), accent: HPColors.wine, onAccent: HPColors.paper,
    accentInk: HPColors.wine, success: Color(0xFF3E7D46), danger: Color(0xFFC2402B), pending: Color(0xFF7B52A8), note: Color(0xFF9A5A00),
    brand: HPColors.wine, onBrand: HPColors.paper, sidebar: HPColors.wineDeep, isDark: false,
  );

  /// Back office, dark (follows the device at night).
  static const backOfficeDark = HPPalette(
    ground: Color(0xFF120B0C), surface: Color(0xFF1C1314), raised: Color(0xFF281B1D), line: Color(0xFF3A2A2C), outline: Color(0xFF4D3A3D),
    text: HPColors.ghee, muted: HPColors.husk, faint: HPColors.smoke, accent: HPColors.saffron, onAccent: HPColors.onSaffron,
    accentInk: HPColors.saffron, success: HPColors.cardamom, danger: HPColors.chili, pending: HPColors.jamun, note: HPColors.saffronTint,
    brand: Color(0xFFD9707F), onBrand: Color(0xFF1E0A0E), sidebar: Color(0xFF0C0708), isDark: true,
  );

  /// Status colour for a tone in this palette (darker on light grounds).
  Color tone(HPTone t) => switch (t) {
        HPTone.neutral => muted,
        HPTone.saffron => isDark ? accent : accentInk,
        HPTone.success => success,
        HPTone.danger => danger,
        HPTone.pending => pending,
      };

  @override
  HPPalette copyWith({Color? ground, Color? surface, Color? accent}) => HPPalette(
        ground: ground ?? this.ground, surface: surface ?? this.surface, raised: raised, line: line, outline: outline, text: text, muted: muted,
        faint: faint, accent: accent ?? this.accent, onAccent: onAccent, accentInk: accentInk, success: success, danger: danger, pending: pending,
        note: note, brand: brand, onBrand: onBrand, sidebar: sidebar, isDark: isDark,
      );

  @override
  HPPalette lerp(HPPalette? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return HPPalette(
      ground: l(ground, other.ground), surface: l(surface, other.surface), raised: l(raised, other.raised), line: l(line, other.line),
      outline: l(outline, other.outline), text: l(text, other.text), muted: l(muted, other.muted), faint: l(faint, other.faint),
      accent: l(accent, other.accent), onAccent: l(onAccent, other.onAccent), accentInk: l(accentInk, other.accentInk),
      success: l(success, other.success), danger: l(danger, other.danger), pending: l(pending, other.pending), note: l(note, other.note),
      brand: l(brand, other.brand), onBrand: l(onBrand, other.onBrand), sidebar: l(sidebar, other.sidebar), isDark: t < .5 ? isDark : other.isDark,
    );
  }
}

extension HPContext on BuildContext {
  /// The House Plating palette of the current theme (dark service palette if a screen is built without HPTheme).
  HPPalette get hp => Theme.of(this).extension<HPPalette>() ?? HPPalette.serviceDark;
}
