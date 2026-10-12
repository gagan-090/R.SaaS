import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'screens/admins_screen.dart';
import 'screens/auth_screens.dart';
import 'screens/restaurants_screens.dart';
import 'state/providers.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.read(authProvider.notifier);
  return GoRouter(
    initialLocation: '/',
    refreshListenable: auth,
    redirect: (context, state) {
      final s = ref.read(authProvider);
      final loc = state.matchedLocation;
      return switch (s) {
        SignedOut() => loc == '/login' ? null : '/login',
        MfaChallenge() || MfaEnrollment() => loc == '/mfa' ? null : '/mfa',
        SignedIn() => (loc == '/login' || loc == '/mfa') ? '/' : null,
      };
    },
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/mfa', builder: (_, _) => const MfaScreen()),
      ShellRoute(
        builder: (c, s, child) => _Shell(location: s.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/', builder: (_, _) => const DashboardScreen()),
          GoRoute(path: '/restaurants', builder: (_, s) => RestaurantsScreen(initialStatus: s.uri.queryParameters['status'])),
          GoRoute(path: '/restaurants/:id', builder: (_, s) => RestaurantDetailScreen(id: s.pathParameters['id']!)),
          GoRoute(path: '/plans', builder: (_, _) => const PlansScreen()),
          GoRoute(path: '/admins', builder: (_, _) => const AdminsScreen()),
          GoRoute(path: '/audit', builder: (_, _) => const AuditScreen()),
        ],
      ),
    ],
  );
});

class AdminApp extends ConsumerWidget {
  const AdminApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
        title: 'Restaurant SaaS · Super Admin',
        debugShowCheckedModeBanner: false,
        theme: HPTheme.backOffice(),
        routerConfig: ref.watch(routerProvider),
      );
}

class _Shell extends ConsumerWidget {
  const _Shell({required this.location, required this.child});
  final String location;
  final Widget child;
  static const _nav = [
    ('/', 'Dashboard', Icons.space_dashboard_outlined, null),
    ('/restaurants', 'Restaurants', Icons.storefront_outlined, 'platform.restaurant.read'),
    ('/plans', 'Plans', Icons.workspace_premium_outlined, 'platform.restaurant.read'),
    ('/admins', 'Admins', Icons.admin_panel_settings_outlined, 'platform.admin.read'),
    ('/audit', 'Audit log', Icons.receipt_long_outlined, 'platform.audit.read'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final me = auth is SignedIn ? auth : null;
    final items = _nav.where((n) => n.$4 == null || (me?.can(n.$4!) ?? false)).toList();
    final idx = items.lastIndexWhere((n) => n.$1 == '/' ? location == '/' : location.startsWith(n.$1));
    return Scaffold(
      body: Row(children: [
        Container(
          width: 232,
          color: HPColors.wineDeep,
          child: SafeArea(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(HPSpace.x2, HPSpace.x2, HPSpace.x2, HPSpace.x3),
                child: Text('House\nPlating', style: HPType.titleScreen(HPColors.paper).copyWith(fontSize: 26, height: 1.05)),
              ),
              for (var i = 0; i < items.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HPSpace.md, vertical: 2),
                  child: Material(
                    color: i == idx ? HPColors.wine : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    child: ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      leading: Icon(items[i].$3, color: HPColors.paper),
                      title: Text(items[i].$2, style: HPType.label(HPColors.paper)),
                      onTap: () => context.go(items[i].$1),
                    ),
                  ),
                ),
              const Spacer(),
              if (me != null)
                Padding(
                  padding: const EdgeInsets.all(HPSpace.lg),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${me.me['name'] ?? ''}', style: HPType.label(HPColors.paper)),
                    Text('${me.me['email'] ?? ''}', style: HPType.body(HPColors.paper.withValues(alpha: .7)).copyWith(fontSize: 12)),
                    TextButton.icon(
                      onPressed: () => ref.read(authProvider.notifier).logout(),
                      icon: const Icon(Icons.logout, size: 16, color: HPColors.saffron),
                      label: Text('Sign out', style: HPType.label(HPColors.saffron)),
                    ),
                  ]),
                ),
            ]),
          ),
        ),
        Expanded(child: child),
      ]),
    );
  }
}
