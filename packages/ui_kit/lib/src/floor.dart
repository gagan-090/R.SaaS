import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'theme.dart';
import 'tokens.dart';

/// A pan that claims the pointer as soon as it lands, so dragging a table or chair moves it instead of panning
/// the zoomable floor underneath (which keeps every drag that starts on empty floor).
class EagerPanGestureRecognizer extends PanGestureRecognizer {
  EagerPanGestureRecognizer({super.debugOwner});
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// Wraps [child] so a drag starting on it is always its own (see [EagerPanGestureRecognizer]).
Widget eagerPan({Key? key, required Widget child, GestureDragStartCallback? onStart, GestureDragUpdateCallback? onUpdate, GestureDragEndCallback? onEnd}) =>
    RawGestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      gestures: {
        EagerPanGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerPanGestureRecognizer>(
          EagerPanGestureRecognizer.new,
          (r) => r
            ..dragStartBehavior = DragStartBehavior.down
            ..onStart = onStart
            ..onUpdate = onUpdate
            ..onEnd = onEnd,
        ),
      },
      child: child,
    );

/// A chair around a table: offset from the table centre in the table's own (unrotated) frame, and its facing.
@immutable
class HPChair {
  const HPChair(this.x, this.y, [this.rotation = 0]);
  final double x, y;
  final int rotation;
  Map<String, Object> toJson() => {'x': x.round(), 'y': y.round(), 'rotation': rotation};
  static HPChair fromJson(Map j) => HPChair((j['x'] as num).toDouble(), (j['y'] as num).toDouble(), (j['rotation'] as num?)?.toInt() ?? 0);
}

/// One table on a floor plan, in layout units (1 unit ≈ 1 cm). Position is the table centre.
class HPFloorTable {
  HPFloorTable({
    this.id, required this.name, required this.seats, required this.shape, required this.x, required this.y,
    required this.width, required this.height, this.rotation = 0, this.chairs, this.status = 'free',
  });
  String? id;
  String name;
  int seats;
  String shape; // round | square | rect
  double x, y, width, height;
  int rotation;
  List<HPChair>? chairs; // null = arranged from the seat count
  String status; // free | occupied | bill_printed | reserved | unavailable

  List<HPChair> get effectiveChairs => chairs ?? arrangeChairs(shape, width, height, seats);

  /// Chairs spread evenly: around a circle, or along the long sides of a rectangle (ends when needed).
  static List<HPChair> arrangeChairs(String shape, double w, double h, int seats) {
    const gap = 18.0;
    if (seats <= 0) return const [];
    if (shape == 'round') {
      final r = math.max(w, h) / 2 + gap;
      return [
        for (var i = 0; i < seats; i++)
          HPChair(r * math.cos(2 * math.pi * i / seats - math.pi / 2), r * math.sin(2 * math.pi * i / seats - math.pi / 2), (360 * i ~/ seats + 180) % 360),
      ];
    }
    final out = <HPChair>[];
    final ends = seats > 4 && seats.isOdd ? 1 : (seats > 6 ? 2 : 0);
    final sides = seats - ends;
    final top = (sides / 2).ceil(), bottom = sides - top;
    void row(int n, double y, int rot) {
      for (var i = 0; i < n; i++) {
        out.add(HPChair(-w / 2 + w * (i + 1) / (n + 1), y, rot));
      }
    }
    row(top, -h / 2 - gap, 180);
    row(bottom, h / 2 + gap, 0);
    if (ends >= 1) out.add(HPChair(-w / 2 - gap, 0, 90));
    if (ends >= 2) out.add(HPChair(w / 2 + gap, 0, 270));
    return out;
  }

  /// Axis-aligned bounds of the rotated table (no chairs) — used for overlap warnings.
  Rect get bounds {
    if (shape == 'round') return Rect.fromCircle(center: Offset(x, y), radius: math.max(width, height) / 2);
    final a = rotation * math.pi / 180;
    final hw = (width * math.cos(a).abs() + height * math.sin(a).abs()) / 2;
    final hh = (width * math.sin(a).abs() + height * math.cos(a).abs()) / 2;
    return Rect.fromLTRB(x - hw, y - hh, x + hw, y + hh);
  }

  /// Side of the square box that holds the table, its chairs and any rotation.
  double get box => math.max(width, height) + 2 * 46;

  HPFloorTable copy() => HPFloorTable(
        id: id, name: name, seats: seats, shape: shape, x: x, y: y, width: width, height: height, rotation: rotation,
        chairs: chairs == null ? null : [...chairs!], status: status,
      );

  Map<String, Object?> toJson() => {
        if (id != null) 'id': id, 'name': name, 'seats': seats, 'shape': shape, 'x': x.round(), 'y': y.round(),
        'width': width.round(), 'height': height.round(), 'rotation': rotation, 'chairs': chairs?.map((c) => c.toJson()).toList(),
      };

  /// From the cloud API (`x`, `y`) or the hub (`pos_x`, `pos_y`); [status] is the live state.
  static HPFloorTable fromJson(Map j, {String? status}) => HPFloorTable(
        id: j['id'] as String?,
        name: '${j['name']}',
        seats: (j['seats'] as num?)?.toInt() ?? 4,
        shape: '${j['shape'] ?? 'square'}',
        x: ((j['x'] ?? j['pos_x'] ?? 120) as num).toDouble(),
        y: ((j['y'] ?? j['pos_y'] ?? 120) as num).toDouble(),
        width: ((j['width'] ?? 80) as num).toDouble(),
        height: ((j['height'] ?? 80) as num).toDouble(),
        rotation: (j['rotation'] as num?)?.toInt() ?? 0,
        chairs: (j['chairs'] as List?)?.map((c) => HPChair.fromJson(c as Map)).toList(),
        status: status ?? '${j['status'] ?? 'free'}',
      );
}

/// Overlapping pairs (by name) — a warning, not an error.
List<(String, String)> floorOverlaps(List<HPFloorTable> ts) => [
      for (var i = 0; i < ts.length; i++)
        for (var j = i + 1; j < ts.length; j++)
          if (ts[i].bounds.overlaps(ts[j].bounds)) (ts[i].name, ts[j].name),
    ];

/// Colour and label of a table state on the plan. Colour is always paired with a word in the legend.
(Color fill, Color border, String label) floorStateStyle(HPPalette p, String status) => switch (status) {
      'occupied' => (HPColors.amber.withValues(alpha: .28), HPColors.amber, 'Occupied'),
      'bill_printed' || 'billing' => (p.pending.withValues(alpha: .22), p.pending, 'Bill printed'),
      'reserved' => (p.success.withValues(alpha: .12), p.success, 'Reserved'),
      'unavailable' => (p.raised, p.faint, 'Out of use'),
      _ => (p.surface, p.outline, 'Available'),
    };

/// Draws one table with its chairs, rotated, inside a square box of [HPFloorTable.box] units.
class FloorTableView extends StatelessWidget {
  const FloorTableView({super.key, required this.table, this.selected = false, this.warn = false, this.onChairDrag, this.highlightChairs = false});
  final HPFloorTable table;
  final bool selected, warn, highlightChairs;
  /// Editing: drag a chair (index, delta in table frame).
  final void Function(int index, Offset delta)? onChairDrag;

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final (fill, border, _) = floorStateStyle(p, table.status);
    final s = table.box;
    final chairs = table.effectiveChairs;
    final angle = table.rotation * math.pi / 180;
    final edge = warn ? p.danger : (selected ? p.accent : border);
    return SizedBox(
      width: s,
      height: s,
      child: Transform.rotate(
        angle: angle,
        child: Stack(clipBehavior: Clip.none, children: [
          for (final (i, c) in chairs.indexed)
            Positioned(
              left: s / 2 + c.x - 11,
              top: s / 2 + c.y - 11,
              child: _maybePan(
                onChairDrag == null
                    ? null
                    : (d) {
                        // Positioned inside the rotated frame already: the delta arrives in table coordinates
                        onChairDrag!(i, d.delta);
                      },
                Container(
                  key: Key('chair-${table.name}-$i'),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: highlightChairs ? p.accent.withValues(alpha: .25) : p.raised,
                    border: Border.all(color: highlightChairs ? p.accent : p.outline),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(Icons.chair_rounded, size: 18, color: p.muted),
                ),
              ),
            ),
          Center(
            child: Container(
              width: table.width,
              height: table.height,
              decoration: BoxDecoration(
                color: fill,
                shape: table.shape == 'round' ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: table.shape == 'round' ? null : BorderRadius.circular(10),
                border: Border.all(color: edge, width: selected || warn ? 3 : 1.5),
              ),
              alignment: Alignment.center,
              // the label stays upright whatever the table's rotation
              child: Transform.rotate(
                angle: -angle,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.table_restaurant_rounded, size: 18, color: edge),
                      Text(table.name, style: HPType.titleCard(p.text).copyWith(fontSize: 18)),
                      Text('${table.seats} seats', style: HPType.body(p.muted).copyWith(fontSize: 11)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

Widget _maybePan(GestureDragUpdateCallback? onUpdate, Widget child) => onUpdate == null ? child : eagerPan(onUpdate: onUpdate, child: child);

/// Faint grid behind the plan ([step] layout units).
class FloorGridPainter extends CustomPainter {
  FloorGridPainter(this.color, {this.step = 50});
  final Color color;
  final double step;
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(FloorGridPainter old) => old.color != color || old.step != step;
}

/// Legend: colour + word for each state shown on the plan.
class FloorLegend extends StatelessWidget {
  const FloorLegend({super.key});
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return Wrap(spacing: HPSpace.md, runSpacing: HPSpace.xs, children: [
      for (final s in ['free', 'occupied', 'bill_printed', 'reserved', 'unavailable'])
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 14, height: 14, decoration: BoxDecoration(color: floorStateStyle(p, s).$1, border: Border.all(color: floorStateStyle(p, s).$2, width: 2), borderRadius: BorderRadius.circular(4))),
          const SizedBox(width: 4),
          Text(floorStateStyle(p, s).$3, style: HPType.body(p.muted).copyWith(fontSize: 12)),
        ]),
    ]);
  }
}

/// Read-only floor plan (POS and the console's live view): zoom and pan, tap a table.
class FloorPlanView extends StatefulWidget {
  const FloorPlanView({super.key, required this.width, required this.height, required this.tables, this.onTap, this.controller});
  final double width, height;
  final List<HPFloorTable> tables;
  final ValueChanged<HPFloorTable>? onTap;
  final TransformationController? controller;
  @override
  State<FloorPlanView> createState() => _FloorPlanViewState();
}

class _FloorPlanViewState extends State<FloorPlanView> {
  late final TransformationController _tc = widget.controller ?? TransformationController();
  Size? _fitted;

  /// Fits the whole floor into the view the first time it is laid out.
  void _fit(Size view) {
    if (_fitted == view) return;
    _fitted = view;
    final k = math.min(view.width / widget.width, view.height / widget.height).clamp(.2, 2.0);
    _tc.value = Matrix4.identity()..scaleByDouble(k, k, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return LayoutBuilder(builder: (c, box) {
      _fit(box.biggest);
      return ClipRect(
        child: InteractiveViewer(
          transformationController: _tc,
          constrained: false,
          minScale: .2,
          maxScale: 3,
          boundaryMargin: const EdgeInsets.all(400),
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: Stack(children: [
              Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(color: p.ground, border: Border.all(color: p.line)), child: CustomPaint(painter: FloorGridPainter(p.line.withValues(alpha: .6))))),
              for (final t in widget.tables)
                Positioned(
                  left: t.x - t.box / 2,
                  top: t.y - t.box / 2,
                  child: GestureDetector(
                    key: Key('plan-table-${t.name}'),
                    onTap: widget.onTap == null ? null : () => widget.onTap!(t),
                    child: FloorTableView(table: t),
                  ),
                ),
            ]),
          ),
        ),
      );
    });
  }
}
