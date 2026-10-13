import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'tokens.dart';

/// Typography: Arial everywhere — a plain, familiar face (no downloaded fonts, works offline).
/// Where Arial is not available (Flutter web cannot use the computer's fonts; Android does not ship Arial) the
/// bundled Liberation Sans takes over — it has Arial's exact letter widths. Numbers use tabular figures.
abstract final class HPType {
  /// Kept for compatibility (tests set it); fonts are system fonts now, nothing is fetched at runtime.
  static bool useGoogleFonts = false;

  static const family = 'Arial';
  static const fallback = ['packages/rsaas_ui_kit/LiberationSans', 'Helvetica Neue', 'Helvetica', 'Roboto', 'Segoe UI', 'sans-serif'];
  static const tabular = [FontFeature.tabularFigures()];

  /// Heading weight and case — House Plating bold, or the restaurant's choice ([HPBrand.activate]).
  static FontWeight headingWeight = FontWeight.w700;
  static bool headingUpper = false;

  /// A page or card title in the restaurant's heading case.
  static String heading(String s) => headingUpper ? s.toUpperCase() : s;

  static TextStyle _f(TextStyle s) => s.copyWith(fontFamily: family, fontFamilyFallback: fallback);

  static TextStyle displayTotal([Color? c]) => _f(TextStyle(fontSize: 40, fontWeight: headingWeight, letterSpacing: -.5, height: 1.15, color: c, fontFeatures: tabular));
  static TextStyle titleScreen([Color? c]) => _f(TextStyle(fontSize: 28, fontWeight: headingWeight, letterSpacing: headingUpper ? .6 : -.3, height: 1.2, color: c));
  static TextStyle titleCard([Color? c]) => _f(TextStyle(fontSize: 18, fontWeight: headingWeight, letterSpacing: headingUpper ? .4 : 0, height: 1.25, color: c));
  static TextStyle note([Color? c]) => _f(TextStyle(fontSize: 14, fontStyle: FontStyle.italic, fontWeight: FontWeight.w400, color: c ?? HPColors.saffronTint));
  static TextStyle label([Color? c]) => _f(TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c, fontFeatures: tabular));
  static TextStyle body([Color? c]) => _f(TextStyle(fontSize: 14, fontWeight: FontWeight.w400, height: 1.35, color: c, fontFeatures: tabular));
  static TextStyle overline([Color? c]) => _f(TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: c));
  static TextStyle mono([Color? c]) => _f(TextStyle(fontSize: 13, color: c, fontFeatures: tabular));
}

/// A restaurant's own look (plan feature "branding", set in the restaurant console): highlight colour, text size,
/// heading weight and case, and a logo (media id). `null` everywhere means the House Plating look.
@immutable
class HPBrand {
  const HPBrand({required this.color, this.textSize = 'standard', this.headingWeight = 'bold', this.headingCase = 'normal', this.logoImageId});
  final Color color;
  final String textSize, headingWeight, headingCase;
  final String? logoImageId;

  static HPBrand? fromJson(Object? j) {
    if (j is! Map) return null;
    final hex = '${j['color'] ?? ''}'.replaceAll('#', '');
    if (!RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(hex)) return null;
    return HPBrand(
      color: Color(int.parse('FF$hex', radix: 16)),
      textSize: '${j['textSize'] ?? 'standard'}',
      headingWeight: '${j['headingWeight'] ?? 'bold'}',
      headingCase: '${j['headingCase'] ?? 'normal'}',
      logoImageId: j['logoImageId'] as String?,
    );
  }

  String get hex => '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// Multiplies every text size (wrap the app in `MediaQuery(textScaler: …)`).
  double get textScale => switch (textSize) { 'compact' => .92, 'large' => 1.12, _ => 1.0 };
  FontWeight get weight => switch (headingWeight) { 'regular' => FontWeight.w400, 'heavy' => FontWeight.w900, _ => FontWeight.w700 };

  /// Text on a fill of [c]: dark on light colours, white on dark ones.
  static Color onColor(Color c) => c.computeLuminance() > .45 ? HPColors.whiteInk : HPColors.white;

  /// The brand colour adjusted so text and icons in it stay readable on the page (darker on white, lighter on dark).
  /// Steps the lightness until the contrast with the page reaches 4.5:1 (WCAG AA for text).
  Color inkOn({required bool dark}) {
    final ground = dark ? HPPalette.serviceDark.ground : HPColors.white;
    double contrast(Color a) {
      final la = a.computeLuminance(), lb = ground.computeLuminance();
      return (la > lb ? la + .05 : lb + .05) / (la > lb ? lb + .05 : la + .05);
    }

    var h = HSLColor.fromColor(color);
    for (var i = 0; i < 40 && contrast(h.toColor()) < 4.5; i++) {
      h = h.withLightness((h.lightness + (dark ? .025 : -.025)).clamp(0.0, 1.0));
    }
    return h.toColor();
  }

  /// This brand's colours on top of a House Plating palette.
  HPPalette apply(HPPalette p) {
    final fill = p.isDark ? inkOn(dark: true) : color;
    return p.copyWith(accent: fill, onAccent: onColor(fill), accentInk: inkOn(dark: p.isDark), brand: fill, onBrand: onColor(fill));
  }

  /// Makes this brand (or the House Plating look when null) current for [HPColors.saffron] and heading styles.
  /// Call before building the theme; widgets pick it up on their next build.
  static void activate(HPBrand? b) {
    HPColors.saffron = b?.color ?? HPColors.amber;
    HPColors.onSaffron = b == null ? HPColors.onAmber : onColor(b.color);
    HPType.headingWeight = b?.weight ?? FontWeight.w700;
    HPType.headingUpper = b?.headingCase == 'upper';
  }

  @override
  bool operator ==(Object other) =>
      other is HPBrand && other.color == color && other.textSize == textSize && other.headingWeight == headingWeight && other.headingCase == headingCase && other.logoImageId == logoImageId;
  @override
  int get hashCode => Object.hash(color, textSize, headingWeight, headingCase, logoImageId);
}

/// Two themes, one system (STYLE.md §2) — each in a dark and a light variant so apps can follow the device
/// (`themeMode: ThemeMode.system`). Colours come from [HPPalette]; screens read them with `context.hp`.
abstract final class HPTheme {
  /// Service: cashier POS, table map, payment, waiter, KDS, hub screen. Dark = Midnight Masala, light = Daylight.
  static ThemeData service({Brightness brightness = Brightness.dark, HPBrand? brand}) {
    final p = brightness == Brightness.dark ? HPPalette.serviceDark : HPPalette.serviceLight;
    return build(brand?.apply(p) ?? p);
  }

  /// Back office: Super Admin portal, restaurant console, owner reports.
  static ThemeData backOffice({Brightness brightness = Brightness.light, HPBrand? brand}) {
    final p = brightness == Brightness.dark ? HPPalette.backOfficeDark : HPPalette.backOfficeLight;
    return build(brand?.apply(p) ?? p);
  }

  static ThemeData build(HPPalette p) {
    final brightness = p.isDark ? Brightness.dark : Brightness.light;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: p.accent,
      onPrimary: p.onAccent,
      secondary: HPColors.saffron,
      onSecondary: HPColors.onSaffron,
      error: p.danger,
      onError: HPColors.onChili,
      surface: p.surface,
      onSurface: p.text,
      onSurfaceVariant: p.muted,
      outline: p.line,
      outlineVariant: p.line,
      surfaceContainerLowest: p.ground,
      surfaceContainerLow: p.surface,
      surfaceContainer: p.surface,
      surfaceContainerHigh: p.raised,
      surfaceContainerHighest: p.raised,
      secondaryContainer: p.accent.withValues(alpha: .22),
      onSecondaryContainer: p.text,
      primaryContainer: p.accent.withValues(alpha: .18),
      onPrimaryContainer: p.text,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, scaffoldBackgroundColor: p.ground, brightness: brightness, splashFactory: InkSparkle.splashFactory, fontFamily: HPType.family, fontFamilyFallback: HPType.fallback);
    final shape16 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(HPRadius.button));
    return base.copyWith(
      extensions: [p],
      textTheme: base.textTheme.copyWith(
        headlineLarge: HPType.titleScreen(p.text).copyWith(fontSize: 34),
        headlineMedium: HPType.titleScreen(p.text),
        headlineSmall: HPType.titleCard(p.text).copyWith(fontSize: 24),
        titleLarge: HPType.titleCard(p.text),
        titleMedium: HPType.label(p.text),
        titleSmall: HPType.label(p.text).copyWith(fontSize: 14),
        bodyLarge: HPType.body(p.text).copyWith(fontSize: 15),
        bodyMedium: HPType.body(p.text),
        bodySmall: HPType.body(p.muted),
        labelLarge: HPType.label(p.text),
        labelMedium: HPType.label(p.text).copyWith(fontSize: 13),
        labelSmall: HPType.overline(p.muted).copyWith(fontSize: 11),
      ),
      iconTheme: IconThemeData(color: p.text),
      // smooth, consistent page motion on every platform (STYLE.md §9: 120–180 ms ease-out feel)
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
      dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: p.ground,
        foregroundColor: p.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: HPType.titleCard(p.text).copyWith(fontSize: 22),
      ),
      cardTheme: CardThemeData(color: p.surface, elevation: 0, margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HPRadius.card), side: BorderSide(color: p.line))),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: HPSpace.lg, vertical: HPSpace.lg),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.line)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.line)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.accent, width: 2)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.danger)),
        labelStyle: HPType.body(p.muted),
        hintStyle: HPType.body(p.faint),
        prefixIconColor: p.muted,
        suffixIconColor: p.muted,
      ),
      dialogTheme: DialogThemeData(backgroundColor: p.surface, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HPRadius.panel))),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: p.outline,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(HPRadius.panel))),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.isDark ? p.raised : p.text,
        contentTextStyle: HPType.label(p.isDark ? p.text : p.ground),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        insetPadding: const EdgeInsets.fromLTRB(HPSpace.lg, 0, HPSpace.lg, HPSpace.lg),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: p.accent.withValues(alpha: p.isDark ? .22 : .30),
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith((s) => HPType.label(s.contains(WidgetState.selected) ? p.text : p.muted).copyWith(fontSize: 12)),
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? p.text : p.muted)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: p.surface,
        indicatorColor: p.accent.withValues(alpha: p.isDark ? .22 : .30),
        selectedIconTheme: IconThemeData(color: p.text),
        unselectedIconTheme: IconThemeData(color: p.muted),
        selectedLabelTextStyle: HPType.label(p.text).copyWith(fontSize: 12),
        unselectedLabelTextStyle: HPType.label(p.muted).copyWith(fontSize: 12),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
          side: WidgetStatePropertyAll(BorderSide(color: p.line)),
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.surface),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.onAccent : p.text),
          textStyle: WidgetStatePropertyAll(HPType.label()),
          shape: WidgetStatePropertyAll(shape16),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.surface,
        selectedColor: p.accent,
        side: BorderSide(color: p.line),
        // selected chips sit on the accent fill (saffron / wine), so their text switches to onAccent
        // (chips resolve state on the label *colour*, so it must be a WidgetStateColor)
        labelStyle: HPType.label().copyWith(fontSize: 14, color: WidgetStateColor.resolveWith((s) => s.contains(WidgetState.selected) ? p.onAccent : p.text)),
        secondaryLabelStyle: HPType.label(p.onAccent).copyWith(fontSize: 14),
        checkmarkColor: p.onAccent,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: HPSpace.sm, vertical: HPSpace.xs),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.onAccent, minimumSize: const Size(0, 48), shape: shape16, textStyle: HPType.label())),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(foregroundColor: p.text, side: BorderSide(color: p.outline), minimumSize: const Size(0, 48), shape: shape16, textStyle: HPType.label())),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: p.accentInk, textStyle: HPType.label())),
      listTileTheme: ListTileThemeData(iconColor: p.muted, textColor: p.text, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      popupMenuTheme: PopupMenuThemeData(color: p.surface, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: p.line))),
      tabBarTheme: TabBarThemeData(
        labelColor: p.text,
        unselectedLabelColor: p.muted,
        indicatorColor: p.accent,
        dividerColor: p.line,
        labelStyle: HPType.label(),
        unselectedLabelStyle: HPType.label(),
        indicatorSize: TabBarIndicatorSize.label,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accentInk, linearTrackColor: p.raised),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.onAccent : p.faint),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.raised),
        trackOutlineColor: WidgetStatePropertyAll(p.line),
      ),
      tooltipTheme: TooltipThemeData(decoration: BoxDecoration(color: p.text, borderRadius: BorderRadius.circular(8)), textStyle: HPType.body(p.ground).copyWith(fontSize: 12)),
    );
  }
}
