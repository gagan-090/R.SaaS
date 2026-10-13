import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
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

/// Two themes, one system (STYLE.md §2) — each in a dark and a light variant so apps can follow the device
/// (`themeMode: ThemeMode.system`). Colours come from [HPPalette]; screens read them with `context.hp`.
abstract final class HPTheme {
  /// Service: cashier POS, table map, payment, waiter, KDS, hub screen. Dark = Midnight Masala, light = Daylight.
  static ThemeData service({Brightness brightness = Brightness.dark}) =>
      build(brightness == Brightness.dark ? HPPalette.serviceDark : HPPalette.serviceLight);

  /// Back office: Super Admin portal, restaurant console, owner reports.
  static ThemeData backOffice({Brightness brightness = Brightness.light}) =>
      build(brightness == Brightness.dark ? HPPalette.backOfficeDark : HPPalette.backOfficeLight);

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
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, scaffoldBackgroundColor: p.ground, brightness: brightness, splashFactory: InkSparkle.splashFactory);
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
        labelStyle: HPType.label(p.text).copyWith(fontSize: 14),
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
