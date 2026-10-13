import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';
import '../state/app_state.dart';
import '../ui/common.dart';
import '../ui/shell.dart';
import 'setup_screens.dart';

/// "More" tab: who is signed in, and the extra tools their role may use.
class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    if (s == null) return const SizedBox.shrink();
    final p = context.hp;
    final isHub = ref.watch(setupProvider).valueOrNull?.isHub ?? false;
    Widget tile(String key, IconData icon, String title, String sub, VoidCallback onTap) => ListTile(
          key: Key('more-$key'),
          leading: Container(width: 40, height: 40, decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: p.text)),
          title: Text(title, style: HPType.label(p.text)),
          subtitle: Text(sub, style: HPType.body(p.muted)),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        );
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    return Column(children: [
      const PosTopBar(title: 'More', showUser: false),
      Expanded(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(padding: const EdgeInsets.all(HPSpace.lg), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(HPSpace.lg),
                  child: Row(children: [
                    CircleAvatar(radius: 28, backgroundColor: roleColor(context, s.roles.firstOrNull).withValues(alpha: .22), child: Text(s.name.characters.first.toUpperCase(), style: HPType.titleCard(p.text))),
                    const SizedBox(width: HPSpace.lg),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(s.name, style: HPType.titleCard(p.text)),
                        Text(roleLabel(s.roles), style: HPType.body(p.muted)),
                      ]),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: HPSpace.lg),
              Card(
                child: Column(children: [
                  if (s.can('reports.read') || s.can('reports.own') || s.can('payment.take'))
                    tile('tips', Icons.volunteer_activism_rounded, 'Tips', s.can('reports.read') || s.can('payment.take') ? 'Tips per waiter today' : 'Your tips', () => push(const TipsScreen())),
                  if (s.can('device.manage')) tile('printers', Icons.print_rounded, 'Printers', 'Bill and kitchen printers, test print', () => push(const PrintersScreen())),
                  if (isHub || s.can('device.manage')) tile('hub', Icons.router_rounded, 'Hub & devices', 'Pair a new terminal, sync health', () => push(const HubStatusScreen())),
                ]),
              ),
              const SizedBox(height: HPSpace.lg),
              Card(
                child: ListTile(
                  key: const Key('more-switch-user'),
                  leading: Container(width: 40, height: 40, decoration: BoxDecoration(color: p.danger.withValues(alpha: .12), borderRadius: BorderRadius.circular(12)), child: Icon(Icons.logout_rounded, color: p.danger)),
                  title: Text('Switch user', style: HPType.label(p.text)),
                  subtitle: Text('Sign out ${s.name} on this terminal', style: HPType.body(p.muted)),
                  onTap: () => switchUser(context, ref),
                ),
              ),
              const SizedBox(height: HPSpace.lg),
              Text('Light or dark follows this device\'s setting.', textAlign: TextAlign.center, style: HPType.body(p.faint)),
            ]),
          ),
        ),
      ),
    ]);
  }
}

class TipsScreen extends ConsumerWidget {
  const TipsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(hubApiProvider)!;
    ref.watch(hubTickProvider);
    final p = context.hp;
    return Scaffold(
      body: Column(children: [
        const PosTopBar(title: 'Tips'),
        Expanded(
          child: FutureBuilder<List<Json>>(
            future: api.tips(),
            builder: (c, s) {
              if (s.hasError) return ErrorState(message: errText(s.error!));
              if (!s.hasData) return const LoadingState();
              if (s.data!.isEmpty) return const EmptyState(icon: Icons.volunteer_activism_outlined, title: 'No tips yet');
              final total = s.data!.fold<int>(0, (n, r) => n + (r['tip_paise'] as int));
              return ListView(padding: const EdgeInsets.all(HPSpace.lg), children: [
                KpiCard(label: 'Tips', value: rupees(total), caption: '${s.data!.length} waiter(s)', icon: Icons.volunteer_activism_rounded, tone: HPTone.success),
                const SizedBox(height: HPSpace.lg),
                for (final r in s.data!)
                  Padding(
                    padding: const EdgeInsets.only(bottom: HPSpace.sm),
                    child: Card(
                      child: ListTile(
                        leading: CircleAvatar(backgroundColor: roleColor(context, 'waiter').withValues(alpha: .22), child: Text('${r['waiter_name'] ?? '?'}'.characters.first)),
                        title: Text('${r['waiter_name'] ?? r['waiter_id']}', style: HPType.label(p.text)),
                        subtitle: Text('${r['bills']} bill(s)', style: HPType.body(p.muted)),
                        trailing: Text(rupees(r['tip_paise'] as int), style: HPType.titleCard(p.accentInk)),
                      ),
                    ),
                  ),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------- T3 Printers

class PrintersScreen extends ConsumerStatefulWidget {
  const PrintersScreen({super.key});
  @override
  ConsumerState<PrintersScreen> createState() => _PrintersScreenState();
}

class _PrintersScreenState extends ConsumerState<PrintersScreen> {
  final _host = {'bill': TextEditingController(), 'kot': TextEditingController()};
  final _port = {'bill': TextEditingController(text: '9100'), 'kot': TextEditingController(text: '9100')};
  final _width = {'bill': 48, 'kot': 48};
  bool _loaded = false, _busy = false;
  Object? _error;

  HubApi get _api => ref.read(hubApiProvider)!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await _api.printers();
      for (final t in ['bill', 'kot']) {
        final m = p[t] as Map?;
        if (m == null) continue;
        _host[t]!.text = '${m['host']}';
        _port[t]!.text = '${m['port']}';
        _width[t] = m['widthChars'] as int? ?? 48;
      }
      setState(() => _loaded = true);
    } catch (e) {
      setState(() => _error = e);
    }
  }

  Json _settings() => {
        for (final t in ['bill', 'kot'])
          t: _host[t]!.text.trim().isEmpty ? null : {'host': _host[t]!.text.trim(), 'port': int.tryParse(_port[t]!.text) ?? 9100, 'widthChars': _width[t]},
      };

  Future<void> _run(Future<Object?> Function() f, String ok) async {
    setState(() => _busy = true);
    try {
      await f();
      if (mounted) toast(context, ok);
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _section(String target, String title, String help, IconData icon) {
    final p = context.hp;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HPSpace.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [Icon(icon, color: p.accentInk), const SizedBox(width: HPSpace.sm), Expanded(child: Text(title, style: HPType.titleCard(p.text), overflow: TextOverflow.ellipsis))]),
          const SizedBox(height: 4),
          Text(help, style: HPType.body(p.muted)),
          const SizedBox(height: HPSpace.md),
          TextField(key: Key('printer-$target-host'), controller: _host[target], keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Printer IP (blank = none)', hintText: '192.168.1.50')),
          const SizedBox(height: HPSpace.sm),
          TextField(controller: _port[target], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port')),
          const SizedBox(height: HPSpace.sm),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: 48, label: Text('80 mm')), ButtonSegment(value: 32, label: Text('58 mm'))],
            selected: {_width[target]!},
            onSelectionChanged: (v) => setState(() => _width[target] = v.first),
          ),
          const SizedBox(height: HPSpace.sm),
          SecondaryButton(
            label: 'Test print',
            icon: Icons.print_outlined,
            height: 48,
            onPressed: _busy
                ? null
                : () => _run(() async {
                      await _api.savePrinters(_settings());
                      return _api.testPrint(target);
                    }, 'Test page sent'),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          const PosTopBar(title: 'Printers'),
          Expanded(
            child: _error != null
                ? ErrorState(
                    message: errText(_error!),
                    onRetry: () => setState(() {
                      _error = null;
                      _load();
                    }))
                : !_loaded
                    ? const LoadingState()
                    : Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: ListView(padding: const EdgeInsets.all(HPSpace.lg), children: [
                            _section('bill', 'Bill printer', 'Customer bills and reprints. With no printer, bills are still saved and can be printed later.', Icons.receipt_long_rounded),
                            const SizedBox(height: HPSpace.md),
                            _section('kot', 'Kitchen printer', 'KOTs. Leave blank to print KOTs on the bill printer.', Icons.soup_kitchen_rounded),
                            const SizedBox(height: HPSpace.lg),
                            PrimaryButton(key: const Key('printers-save'), label: 'Save', busy: _busy, onPressed: () => _run(() => _api.savePrinters(_settings()), 'Printers saved')),
                          ]),
                        ),
                      ),
          ),
        ]),
      );
}

// ------------------------------------------------------------------------------------------- IT admin home

/// IT admin: no service screens (no order permissions) — printers, devices and sync instead.
class AdminHomeScreen extends ConsumerWidget {
  const AdminHomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(hubApiProvider)!;
    ref.watch(hubTickProvider);
    final p = context.hp;
    Widget tile(String title, String sub, IconData icon, Widget Function() page) => Card(
          child: ListTile(
            key: Key('admin-$title'),
            contentPadding: const EdgeInsets.all(HPSpace.lg),
            leading: Container(width: 48, height: 48, decoration: BoxDecoration(color: HPColors.saffron.withValues(alpha: .18), borderRadius: BorderRadius.circular(14)), child: Icon(icon, color: p.accentInk)),
            title: Text(title, style: HPType.titleCard(p.text)),
            subtitle: Text(sub, style: HPType.body(p.muted)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page())),
          ),
        );
    return Column(children: [
      const PosTopBar(title: 'Setup'),
      Expanded(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(padding: const EdgeInsets.all(HPSpace.lg), children: [
              tile('Printers', 'Bill and kitchen printers, test print', Icons.print_rounded, () => const PrintersScreen()),
              const SizedBox(height: HPSpace.md),
              tile('Hub & devices', 'Pairing code for new terminals, sync health', Icons.router_rounded, () => const HubStatusScreen()),
              const SizedBox(height: HPSpace.lg),
              FutureBuilder<Json>(
                future: api.syncStatus(),
                builder: (c, s) => !s.hasData
                    ? const SkeletonBox(height: 32)
                    : Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
                        StatusChip(label: '${s.data!['pending']} waiting to sync', tone: (s.data!['pending'] as int) > 0 ? HPTone.saffron : HPTone.success),
                        StatusChip(label: '${s.data!['failed']} failed', tone: (s.data!['failed'] as int) > 0 ? HPTone.danger : HPTone.neutral),
                        StatusChip(label: 'Last cloud update ${s.data!['lastPullAt'] == null ? 'never' : clock12(s.data!['lastPullAt'])}'),
                      ]),
              ),
              const SizedBox(height: HPSpace.lg),
              Text('Menu, tables and staff are managed in the web console and arrive here within a minute.', style: HPType.body(p.muted)),
            ]),
          ),
        ),
      ),
    ]);
  }
}
