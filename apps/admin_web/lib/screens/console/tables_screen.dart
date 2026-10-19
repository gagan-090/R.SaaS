import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'floor_editor.dart';

/// T2 Floors & tables: floors as tabs, tables as tiles exactly like the POS table map draws them.
class TablesScreen extends ConsumerStatefulWidget {
  const TablesScreen({super.key});
  @override
  ConsumerState<TablesScreen> createState() => _TablesScreenState();
}

class _TablesScreenState extends ConsumerState<TablesScreen> {
  List<Json>? _floors;
  List<String> _features = const [];
  bool _plan = true; // floor plan view (else the simple list)
  String? _branchId;
  String? _floor;
  Object? _error;

  ApiClient get _api => ref.read(apiProvider);
  bool get _canEdit {
    final a = ref.read(authProvider);
    return a is SignedIn && a.can('floor.manage');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([_api.floors(), _api.overview()]);
      if (!mounted) return;
      setState(() {
        _floors = (r[0] as List).cast<Json>();
        _branchId = (((r[1] as Json)['branches'] as List).cast<Json>().firstOrNull)?['id'] as String?;
        _features = (((r[1] as Json)['license'] as Json)['features'] as List).cast<String>();
        if (_floor == null || !_floors!.any((f) => f['id'] == _floor)) _floor = _floors!.firstOrNull?['id'] as String?;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _run(Future<void> Function() f, String done) async {
    try {
      await f();
      await _load();
      if (mounted) showDone(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<String?> _ask(String title, String label, {String initial = ''}) async {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      barrierDismissible: false,
      context: context,
      builder: (d) => HPDialog(
        title: title,
        actions: [
          SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(d)),
          PrimaryButton(label: 'Save', height: 56, onPressed: () => Navigator.pop(d, c.text.trim())),
        ],
        child: TextField(key: const Key('ask-field'), controller: c, autofocus: true, decoration: InputDecoration(labelText: label), onSubmitted: (v) => Navigator.pop(d, v.trim())),
      ),
    );
  }

  Future<void> _addFloor() async {
    final name = await _ask('New floor', 'Name, e.g. Rooftop');
    if (name == null || name.isEmpty || _branchId == null) return;
    await _run(() async {
      final f = await _api.createFloor(_branchId!, name, sortOrder: _floors?.length ?? 0);
      _floor = f['id'] as String;
    }, 'Floor added');
  }

  Future<void> _editTable(String floorId, [Json? t]) async {
    final name = TextEditingController(text: t?['name'] as String? ?? '${_nextNumber()}');
    var seats = (t?['seats'] as int?) ?? 4;
    final ok = await showDialog<bool>(
      barrierDismissible: false,
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => HPDialog(
          title: t == null ? 'Add a table' : 'Table ${t['name']}',
          actions: [
            if (t != null)
              DangerButton(label: 'Delete', onPressed: () async {
                Navigator.pop(d);
                if (await confirm(context, title: 'Delete table ${t['name']}?', message: 'It disappears from the table map on every terminal.')) {
                  await _run(() => _api.deleteTable(t['id'] as String), 'Table deleted');
                }
              }),
            SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(d)),
            PrimaryButton(key: const Key('save-table'), label: 'Save', height: 56, onPressed: () => Navigator.pop(d, true)),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(key: const Key('table-name'), controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Table number or name')),
            const SizedBox(height: HPSpace.lg),
            Text('SEATS', style: HPType.overline(context.hp.muted)),
            const SizedBox(height: HPSpace.sm),
            Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
              for (final n in [2, 4, 6, 8, 10, 12]) ChoiceChip(label: Text('$n'), selected: seats == n, onSelected: (_) => set(() => seats = n)),
            ]),
          ]),
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    await _run(
      () async => t == null ? await _api.createTable(floorId, name.text.trim(), seats) : await _api.updateTable(t['id'] as String, {'name': name.text.trim(), 'seats': seats}),
      t == null ? 'Table added' : 'Table saved',
    );
  }

  int _nextNumber() {
    final nums = [for (final f in _floors!) for (final t in (f['tables'] as List).cast<Json>()) int.tryParse('${t['name']}') ?? 0];
    return nums.isEmpty ? 1 : nums.reduce((a, b) => a > b ? a : b) + 1;
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return loadErrorView(_error!, page: 'Floors & tables', onRetry: _load);
    if (_floors == null) return const SkeletonGrid(maxExtent: 140);
    final edit = _canEdit;
    final floor = _floors!.where((f) => f['id'] == _floor).firstOrNull;
    final tables = [...?(floor?['tables'] as List?)?.cast<Json>()]
      ..sort((a, b) => (int.tryParse('${a['name']}') ?? 999).compareTo(int.tryParse('${b['name']}') ?? 999));
    final total = _floors!.fold<int>(0, (s, f) => s + (f['tables'] as List).length);
    final seats = _floors!.fold<int>(0, (s, f) => s + (f['tables'] as List).cast<Json>().fold<int>(0, (x, t) => x + (t['seats'] as int)));
    return PageFrame(
      title: 'Floors & tables',
      subtitle: '$total tables · $seats seats · the POS table map shows exactly this',
      actions: [if (edit) SecondaryButton(key: const Key('add-floor'), label: 'Add floor', icon: Icons.layers_outlined, height: 48, onPressed: _addFloor)],
      child: _floors!.isEmpty
          ? EmptyState(
              icon: Icons.table_restaurant_outlined,
              title: 'No floors yet',
              message: 'Start with one floor (e.g. "Ground floor"), then add its tables.',
              action: edit ? PrimaryButton(label: 'Add a floor', icon: Icons.add_rounded, onPressed: _addFloor) : null,
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                height: 44,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final f in _floors!)
                    Padding(
                      padding: const EdgeInsets.only(right: HPSpace.sm),
                      child: CategoryChip(label: '${f['name']}', count: (f['tables'] as List).length, selected: f['id'] == _floor, onTap: () => setState(() => _floor = f['id'] as String)),
                    ),
                ]),
              ),
              const SizedBox(height: HPSpace.lg),
              if (floor != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(HPSpace.lg),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.spaceBetween, children: [
                        Text('${floor['name']}', style: HPType.titleCard(context.hp.text)),
                        SegmentedButton<bool>(
                          key: const Key('floor-view'),
                          showSelectedIcon: false,
                          segments: const [ButtonSegment(value: true, label: Text('Floor plan'), icon: Icon(Icons.map_outlined)), ButtonSegment(value: false, label: Text('List'), icon: Icon(Icons.grid_view_rounded))],
                          selected: {_plan},
                          onSelectionChanged: (v) => setState(() => _plan = v.first),
                        ),
                        if (edit) ...[
                          IconButton(tooltip: 'Rename floor', icon: const Icon(Icons.edit_outlined), onPressed: () async {
                            final n = await _ask('Rename floor', 'Name', initial: '${floor['name']}');
                            if (n != null && n.isNotEmpty) await _run(() => _api.updateFloor(floor['id'] as String, {'name': n}), 'Floor renamed');
                          }),
                          IconButton(tooltip: 'Delete floor', icon: const Icon(Icons.delete_outline_rounded), onPressed: () async {
                            if (await confirm(context, title: 'Delete ${floor['name']}?', message: 'Only floors without tables can be deleted.')) {
                              await _run(() => _api.deleteFloor(floor['id'] as String), 'Floor deleted');
                            }
                          }),
                        ],
                      ]),
                      const SizedBox(height: HPSpace.lg),
                      if (_plan)
                        FloorEditor(
                          key: ValueKey('plan-${floor['id']}'),
                          api: _api,
                          floorId: floor['id'] as String,
                          canEdit: edit,
                          canSetStatus: ref.read(authProvider) is SignedIn && (ref.read(authProvider) as SignedIn).can('order.write'),
                          editorInPlan: _features.contains('floor.editor'),
                        )
                      else
                      LayoutBuilder(builder: (c, box) {
                        final cols = (box.maxWidth / 130).floor().clamp(2, 10);
                        const gap = HPSpace.md;
                        final w = (box.maxWidth - gap * (cols - 1)) / cols;
                        return Wrap(spacing: gap, runSpacing: gap, children: [
                          for (final t in tables)
                            SizedBox(
                              width: w,
                              height: w * .9,
                              child: TableTile(key: Key('console-table-${t['name']}'), name: '${t['name']}', seats: t['seats'] as int, state: TableState.free, expand: true, onTap: edit ? () => _editTable(floor['id'] as String, t) : null),
                            ),
                          if (edit)
                            SizedBox(
                              width: w,
                              height: w * .9,
                              child: Material(
                                color: context.hp.raised,
                                borderRadius: BorderRadius.circular(HPRadius.card),
                                child: InkWell(
                                  key: const Key('add-table'),
                                  borderRadius: BorderRadius.circular(HPRadius.card),
                                  onTap: () => _editTable(floor['id'] as String),
                                  child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.add_rounded, color: context.hp.accentInk), Text('Add table', style: HPType.label(context.hp.accentInk))])),
                                ),
                              ),
                            ),
                        ]);
                      }),
                    ]),
                  ),
                ),
            ]),
    );
  }
}
