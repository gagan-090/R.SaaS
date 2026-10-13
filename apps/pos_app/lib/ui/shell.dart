import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';
import '../screens/bill_screens.dart';
import '../screens/kitchen_screen.dart';
import '../screens/more_screens.dart';
import '../screens/tables_screen.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'media.dart';

/// Signs the current person out of this terminal: closes every open screen first, then clears the session,
/// so no screen ever rebuilds without a user.
void switchUser(BuildContext context, WidgetRef ref) {
  Navigator.of(context).popUntil((r) => r.isFirst);
  ref.read(hubApiProvider)?.sessionToken = null;
  ref.read(sessionProvider.notifier).state = null;
}

/// Top bar on every service screen: back, title, hub + sync status, and the signed-in person's menu.
class PosTopBar extends ConsumerWidget {
  const PosTopBar({super.key, required this.title, this.subtitle, this.actions = const [], this.showUser = true});
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final bool showUser;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.hp;
    final ev = ref.watch(hubEventsProvider);
    final online = !ev.hasError;
    final session = ref.watch(sessionProvider);
    final narrow = isNarrow(context);
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    return Material(
      color: p.ground,
      child: SafeArea(
        bottom: false,
        child: Column(children: [
          SizedBox(
            height: 64,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: narrow ? HPSpace.xs : HPSpace.md),
              child: Row(children: [
                if (canPop) IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.of(context).maybePop()) else const SizedBox(width: HPSpace.sm),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(HPType.heading(title), style: HPType.titleCard(p.text).copyWith(fontSize: narrow ? 21 : 24), overflow: TextOverflow.ellipsis, maxLines: 1),
                    if (subtitle != null) Text(subtitle!, style: HPType.body(p.muted).copyWith(fontSize: 12.5), overflow: TextOverflow.ellipsis, maxLines: 1),
                  ]),
                ),
                ...actions,
                _HubPill(online: online, compact: narrow),
                if (showUser && session != null) _UserButton(session: session),
                const SizedBox(width: HPSpace.xs),
              ]),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            child: online ? const SizedBox(width: double.infinity) : const OfflineBanner(message: 'Kitchen hub offline — orders pause until it is back'),
          ),
        ]),
      ),
    );
  }
}

class _HubPill extends ConsumerWidget {
  const _HubPill({required this.online, required this.compact});
  final bool online, compact;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(hubTickProvider);
    final api = ref.watch(hubApiProvider);
    final p = context.hp;
    return FutureBuilder<Json>(
      future: api?.syncStatus(),
      builder: (c, s) {
        final pending = (s.data?['pending'] as int?) ?? 0, failed = (s.data?['failed'] as int?) ?? 0;
        final tone = !online || failed > 0 ? HPTone.danger : (pending > 0 ? HPTone.saffron : HPTone.success);
        final label = !online ? 'Hub offline' : (failed > 0 ? '$failed failed to sync' : (pending > 0 ? '$pending waiting to sync' : 'Hub online'));
        if (compact) {
          return Tooltip(
            message: label,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: HPSpace.sm),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(online ? Icons.wifi_rounded : Icons.wifi_off_rounded, size: 20, color: p.tone(tone)),
                if (online && failed + pending > 0) ...[const SizedBox(width: 2), Text('${failed > 0 ? failed : pending}', style: HPType.label(p.tone(tone)).copyWith(fontSize: 12))],
              ]),
            ),
          );
        }
        return Padding(padding: const EdgeInsets.symmetric(horizontal: HPSpace.sm), child: StatusChip(key: const Key('hub-pill'), label: label, tone: tone, icon: online ? Icons.wifi_rounded : Icons.wifi_off_rounded));
      },
    );
  }
}

class _UserButton extends ConsumerWidget {
  const _UserButton({required this.session});
  final StaffSession session;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.hp;
    return PopupMenuButton<String>(
      key: const Key('user-menu'),
      tooltip: '${session.name} — switch user',
      offset: const Offset(0, 52),
      onSelected: (v) {
        if (v == 'switch') switchUser(context, ref);
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(session.name, style: HPType.label(p.text)),
            subtitle: Text(roleLabel(session.roles), style: HPType.body(p.muted)),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'switch', key: Key('switch-user'), child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.logout_rounded), title: Text('Switch user'))),
      ],
      child: Padding(
        padding: const EdgeInsets.all(HPSpace.xs),
        child: CircleAvatar(
          radius: 18,
          backgroundColor: roleColor(context, session.roles.firstOrNull).withValues(alpha: .22),
          child: Text(session.name.characters.first.toUpperCase(), style: HPType.label(p.text)),
        ),
      ),
    );
  }
}

typedef _Dest = (String key, String label, IconData icon, IconData selectedIcon, Widget page);

/// Home after PIN login: the role's destinations in a bottom bar (phones) or a side rail (tablets / PCs).
/// Order roles start on Tables, chefs on Kitchen, IT admins on Setup. The hub enforces every action anyway.
class PosShell extends ConsumerStatefulWidget {
  const PosShell({super.key});
  @override
  ConsumerState<PosShell> createState() => _PosShellState();
}

class _PosShellState extends ConsumerState<PosShell> {
  int _index = 0;
  final _visits = <String, int>{}; // re-opening a tab reloads it, so Bills / Kitchen are never stale

  void _select(List<_Dest> dest, int v) => setState(() {
        _index = v;
        _visits[dest[v].$1] = (_visits[dest[v].$1] ?? 0) + 1;
      });

  List<_Dest> _destinations(StaffSession s) => [
        if (s.can('order.read')) ('Tables', 'Tables', Icons.table_restaurant_outlined, Icons.table_restaurant_rounded, const TableMapScreen()),
        if (s.can('kds.read')) ('Kitchen', 'Kitchen', Icons.soup_kitchen_outlined, Icons.soup_kitchen_rounded, const KitchenScreen()),
        if (s.can('order.read')) ('Bills', 'Bills', Icons.receipt_long_outlined, Icons.receipt_long_rounded, const BillHistoryScreen()),
        if (!s.can('order.read') && s.can('device.manage')) ('Setup', 'Setup', Icons.settings_suggest_outlined, Icons.settings_suggest_rounded, const AdminHomeScreen()),
        ('More', 'More', Icons.more_horiz_rounded, Icons.more_horiz_rounded, const MoreScreen()),
      ];

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    if (s == null) return const SizedBox.shrink();
    final dest = _destinations(s);
    // pull-down-to-refresh rebuilds the open tab from scratch, like opening it again
    ref.listen(refreshTickProvider, (_, _) => _select(dest, _index.clamp(0, dest.length - 1)));
    final i = _index.clamp(0, dest.length - 1);
    final kds = ref.watch(_kdsCount);
    Widget icon(_Dest d, {bool selected = false}) {
      final ic = Icon(selected ? d.$4 : d.$3);
      final n = d.$1 == 'Kitchen' ? (kds.valueOrNull ?? 0) : 0;
      return n == 0 ? ic : Badge(label: Text('$n'), backgroundColor: HPColors.chili, child: ic);
    }

    final body = IndexedStack(index: i, children: [for (final d in dest) KeyedSubtree(key: ValueKey('${d.$1}-${_visits[d.$1] ?? 0}'), child: d.$5)]);
    if (isNarrow(context)) {
      return Scaffold(
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: i,
          onDestinationSelected: (v) => _select(dest, v),
          destinations: [for (final d in dest) NavigationDestination(key: Key('nav-${d.$1}'), icon: icon(d), selectedIcon: icon(d, selected: true), label: d.$2)],
        ),
      );
    }
    return Scaffold(
      body: Row(children: [
        NavigationRail(
          selectedIndex: i,
          onDestinationSelected: (v) => _select(dest, v),
          labelType: NavigationRailLabelType.all,
          minWidth: 88,
          leading: Padding(
            padding: const EdgeInsets.symmetric(vertical: HPSpace.lg),
            child: BrandLogo(
              height: 44,
              maxWidth: 72,
              fallback: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: HPColors.saffron, shape: BoxShape.circle),
                child: Icon(Icons.restaurant_rounded, color: HPColors.onSaffron),
              ),
            ),
          ),
          destinations: [
            for (final d in dest)
              NavigationRailDestination(
                icon: KeyedSubtree(key: Key('nav-${d.$1}'), child: icon(d)),
                selectedIcon: KeyedSubtree(key: Key('nav-${d.$1}'), child: icon(d, selected: true)),
                label: Text(d.$2),
              ),
          ],
        ),
        VerticalDivider(width: 1, color: context.hp.line),
        Expanded(child: body),
      ]),
    );
  }
}

/// Live count of kitchen tickets not yet served (badge on the Kitchen tab).
final _kdsCount = FutureProvider.autoDispose<int>((ref) async {
  ref.watch(hubTickProvider);
  final api = ref.watch(hubApiProvider);
  final s = ref.watch(sessionProvider);
  if (api == null || s == null || !s.can('kds.read')) return 0;
  final st = await api.state();
  return ((st['kds'] as List?) ?? const []).length;
});
