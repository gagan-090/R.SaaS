import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'screens/setup_screens.dart';
import 'state/app_state.dart';
import 'ui/common.dart';
import 'ui/shell.dart';

/// Device setup → staff PIN login → the role's home (tables, kitchen, setup). One app for every role;
/// Hub mode on the main device. Light (Daylight) or dark (Midnight Masala) follows the device setting.
class PosApp extends ConsumerWidget {
  const PosApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setup = ref.watch(setupProvider);
    final session = ref.watch(sessionProvider);
    // a restaurant with the "branding" plan feature gets its own colour and text style on every role's screens
    final brand = ref.watch(posLookProvider).valueOrNull?.brand;
    HPBrand.activate(brand);
    return MaterialApp(
      title: 'House Plating POS',
      debugShowCheckedModeBanner: false,
      theme: HPTheme.service(brightness: Brightness.light, brand: brand),
      darkTheme: HPTheme.service(brand: brand),
      themeMode: ref.watch(themeModeProvider), // white (Light) by default; Auto or Dark can be chosen in More
      builder: (context, child) {
        final page = PullToRefresh(child: child ?? const SizedBox.shrink());
        if (brand == null || brand.textScale == 1) return page;
        return MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(brand.textScale)), child: page);
      },
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: setup.when(
          loading: () => const Scaffold(key: ValueKey('loading'), body: LoadingState(label: 'Starting…')),
          error: (e, _) => Scaffold(key: const ValueKey('error'), body: ErrorState(message: '$e', onRetry: () => ref.invalidate(setupProvider))),
          data: (s) => s == null
              ? const DeviceSetupScreen(key: ValueKey('setup'))
              : session == null
                  ? const StaffLoginScreen(key: ValueKey('login'))
                  : PosShell(key: ValueKey('shell-${session.userId}')),
        ),
      ),
    );
  }
}
