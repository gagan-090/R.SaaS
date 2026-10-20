import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'screens/admins_screen.dart';
import 'screens/auth_screens.dart';
import 'screens/plans_screen.dart';
import 'screens/console/devices_screen.dart';
import 'screens/console/audit_screen.dart';
import 'screens/console/expenses_screen.dart';
import 'screens/console/home_screen.dart';
import 'screens/console/inventory_screen.dart';
import 'screens/console/menu_screen.dart';
import 'screens/console/roles_screen.dart';
import 'screens/console/settings_screen.dart';
import 'screens/console/staff_screen.dart';
import 'screens/console/tables_screen.dart';
import 'screens/restaurants_screens.dart';
import 'screens/verify_screen.dart';
import 'state/providers.dart';
import 'util/open_link.dart';
import 'widgets/common.dart';

/// One web app, two consoles: platform admins get the Super Admin console, restaurant owners / IT admins the
/// Restaurant console (menu, tables, staff, hubs). The account type from /me decides; the API enforces it.
/// Console pages cross-fade (150 ms) instead of cutting.
Page<void> _fade(GoRouterState s, Widget child) => CustomTransitionPage<void>(
      key: s.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 120),
      transitionsBuilder: (c, a, _, child) => FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOut), child: child),
    );

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.read(authProvider.notifier);
  return GoRouter(
    initialLocation: '/',
    refreshListenable: auth,
    redirect: (context, state) {
      final s = ref.read(authProvider);
      final loc = state.matchedLocation;
      if (loc == '/verify-email' || loc == '/set-pin') return null; // emailed links work whether or not someone is signed in
      return switch (s) {
        RestoringSession() => null, // preserve current matched route during session restoration
        SignedOut() => loc == '/login' ? null : '/login',
        MfaChallenge() || MfaEnrollment() => loc == '/mfa' ? null : '/mfa',
        SignedIn(:final isRestaurant) when isRestaurant => loc.startsWith('/console') ? null : '/console',
        SignedIn() => (loc == '/restoring' || loc == '/login' || loc == '/mfa' || loc.startsWith('/console')) ? '/' : null,
      };
    },
    routes: [
      GoRoute(path: '/restoring', builder: (_, _) => const Scaffold(body: Center(child: CircularProgressIndicator()))),
      GoRoute(path: '/login', builder: (_, s) => LoginScreen(employee: s.uri.queryParameters['mode'] == 'employee')),
      GoRoute(path: '/mfa', builder: (_, _) => const MfaScreen()),
      GoRoute(path: '/verify-email', builder: (_, s) => VerifyEmailScreen(token: s.uri.queryParameters['token'])),
      GoRoute(path: '/set-pin', builder: (_, s) => SetPinScreen(token: s.uri.queryParameters['token'])),
      ShellRoute(
        builder: (c, s, child) => ConsoleShell(location: s.matchedLocation, query: s.uri.queryParameters, nav: platformNav, brand: 'Platform', child: child),
        routes: [
          GoRoute(path: '/', pageBuilder: (_, s) => _fade(s, const DashboardScreen())),
          GoRoute(path: '/restaurants', pageBuilder: (_, s) => _fade(s, RestaurantsScreen(initialStatus: s.uri.queryParameters['status']))),
          GoRoute(path: '/restaurants/:id', pageBuilder: (_, s) => _fade(s, RestaurantDetailScreen(id: s.pathParameters['id']!))),
          GoRoute(path: '/plans', pageBuilder: (_, s) => _fade(s, const PlansScreen())),
          GoRoute(path: '/admins', pageBuilder: (_, s) => _fade(s, AdminsScreen(role: s.uri.queryParameters['role']))),
          GoRoute(path: '/audit', pageBuilder: (_, s) => _fade(s, const AuditScreen())),
        ],
      ),
      ShellRoute(
        builder: (c, s, child) => ConsoleShell(location: s.matchedLocation, nav: restaurantNav, brand: 'Restaurant', child: child),
        routes: [
          GoRoute(path: '/console', pageBuilder: (_, s) => _fade(s, const ConsoleHome())),
          GoRoute(path: '/console/menu', pageBuilder: (_, s) => _fade(s, const MenuScreen())),
          GoRoute(path: '/console/tables', pageBuilder: (_, s) => _fade(s, const TablesScreen())),
          GoRoute(path: '/console/staff', pageBuilder: (_, s) => _fade(s, const StaffScreen())),
          GoRoute(path: '/console/roles', pageBuilder: (_, s) => _fade(s, const RolesScreen())),
          GoRoute(path: '/console/inventory', pageBuilder: (_, s) => _fade(s, const InventoryScreen())),
          GoRoute(path: '/console/expenses', pageBuilder: (_, s) => _fade(s, const ExpensesScreen())),
          GoRoute(path: '/console/audit', pageBuilder: (_, s) => _fade(s, const RestaurantAuditScreen())),
          GoRoute(path: '/console/devices', pageBuilder: (_, s) => _fade(s, const DevicesScreen())),
          GoRoute(path: '/console/settings', pageBuilder: (_, s) => _fade(s, const SettingsScreen())),
        ],
      ),
    ],
  );
});

class AdminApp extends ConsumerWidget {
  const AdminApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // a restaurant with the "branding" plan feature sees its own colour and text style; everyone else House Plating
    final brand = ref.watch(restaurantLookProvider).valueOrNull?.brand;
    HPBrand.activate(brand);
    final authState = ref.watch(authProvider);
    return MaterialApp.router(
      title: 'House Plating',
      debugShowCheckedModeBanner: false,
      theme: HPTheme.backOffice(brand: brand),
      darkTheme: HPTheme.backOffice(brightness: Brightness.dark, brand: brand),
      themeMode: ref.watch(themeModeProvider), // white (Light) by default; Auto follows the device; Dark if chosen
      routerConfig: ref.watch(routerProvider),
      builder: (c, child) {
        if (authState is RestoringSession) {
          return const Scaffold(
            body: Center(
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ),
          );
        }
        return brand == null || brand.textScale == 1
            ? child!
            : MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(brand.textScale)), child: child!);
      },
    );
  }
}

typedef NavItem = (String path, String label, IconData icon, String? permission);

/// The Android POS app (cashier / waiter / kitchen). Override per deployment with --dart-define=APK_URL=…
const apkUrl = String.fromEnvironment('APK_URL', defaultValue: 'https://drive.google.com/file/d/1v8AgxWVezOqZ8yGYYs9iDQBt-8Bw9-fT/view?usp=sharing');

const platformNav = <NavItem>[
  ('/', 'Dashboard', Icons.space_dashboard_outlined, null),
  ('/restaurants', 'Restaurants', Icons.storefront_outlined, 'platform.restaurant.read'),
  ('/plans', 'Plans', Icons.workspace_premium_outlined, 'platform.restaurant.read'),
  ('/admins', 'Admins', Icons.admin_panel_settings_outlined, 'platform.admin.read'),
  ('/audit', 'Audit log', Icons.receipt_long_outlined, 'platform.audit.read'),
];

const restaurantNav = <NavItem>[
  ('/console', 'Dashboard', Icons.space_dashboard_outlined, null),
  ('/console/menu', 'Menu', Icons.restaurant_menu_rounded, 'menu.read'),
  ('/console/tables', 'Floors & tables', Icons.table_restaurant_outlined, 'floor.read'),
  ('/console/inventory', 'Inventory', Icons.inventory_2_outlined, 'inventory.read'),
  ('/console/expenses', 'Expenses', Icons.receipt_long_outlined, 'expense.read'),
  ('/console/audit', 'Audit & records', Icons.fact_check_outlined, 'audit.read'),
  ('/console/staff', 'Staff', Icons.badge_outlined, 'staff.read'),
  ('/console/roles', 'Roles', Icons.admin_panel_settings_outlined, 'staff.read'),
  ('/console/devices', 'Hubs & devices', Icons.router_outlined, 'device.manage'),
  ('/console/settings', 'Settings', Icons.tune_rounded, 'restaurant.profile.read'),
];

/// Sidebar on wide screens, app bar + drawer on phones. Items the signed-in role cannot use are hidden
/// (the API refuses them anyway).
class ConsoleShell extends ConsumerWidget {
  const ConsoleShell({super.key, required this.location, this.query = const {}, required this.nav, required this.brand, required this.child});
  final String location;
  final Map<String, String> query;
  final List<NavItem> nav;
  final String brand;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final me = auth is SignedIn ? auth : null;
    final items = nav.where((n) => n.$4 == null || (me?.can(n.$4!) ?? false)).toList();
    final root = items.isEmpty ? '/' : items.first.$1;
    final idx = items.lastIndexWhere((n) => n.$1 == root ? location == root : location.startsWith(n.$1));
    final narrow = isNarrowWeb(context);
    final p = context.hp;

    final look = ref.watch(restaurantLookProvider).valueOrNull;
    final logoId = look?.brand?.logoImageId;
    Widget sidebar({required bool inDrawer}) => SizedBox(
        width: inDrawer ? null : 248,
        child: Material(
          color: p.sidebar,
          shape: inDrawer || p.isDark ? null : Border(right: BorderSide(color: p.line)),
          child: SafeArea(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(HPSpace.x2, HPSpace.x2, HPSpace.x2, HPSpace.x3),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (logoId != null) ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 56, maxWidth: 180),
                      child: Image.network(ref.read(apiProvider).mediaUrl(logoId), key: const Key('brand-logo'), fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                    ),
                    const SizedBox(height: HPSpace.md),
                  ],
                  if (look?.brand != null && look!.name.isNotEmpty)
                    Text(HPType.heading(look.name), key: const Key('brand-name'), style: HPType.titleScreen(_onSidebar(p)).copyWith(fontSize: 22, height: 1.1))
                  else
                    Text('House\nPlating', style: HPType.titleScreen(_onSidebar(p)).copyWith(fontSize: 26, height: 1.05)),
                  const SizedBox(height: HPSpace.sm),
                  Text('$brand console'.toUpperCase(), style: HPType.overline(_onSidebar(p).withValues(alpha: .65)).copyWith(fontSize: 10)),
                ]),
              ),
              Expanded(
                child: ListView(children: [
                  for (var i = 0; i < items.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: HPSpace.md, vertical: 2),
                      child: items[i].$1 == '/admins'
                          // Admins opens a sub-menu of admin types: All, Super Admin, Onboarding Admin …
                          ? _AdminsNavGroup(
                              item: items[i],
                              selected: i == idx,
                              role: query['role'],
                              onGo: (path) {
                                if (inDrawer) Navigator.of(context).pop();
                                context.go(path);
                              },
                            )
                          : _NavTile(
                              key: Key('nav-${items[i].$2}'),
                              item: items[i],
                              selected: i == idx,
                              onTap: () {
                                if (inDrawer) Navigator.of(context).pop();
                                context.go(items[i].$1);
                              },
                            ),
                    ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(HPSpace.md, 0, HPSpace.md, HPSpace.sm),
                child: _NavTile(
                  key: const Key('download-apk'),
                  item: ('', 'Download POS app (APK)', Icons.android_rounded, null),
                  selected: false,
                  trailing: Icon(Icons.open_in_new_rounded, size: 16, color: _onSidebar(p).withValues(alpha: .6)),
                  onTap: () => openLink(apkUrl),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: HPSpace.lg),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    segmentedButtonTheme: SegmentedButtonThemeData(
                      style: ButtonStyle(
                        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? navAccent(p) : Colors.transparent),
                        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? onNavAccent : _onSidebar(p)),
                        side: WidgetStatePropertyAll(BorderSide(color: _onSidebar(p).withValues(alpha: .3))),
                      ),
                    ),
                  ),
                  child: ThemeModeSwitch(showAuto: false, value: ref.watch(themeModeProvider), onChanged: ref.read(themeModeProvider.notifier).set),
                ),
              ),
              if (me != null)
                Padding(
                  padding: const EdgeInsets.all(HPSpace.lg),
                  child: Row(children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: navAccent(p),
                      child: Text('${me.me['name'] ?? '?'}'.characters.first.toUpperCase(), style: HPType.label(onNavAccent)),
                    ),
                    const SizedBox(width: HPSpace.sm),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${me.me['name'] ?? ''}', style: HPType.label(_onSidebar(p)), overflow: TextOverflow.ellipsis),
                        Text('${me.me['email'] ?? ''}', style: HPType.body(_onSidebar(p).withValues(alpha: .7)).copyWith(fontSize: 12), overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    IconButton(
                      key: const Key('sign-out'),
                      tooltip: 'Sign out',
                      onPressed: () => ref.read(authProvider.notifier).logout(),
                      icon: Icon(Icons.logout_rounded, color: _onSidebar(p), size: 20),
                    ),
                  ]),
                ),
            ]),
          ),
        ),
      );

    if (narrow) {
      return Scaffold(
        appBar: AppBar(
          title: Text(idx >= 0 ? items[idx].$2 : 'House Plating'),
          leading: Builder(builder: (c) => IconButton(key: const Key('open-nav'), tooltip: 'Menu', icon: const Icon(Icons.menu_rounded), onPressed: () => Scaffold.of(c).openDrawer())),
        ),
        drawer: Drawer(backgroundColor: p.sidebar, child: sidebar(inDrawer: true)),
        body: SafeArea(top: false, child: child),
      );
    }
    return Scaffold(body: Row(children: [sidebar(inDrawer: false), Expanded(child: child)]));
  }

  static Color _onSidebar(HPPalette p) => p.isDark || p.sidebar.computeLuminance() < .3 ? HPColors.paper : HPColors.ink;

  /// Selected navigation: dark blue with white text in both looks; a restaurant's own brand colour when it has one.
  static Color navAccent(HPPalette p) => HPColors.saffron != HPColors.amber ? HPColors.saffron : p.isDark ? HPColors.navyDark : HPColors.navy;
  static Color get onNavAccent => HPColors.saffron != HPColors.amber ? HPColors.onSaffron : HPColors.white;
}

/// "Admins" with an arrow: opens the admin types (All, Super Admin, Onboarding Admin …); each shows only that kind.
class _AdminsNavGroup extends ConsumerStatefulWidget {
  const _AdminsNavGroup({required this.item, required this.selected, required this.role, required this.onGo});
  final NavItem item;
  final bool selected;
  final String? role;
  final ValueChanged<String> onGo;
  @override
  ConsumerState<_AdminsNavGroup> createState() => _AdminsNavGroupState();
}

class _AdminsNavGroupState extends ConsumerState<_AdminsNavGroup> {
  late bool _open = widget.selected;

  @override
  void didUpdateWidget(covariant _AdminsNavGroup old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) _open = true;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final fg = ConsoleShell._onSidebar(p);
    final roles = _open ? ref.watch(adminRolesProvider).valueOrNull : null;
    Widget sub(String label, String? role) {
      final on = widget.selected && widget.role == role;
      return Padding(
        padding: const EdgeInsets.only(left: 36, top: 2),
        child: Material(
          color: on ? ConsoleShell.navAccent(p).withValues(alpha: p.isDark ? .45 : .12) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: ListTile(
            key: Key('nav-admins-${role ?? 'all'}'),
            dense: true,
            visualDensity: VisualDensity.compact,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            title: Text(label, overflow: TextOverflow.ellipsis, style: HPType.body(on && !p.isDark ? ConsoleShell.navAccent(p) : fg).copyWith(fontSize: 14, fontWeight: on ? FontWeight.w700 : FontWeight.w400)),
            onTap: () => widget.onGo(role == null ? '/admins' : '/admins?role=${Uri.encodeQueryComponent(role)}'),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _NavTile(
        key: Key('nav-${widget.item.$2}'),
        item: widget.item,
        selected: widget.selected,
        trailing: IconButton(
          key: const Key('nav-admins-toggle'),
          tooltip: _open ? 'Hide admin types' : 'Show admin types',
          visualDensity: VisualDensity.compact,
          icon: Icon(_open ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
              color: widget.selected ? ConsoleShell.onNavAccent : fg),
          onPressed: () => setState(() => _open = !_open),
        ),
        onTap: () {
          setState(() => _open = true);
          widget.onGo('/admins');
        },
      ),
      if (_open) ...[
        sub('All', null),
        for (final r in roles ?? const <Map<String, dynamic>>[]) sub('${r['name']}', '${r['name']}'),
      ],
    ]);
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({super.key, required this.item, required this.selected, required this.onTap, this.trailing});
  final NavItem item;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final fg = selected ? ConsoleShell.onNavAccent : ConsoleShell._onSidebar(p);
    return Material(
      color: selected ? ConsoleShell.navAccent(p) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        dense: true,
        selected: selected,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Icon(item.$3, color: fg, size: 20),
        title: Text(item.$2, style: HPType.label(fg)),
        trailing: trailing,
        onTap: onTap,
      ),
    );
  }
}
