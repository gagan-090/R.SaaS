import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// Typography (STYLE.md §4): Fraunces for what people read at a glance, DM Sans for what they act on,
/// DM Mono for invoice numbers. Numbers use tabular figures.
abstract final class HPType {
  /// Widget tests and offline builds set this to false to avoid fetching fonts at runtime.
  static bool useGoogleFonts = true;

  static const tabular = [FontFeature.tabularFigures()];

  static TextStyle _f(String family, TextStyle s) {
    if (!useGoogleFonts) return s.copyWith(fontFamily: family);
    return switch (family) {
      'Fraunces' => GoogleFonts.fraunces(textStyle: s),
      'DM Mono' => GoogleFonts.dmMono(textStyle: s),
      _ => GoogleFonts.dmSans(textStyle: s),
    };
  }

  static TextStyle displayTotal([Color? c]) => _f('Fraunces', TextStyle(fontSize: 44, fontWeight: FontWeight.w700, letterSpacing: -1, color: c, fontFeatures: tabular));
  static TextStyle titleScreen([Color? c]) => _f('Fraunces', TextStyle(fontSize: 30, fontWeight: FontWeight.w600, letterSpacing: -.5, color: c));
  static TextStyle titleCard([Color? c]) => _f('Fraunces', TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: c));
  static TextStyle note([Color? c]) => _f('Fraunces', TextStyle(fontSize: 15, fontStyle: FontStyle.italic, fontWeight: FontWeight.w500, color: c ?? HPColors.saffronTint));
  static TextStyle label([Color? c]) => _f('DM Sans', TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c, fontFeatures: tabular));
  static TextStyle body([Color? c]) => _f('DM Sans', TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: c, fontFeatures: tabular));
  static TextStyle overline([Color? c]) => _f('DM Sans', TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 2, color: c));
  static TextStyle mono([Color? c]) => _f('DM Mono', TextStyle(fontSize: 13, color: c, fontFeatures: tabular));
}

/// Two themes, one system (STYLE.md §2).
abstract final class HPTheme {
  /// Service (dark): cashier POS, table map, payment, waiter, KDS, hub screen.
  static ThemeData service() => _build(
        brightness: Brightness.dark,
        ground: HPColors.espresso,
        surface: HPColors.ember,
        text: HPColors.ghee,
        muted: HPColors.husk,
        primary: HPColors.saffron,
        onPrimary: HPColors.onSaffron,
        line: HPColors.clayLine,
      );

  /// Back office (light): Super Admin portal, owner reports, web settings.
  static ThemeData backOffice() => _build(
        brightness: Brightness.light,
        ground: HPColors.paper,
        surface: HPColors.paperCard,
        text: HPColors.ink,
        muted: HPColors.inkMuted,
        primary: HPColors.wine,
        onPrimary: HPColors.paper,
        line: HPColors.paperLine,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color ground,
    required Color surface,
    required Color text,
    required Color muted,
    required Color primary,
    required Color onPrimary,
    required Color line,
  }) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: onPrimary,
      secondary: HPColors.saffron,
      onSecondary: HPColors.onSaffron,
      error: HPColors.chili,
      onError: HPColors.onChili,
      surface: surface,
      onSurface: text,
      outline: line,
      surfaceContainerHighest: brightness == Brightness.dark ? HPColors.emberRaised : HPColors.paper,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, scaffoldBackgroundColor: ground, brightness: brightness);
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineMedium: HPType.titleScreen(text),
        titleLarge: HPType.titleCard(text),
        titleMedium: HPType.label(text),
        bodyMedium: HPType.body(text),
        bodySmall: HPType.body(muted),
        labelLarge: HPType.label(text),
      ),
      dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
      cardTheme: CardThemeData(color: surface, elevation: 0, margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HPRadius.card), side: BorderSide(color: line))),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brightness == Brightness.dark ? HPColors.ember : HPColors.paperCard,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: line)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: line)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: primary, width: 2)),
        labelStyle: HPType.body(muted),
      ),
      dialogTheme: DialogThemeData(backgroundColor: surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HPRadius.panel))),
    );
  }
}
