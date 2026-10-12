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
