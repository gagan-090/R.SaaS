import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'screens/service_screens.dart';
import 'screens/setup_screens.dart';
import 'state/app_state.dart';

/// Device setup → staff PIN login → role home. One app for cashier, waiter, kitchen and owner; Hub mode on the hub device.
class PosApp extends ConsumerWidget {
  const PosApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setup = ref.watch(setupProvider);
    final session = ref.watch(sessionProvider);
    return MaterialApp(
      title: 'House Plating POS',
      debugShowCheckedModeBanner: false,
      theme: HPTheme.service(),
      home: setup.when(
        loading: () => const Scaffold(body: LoadingState(label: 'Starting…')),
        error: (e, _) => Scaffold(body: ErrorState(message: '$e', onRetry: () => ref.invalidate(setupProvider))),
        data: (s) => s == null
            ? const DeviceSetupScreen()
            : session == null
                ? const StaffLoginScreen()
                : const RoleHome(),
      ),
    );
  }
}
