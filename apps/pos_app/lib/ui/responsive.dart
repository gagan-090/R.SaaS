import 'dart:math' as math;
import 'dart:ui' show DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

/// Layout size classes (logical pixels). Decisions use the width actually available, so a split-screen window or a
/// resized desktop window gets the layout that fits it, not the one its device "should" have.
enum ScreenSize {
  compact(0), // < 360: small / older phones
  mobile(360), // 360–599
  largeMobile(600), // 600–767: large phones, small foldables unfolded
  tablet(768), // 768–1023
  smallDesktop(1024), // 1024–1279
  desktop(1280), // 1280–1599
  largeDesktop(1600); // 1600+

  const ScreenSize(this.minWidth);
  final double minWidth;

  static ScreenSize of(double width) => values.lastWhere((s) => width >= s.minWidth);

  bool operator >=(ScreenSize o) => index >= o.index;
  bool operator <(ScreenSize o) => index < o.index;
}

/// Shared breakpoints. Everything else derives from these, so no screen keeps its own magic numbers.
abstract final class Breakpoints {
  /// Below this the app is single-column with a bottom bar; at or above it, panes sit side by side with a rail.
  static const twoPane = 720.0;

  /// Room for a third column (kitchen board, bill receipt beside the keypad).
  static const threePane = 900.0;

  /// The navigation rail becomes a labelled sidebar.
  static const sidebar = 1280.0;

  /// Phones in landscape: too short for the tall rail and big headers.
  static const shortHeight = 480.0;
}

/// Readable widths for content that should not stretch across a wide monitor.
abstract final class ContentWidth {
  static const form = 560.0;
  static const list = 760.0;
  static const dashboard = 1100.0;
  static const board = 1600.0;
}

extension ResponsiveContext on BuildContext {
  Size get screen => MediaQuery.sizeOf(this);
  ScreenSize get screenSize => ScreenSize.of(screen.width);

  /// Single-column phone layout.
  bool get isNarrow => screen.width < Breakpoints.twoPane;

  /// Landscape phone / short window: compact chrome.
  bool get isShort => screen.height < Breakpoints.shortHeight;

  /// Side gutter that grows with the window: 12 on tiny phones, 16 on phones, 24 on tablets and up.
  double get gutter => gutterFor(screen.width);
}

double gutterFor(double width) => width < ScreenSize.mobile.minWidth ? HPSpace.md : (width < Breakpoints.twoPane ? HPSpace.lg : HPSpace.x2);

/// Columns for a card grid in [width]: as many [minTileWidth]-wide tiles as fit, between [min] and [max].
int columnsFor(double width, {required double minTileWidth, double spacing = HPSpace.md, int min = 1, int max = 6}) => ((width + spacing) / (minTileWidth + spacing)).floor().clamp(min, max);

/// Rebuilds with the size class of the space this widget actually gets (not the whole screen).
class ResponsiveBuilder extends StatelessWidget {
  const ResponsiveBuilder({super.key, required this.builder});
  final Widget Function(BuildContext context, ScreenSize size, BoxConstraints box) builder;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (c, box) => builder(c, ScreenSize.of(box.maxWidth), box));
}

/// Centres [child] and caps its width so lists and forms stay readable on wide monitors.
class CenteredContent extends StatelessWidget {
  const CenteredContent({super.key, required this.child, this.maxWidth = ContentWidth.list});
  final Widget child;
  final double maxWidth;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

/// Equal-width tiles that wrap into as many columns as fit (KPI cards, payment tiles, bill cards).
/// Each tile gets its natural height, so long text never clips.
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({super.key, required this.children, this.minTileWidth = 200, this.spacing = HPSpace.md, this.maxColumns = 6, this.minColumns = 1});
  final List<Widget> children;
  final double minTileWidth, spacing;
  final int maxColumns, minColumns;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (c, box) {
      final cols = columnsFor(box.maxWidth, minTileWidth: minTileWidth, spacing: spacing, min: minColumns, max: maxColumns);
      final w = ((box.maxWidth - spacing * (cols - 1)) / cols).floorToDouble();
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [for (final ch in children) SizedBox(width: w, child: ch)],
      );
    },
  );
}

/// A vertical fold or hinge that splits the window into a left and a right screen (book-style foldables,
/// dual-screen devices), or null. A flat-open fold with no physical gap does not split anything.
Rect? verticalHinge(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  for (final f in MediaQuery.displayFeaturesOf(context)) {
    final vertical = f.bounds.height >= size.height * .9 && f.bounds.width < size.width / 2;
    final splits = f.type == DisplayFeatureType.hinge || f.bounds.width > 0 || f.state == DisplayFeatureState.postureHalfOpened;
    if (vertical && splits && f.type != DisplayFeatureType.cutout) return f.bounds;
  }
  return null;
}

/// Two panes side by side: [start] takes the remaining width and [end] gets [endWidth]. On a foldable with a vertical
/// hinge the split follows the hinge instead, so nothing sits underneath it. Hinge alignment assumes the panes span
/// the full window width (true for the full-screen order and bill screens); otherwise the plain split is used.
class TwoPane extends StatelessWidget {
  const TwoPane({super.key, required this.start, required this.end, required this.endWidth, this.divider});
  final Widget start, end;
  final double endWidth;
  final Widget? divider;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (c, box) {
      final hinge = verticalHinge(c);
      final fullWidth = (box.maxWidth - MediaQuery.sizeOf(c).width).abs() < 1;
      if (hinge != null && fullWidth && hinge.left > 200 && box.maxWidth - hinge.right > 200) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: hinge.left, child: start),
            SizedBox(width: math.max(hinge.width, 1), child: divider),
            Expanded(child: end),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: start),
          ?divider,
          SizedBox(width: endWidth, child: end),
        ],
      );
    },
  );
}

/// Width of a side panel (order panel, payment panel): about 38% of the window, kept between [min] and [max].
double sidePanelWidth(double windowWidth, {double min = 320, double max = 460}) => (windowWidth * .38).clamp(min, max);
