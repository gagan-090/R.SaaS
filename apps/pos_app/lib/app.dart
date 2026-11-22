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
    ref.watch(promotionWatcherProvider); // the owner can make this device the main device from the console
    final promoting = ref.watch(promotionStatusProvider);
    // a restaurant with the "branding" plan feature gets its own colour and text style on every role's screens
    final brand = ref.watch(posLookProvider).valueOrNull?.brand;
    HPBrand.activate(brand);
    return MaterialApp(
      title: 'BhojMitra',
      debugShowCheckedModeBanner: false,
      theme: HPTheme.service(brightness: Brightness.light, brand: brand),
      darkTheme: HPTheme.service(brand: brand),
      themeMode: ref.watch(themeModeProvider), // white (Light) by default; Auto or Dark can be chosen in More
      builder: (context, child) {
        // touching anywhere outside a text field closes the on-screen keyboard (Android / iOS keep it open otherwise)
        Widget page = DismissKeyboardOnTapOutside(child: PullToRefresh(child: child ?? const SizedBox.shrink()));
        if (promoting != null) {
          page = Column(children: [
            Material(
              key: const Key('promotion-banner'),
              color: HPColors.saffron,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HPSpace.lg, vertical: HPSpace.sm),
                  child: Row(children: [
                    Expanded(child: Text(promoting, style: HPType.label(HPColors.onSaffron))),
                    IconButton(tooltip: 'Close', icon: Icon(Icons.close_rounded, color: HPColors.onSaffron), onPressed: () => ref.read(promotionStatusProvider.notifier).state = null),
                  ]),
                ),
              ),
            ),
            Expanded(child: page),
          ]);
        }
        if (brand == null || brand.textScale == 1) return page;
        // the brand's size multiplies the person's accessibility setting; it never replaces it
        final system = MediaQuery.textScalerOf(context).scale(100) / 100;
        return MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(system * brand.textScale)), child: page);
      },
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: setup.when(
          loading: () => const Scaffold(key: ValueKey('loading'), backgroundColor: Colors.white, body: Center(child: BhojMitraLogo(height: 160, plate: false))),
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
