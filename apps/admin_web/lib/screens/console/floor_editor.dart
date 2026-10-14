import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../widgets/common.dart';

/// Visual floor editor (plan feature "floor.editor"): drag tables and chairs, rotate, resize, change shape, add,
/// duplicate and delete; grid snapping, zoom and pan; save / cancel / reload. Without edit rights (or without the
/// feature) it is the live floor view: tables coloured by state, and staff who take orders can mark a table
/// reserved or out of use.
class FloorEditor extends StatefulWidget {
  const FloorEditor({super.key, required this.api, required this.floorId, required this.canEdit, required this.canSetStatus, required this.editorInPlan});
  final ApiClient api;
  final String floorId;
  final bool canEdit, canSetStatus, editorInPlan;
  @override
  State<FloorEditor> createState() => _FloorEditorState();
}

class _FloorEditorState extends State<FloorEditor> {
  Json? _server; // last loaded layout
  Object? _error;
  List<HPFloorTable> _tables = [];
  double _w = 1200, _h = 800;
  int _version = 1;
  int? _sel;
  bool _dirty = false, _snap = true, _busy = false, _editing = false, _chairMode = false;
  final _tc = TransformationController();
  static const _grid = 10.0;

  bool get _editable => widget.canEdit && widget.editorInPlan && _editing;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FloorEditor old) {
    super.didUpdateWidget(old);
    if (old.floorId != widget.floorId) {
      _editing = false;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final l = await widget.api.floorLayout(widget.floorId);
      if (!mounted) return;
      setState(() {
        _server = l;
        final f = l['floor'] as Json;
        _w = (f['width'] as num).toDouble();
        _h = (f['height'] as num).toDouble();
        _version = f['version'] as int;
        _tables = [
          for (final t in (l['tables'] as List).cast<Json>()) HPFloorTable.fromJson(t, status: '${t['live']}' == 'available' ? 'free' : '${t['live']}'),
        ];
        _sel = null;
        _dirty = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _change(VoidCallback f) => setState(() {
    f();
    _dirty = true;
  });

  double _snapTo(double v) => _snap ? (v / _grid).round() * _grid : v;

  String _nextName() {
    final nums = _tables.map((t) => int.tryParse(t.name) ?? 0);
    return '${(nums.isEmpty ? 0 : nums.reduce(math.max)) + 1}';
  }

  /// Puts a new table in the visible centre of the canvas.
  void _add(String shape) {
    final inv = Matrix4.inverted(_tc.value);
    final box = context.size ?? const Size(800, 600);
    final c = MatrixUtils.transformPoint(inv, Offset(box.width / 2, 200));
    final seats = shape == 'rect' ? 6 : (shape == 'round' ? 2 : 4);
    _change(() {
      _tables.add(
        HPFloorTable(
          name: _nextName(),
          seats: seats,
          shape: shape,
          x: _snapTo(c.dx.clamp(60, _w - 60)),
          y: _snapTo(c.dy.clamp(60, _h - 60)),
          width: shape == 'rect' ? 140 : 80,
          height: 80,
        ),
      );
      _sel = _tables.length - 1;
    });
  }

  void _duplicate() {
    if (_sel == null) return;
    final t = _tables[_sel!].copy()
      ..id = null
      ..name = _nextName()
      ..x = math.min(_w - 40, _tables[_sel!].x + 40)
      ..y = math.min(_h - 40, _tables[_sel!].y + 40);
    _change(() {
      _tables.add(t);
      _sel = _tables.length - 1;
    });
  }

  void _delete() {
    if (_sel == null) return;
    final t = _tables[_sel!];
    if (t.status == 'occupied' || t.status == 'bill_printed') {
      showError(context, 'Table ${t.name} has an open order. Close it before removing the table.');
      return;
    }
    _change(() {
      _tables.removeAt(_sel!);
      _sel = null;
    });
  }

  List<(String, String)> get _overlaps => floorOverlaps(_tables);

  String? get _problem {
    final names = _tables.map((t) => t.name.trim().toLowerCase()).toList();
    final dup = names.where((n) => names.where((x) => x == n).length > 1).firstOrNull;
    if (dup != null) return 'Two tables are called "$dup". Table names must be unique.';
    if (names.any((n) => n.isEmpty)) return 'Every table needs a name or number.';
    return null;
  }

  Future<void> _save() async {
    final problem = _problem;
    if (problem != null) return showError(context, problem);
    setState(() => _busy = true);
    try {
      final r = await widget.api.saveFloorLayout(widget.floorId, {
        'version': _version,
        'width': _w.round(),
        'height': _h.round(),
        'tables': [for (final t in _tables) t.toJson()],
      });
      final warn = (r['warnings'] as List).length;
      await _load();
      if (mounted) {
        setState(() => _editing = false);
        showDone(context, warn == 0 ? 'Floor plan saved' : 'Saved — $warn pair${warn == 1 ? '' : 's'} of tables overlap');
      }
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    if (_dirty && !await confirm(context, title: 'Discard changes?', message: 'The floor goes back to the last saved plan.', confirmLabel: 'Discard')) return;
    setState(() => _editing = false);
    await _load();
  }

  Future<void> _setStatus(HPFloorTable t) async {
    final s = await showDialog<String>(
      context: context,
      builder: (d) => HPDialog(
        title: 'Table ${t.name}',
        actions: [SecondaryButton(label: 'Close', onPressed: () => Navigator.pop(d))],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${t.seats} seats · ${floorStateStyle(d.hp, t.status).$3}', style: HPType.body(d.hp.muted)),
            if (widget.canSetStatus && t.status != 'occupied' && t.status != 'bill_printed') ...[
              const SizedBox(height: HPSpace.md),
              for (final (v, l) in [('available', 'Available'), ('reserved', 'Reserved'), ('unavailable', 'Out of use')])
                ListTile(key: Key('status-$v'), title: Text(l), leading: const Icon(Icons.circle_outlined, size: 16), onTap: () => Navigator.pop(d, v)),
            ],
          ],
        ),
      ),
    );
    if (s == null) return;
    try {
      await widget.api.setTableStatus(t.id!, s);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Editing: a drag that starts on a table moves it (it never pans the canvas). Otherwise a plain tap.
  Widget _tableGestures({required Key key, required VoidCallback onTap, VoidCallback? onStart, ValueChanged<Offset>? onMove, VoidCallback? onEnd, required Widget child}) {
    if (onMove == null) return GestureDetector(key: key, onTap: onTap, child: child);
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: eagerPan(key: key, onStart: (_) => onStart?.call(), onUpdate: (d) => onMove(d.delta), onEnd: (_) => onEnd?.call(), child: child),
    );
  }

  void _zoom(double by) {
    final m = _tc.value.clone()..scaleByDouble(by, by, 1, 1);
    _tc.value = m;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    if (_error != null) return ErrorState(message: '$_error', onRetry: _load);
    if (_server == null) return const SkeletonBox(height: 420);
    final narrow = MediaQuery.sizeOf(context).width < 900;
    final overlaps = _overlaps;
    final warnNames = {
      for (final o in overlaps) ...[o.$1, o.$2],
    };

    final canvas = ClipRRect(
      borderRadius: BorderRadius.circular(HPRadius.card),
      child: Container(
        height: narrow ? 420 : 560,
        color: p.raised,
        child: InteractiveViewer(
          key: const Key('floor-canvas'),
          transformationController: _tc,
          constrained: false,
          minScale: .2,
          maxScale: 3,
          boundaryMargin: const EdgeInsets.all(600),
          child: GestureDetector(
            onTap: () => setState(() => _sel = null),
            child: SizedBox(
              width: _w,
              height: _h,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: p.ground,
                        border: Border.all(color: p.outline),
                      ),
                      child: CustomPaint(painter: FloorGridPainter(p.line.withValues(alpha: .7))),
                    ),
                  ),
                  for (final (i, t) in _tables.indexed)
                    Positioned(
                      left: t.x - t.box / 2,
                      top: t.y - t.box / 2,
                      child: _tableGestures(
                        key: Key('table-${t.name}'),
                        onTap: () => _editable ? setState(() => _sel = i) : _setStatus(t),
                        onStart: _editable ? () => setState(() => _sel = i) : null,
                        onMove: _editable
                            ? (d) => _change(() {
                                t.x = (t.x + d.dx).clamp(0, _w);
                                t.y = (t.y + d.dy).clamp(0, _h);
                              })
                            : null,
                        onEnd: _editable
                            ? () => _change(() {
                                t.x = _snapTo(t.x);
                                t.y = _snapTo(t.y);
                              })
                            : null,
                        child: FloorTableView(
                          table: t,
                          selected: _sel == i,
                          warn: warnNames.contains(t.name),
                          highlightChairs: _editable && _chairMode && _sel == i,
                          onChairDrag: _editable && _chairMode && _sel == i
                              ? (ci, delta) => _change(() {
                                  final cs = [...t.effectiveChairs];
                                  cs[ci] = HPChair(cs[ci].x + delta.dx, cs[ci].y + delta.dy, cs[ci].rotation);
                                  t.chairs = cs;
                                })
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final toolbar = Wrap(
      spacing: HPSpace.sm,
      runSpacing: HPSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (_editable) ...[
          PopupMenuButton<String>(
            key: const Key('add-plan-table'),
            tooltip: 'Add a table',
            onSelected: _add,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'round',
                child: ListTile(leading: Icon(Icons.circle_outlined), title: Text('Round table')),
              ),
              PopupMenuItem(
                value: 'square',
                child: ListTile(leading: Icon(Icons.crop_square_rounded), title: Text('Square table')),
              ),
              PopupMenuItem(
                value: 'rect',
                child: ListTile(leading: Icon(Icons.rectangle_outlined), title: Text('Long table')),
              ),
            ],
            child: const Chip(avatar: Icon(Icons.add_rounded, size: 18), label: Text('Add table')),
          ),
          FilterChip(key: const Key('snap'), label: const Text('Snap to grid'), selected: _snap, onSelected: (v) => setState(() => _snap = v)),
          FilterChip(key: const Key('chair-mode'), label: const Text('Move chairs'), selected: _chairMode, onSelected: (v) => setState(() => _chairMode = v)),
        ],
        IconButton(tooltip: 'Zoom in', icon: const Icon(Icons.zoom_in_rounded), onPressed: () => _zoom(1.25)),
        IconButton(tooltip: 'Zoom out', icon: const Icon(Icons.zoom_out_rounded), onPressed: () => _zoom(.8)),
        IconButton(tooltip: 'Reset view', icon: const Icon(Icons.fit_screen_rounded), onPressed: () => _tc.value = Matrix4.identity()),
        IconButton(key: const Key('reload-plan'), tooltip: 'Reload', icon: const Icon(Icons.refresh_rounded), onPressed: _dirty ? _cancel : _load),
      ]);
    final actions = Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
        if (widget.canEdit && widget.editorInPlan && !_editing)
          PrimaryButton(
            key: const Key('edit-plan'),
            label: 'Edit floor plan',
            icon: Icons.edit_outlined,
            height: 44,
            onPressed: () => setState(() => _editing = true),
          ),
        if (_editable) ...[
          SecondaryButton(key: const Key('cancel-plan'), label: 'Cancel', onPressed: _busy ? null : _cancel),
          PrimaryButton(key: const Key('save-plan'), label: 'Save plan', busy: _busy, height: 44, onPressed: _dirty ? _save : null),
        ],
      ],
    );

    final panel = _editable ? _props(p, overlaps) : _liveInfo(p);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.canEdit && !widget.editorInPlan)
          Padding(
            padding: const EdgeInsets.only(bottom: HPSpace.md),
            child: Container(
              key: const Key('editor-locked'),
              padding: const EdgeInsets.all(HPSpace.md),
              decoration: BoxDecoration(color: HPColors.amber.withValues(alpha: .14), borderRadius: BorderRadius.circular(12), border: Border.all(color: HPColors.amber)),
              child: Row(children: [
                Icon(Icons.lock_outline_rounded, color: p.accentInk),
                const SizedBox(width: HPSpace.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Moving tables is locked: the visual floor editor is not in your plan', style: HPType.label(p.text)),
                    const SizedBox(height: 2),
                    Text('Ask House Plating to switch on "Visual floor editor" for your plan. Until then you can add tables in the List and see the live floor here.', style: HPType.body(p.muted)),
                  ]),
                ),
              ]),
            ),
          ),
        Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: HPSpace.md, runSpacing: HPSpace.sm, children: [toolbar, actions]),
        if (_editable)
          Padding(padding: const EdgeInsets.only(top: HPSpace.sm), child: Text('Drag a table to move it with all its chairs. Turn on Move chairs to adjust individual chairs on the selected table. Choose Save plan to keep your changes.', style: HPType.body(p.muted))),
        const SizedBox(height: HPSpace.sm),
        if (narrow) ...[
          canvas,
          const SizedBox(height: HPSpace.md),
          panel,
        ] else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: canvas),
              const SizedBox(width: HPSpace.lg),
              SizedBox(width: 300, child: panel),
            ],
          ),
      ],
    );
  }

  Widget _liveInfo(HPPalette p) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('LIVE FLOOR', style: HPType.overline(p.muted)),
      const SizedBox(height: HPSpace.sm),
      const FloorLegend(),
      const SizedBox(height: HPSpace.md),
      Text(
        widget.canSetStatus ? 'Tap a table to mark it reserved or out of use.' : 'Tables show their state from the POS (synced every few seconds).',
        style: HPType.body(p.muted),
      ),
    ],
  );

  Widget _props(HPPalette p, List<(String, String)> overlaps) {
    final t = _sel == null ? null : _tables[_sel!];
    Widget label(String s) => Padding(
      padding: const EdgeInsets.only(top: HPSpace.md, bottom: HPSpace.xs),
      child: Text(s, style: HPType.overline(p.muted)),
    );
    if (t == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('FLOOR', style: HPType.overline(p.muted)),
          const SizedBox(height: HPSpace.sm),
          Text('Drag tables to place them. Tap one to edit it. Pinch or use the buttons to zoom; drag the background to pan.', style: HPType.body(p.muted)),
          label('Floor size (cm)'),
          Row(
            children: [
              Expanded(child: _num('floor-w', 'Width', _w, 300, 10000, (v) => _change(() => _w = v))),
              const SizedBox(width: HPSpace.sm),
              Expanded(child: _num('floor-h', 'Depth', _h, 300, 10000, (v) => _change(() => _h = v))),
            ],
          ),
          if (overlaps.isNotEmpty) ...[
            label('Warnings'),
            for (final o in overlaps) Text('Tables ${o.$1} and ${o.$2} overlap', key: Key('overlap-${o.$1}-${o.$2}'), style: HPType.body(p.danger)),
          ],
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.only(top: HPSpace.sm),
              child: Text(_problem!, style: HPType.body(p.danger)),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('TABLE', style: HPType.overline(p.muted))),
            IconButton(key: const Key('duplicate-table'), tooltip: 'Duplicate', icon: const Icon(Icons.copy_all_outlined), onPressed: _duplicate),
            IconButton(
              key: const Key('delete-table'),
              tooltip: 'Remove',
              icon: Icon(Icons.delete_outline_rounded, color: p.danger),
              onPressed: _delete,
            ),
          ],
        ),
        TextFormField(
          key: ValueKey('name-${identityHashCode(t)}'),
          initialValue: t.name,
          decoration: const InputDecoration(labelText: 'Name or number'),
          onChanged: (v) => _change(() => t.name = v.trim()),
        ),
        label('Shape'),
        SegmentedButton<String>(
          key: const Key('shape'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'round', label: Text('Round')),
            ButtonSegment(value: 'square', label: Text('Square')),
            ButtonSegment(value: 'rect', label: Text('Long')),
          ],
          selected: {t.shape},
          onSelectionChanged: (s) => _change(() {
            t.shape = s.first;
            if (t.shape != 'rect') t.height = t.width;
            t.chairs = null;
          }),
        ),
        label('Seats'),
        Row(
          children: [
            IconButton(
              key: const Key('seats-minus'),
              icon: const Icon(Icons.remove_rounded),
              onPressed: t.seats > 1
              ? () => _change(() {
                  t.seats--;
                  t.chairs = null;
                })
              : null,
            ),
            Text('${t.seats}', key: const Key('seats'), style: HPType.titleCard(p.text)),
            IconButton(
              key: const Key('seats-plus'),
              icon: const Icon(Icons.add_rounded),
              onPressed: t.seats < 40
              ? () => _change(() {
                  t.seats++;
                  t.chairs = null;
                })
              : null,
            ),
          ],
        ),
        label('Size (cm)'),
        Row(
          children: [
            Expanded(
              child: _num(
                'tw-${identityHashCode(t)}',
                t.shape == 'round' ? 'Diameter' : 'Width',
                t.width,
                30,
                800,
                (v) => _change(() {
                  t.width = v;
                  if (t.shape != 'rect') t.height = v;
                }),
              ),
            ),
            if (t.shape == 'rect') ...[
              const SizedBox(width: HPSpace.sm),
              Expanded(child: _num('th-${identityHashCode(t)}', 'Depth', t.height, 30, 800, (v) => _change(() => t.height = v))),
            ],
          ],
        ),
        label('Rotation ${t.rotation}°'),
        Row(
          children: [
            IconButton(
              key: const Key('rotate-left'),
              tooltip: 'Rotate 15° left',
              icon: const Icon(Icons.rotate_left_rounded),
              onPressed: () => _change(() => t.rotation = (t.rotation - 15) % 360),
            ),
            Expanded(
              child: Slider(value: t.rotation.toDouble(), max: 345, divisions: 23, onChanged: (v) => _change(() => t.rotation = v.round())),
            ),
            IconButton(
              key: const Key('rotate-right'),
              tooltip: 'Rotate 15° right',
              icon: const Icon(Icons.rotate_right_rounded),
              onPressed: () => _change(() => t.rotation = (t.rotation + 15) % 360),
            ),
          ],
        ),
        label('Chairs'),
        Wrap(
          spacing: HPSpace.sm,
          children: [
            TextButton(key: const Key('arrange-chairs'), onPressed: () => _change(() => t.chairs = null), child: const Text('Arrange from seats')),
            TextButton(
              key: const Key('add-chair'),
              onPressed: () => _change(() => t.chairs = [...t.effectiveChairs, HPChair(0, t.height / 2 + 30)]),
              child: const Text('Add chair'),
            ),
            TextButton(
              onPressed: t.effectiveChairs.isEmpty ? null : () => _change(() => t.chairs = [...t.effectiveChairs]..removeLast()),
              child: const Text('Remove chair'),
            ),
          ],
        ),
        Text('${t.effectiveChairs.length} chairs. Turn on "Move chairs" to drag them one by one.', style: HPType.body(p.muted).copyWith(fontSize: 12)),
      ],
    );
  }

  Widget _num(String key, String label, double value, double min, double max, ValueChanged<double> on) => TextFormField(
    key: Key(key),
    initialValue: '${value.round()}',
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: InputDecoration(labelText: label),
    onChanged: (s) {
      final v = double.tryParse(s);
      if (v != null && v >= min && v <= max) on(v);
    },
  );
}
