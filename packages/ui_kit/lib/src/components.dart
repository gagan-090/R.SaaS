import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';
import 'tokens.dart';

// ------------------------------------------------------------------ buttons

class _HPButton extends StatefulWidget {
  const _HPButton({required this.label, required this.onPressed, required this.fill, required this.textColor, this.icon, this.trailing, this.border, this.glow = false, this.height = 56, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final Color fill;
  final Color textColor;
  final IconData? icon;
  final IconData? trailing;
  final Color? border;
  final bool glow;
  final double height;
  final bool busy;

  @override
  State<_HPButton> createState() => _HPButtonState();
}

class _HPButtonState extends State<_HPButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final enabled = w.onPressed != null && !w.busy;
    return Semantics(
      button: true,
      enabled: enabled,
      label: w.label,
      excludeSemantics: true,
      child: AnimatedScale(
        // a 2% press-in reads as "pressed" without bouncing (STYLE.md §9)
        scale: _down && enabled ? .98 : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: enabled || w.busy ? 1 : .45,
          child: Container(
            height: w.height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(HPRadius.button),
              boxShadow: w.glow && enabled ? [BoxShadow(color: w.fill.withValues(alpha: .40), blurRadius: 28, offset: const Offset(0, 10), spreadRadius: -12)] : null,
            ),
            child: Material(
              color: w.fill,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HPRadius.button), side: w.border == null ? BorderSide.none : BorderSide(color: w.border!, width: 1.5)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: enabled
                    ? () {
                        HapticFeedback.selectionClick();
                        w.onPressed!();
                      }
                    : null,
                onHighlightChanged: (v) => setState(() => _down = v),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HPSpace.x2),
                  // scaleDown: a long label in a narrow slot shrinks instead of overflowing
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                        if (w.busy)
                          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: w.textColor))
                        else if (w.icon != null)
                          Icon(w.icon, size: 20, color: w.textColor),
                        if (w.busy || w.icon != null) const SizedBox(width: HPSpace.sm),
                        Text(w.label, style: HPType.label(w.textColor).copyWith(fontSize: 16)),
                        if (w.trailing != null) ...[const SizedBox(width: HPSpace.sm), Icon(w.trailing, size: 20, color: w.textColor)],
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One confident action per screen region: saffron on dark, wine on light, with a soft glow.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.icon, this.trailing, this.busy = false, this.height = 60});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final IconData? trailing;
  final bool busy;
  final double height;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return _HPButton(label: label, onPressed: onPressed, icon: icon, trailing: trailing, busy: busy, height: height, glow: true, fill: p.accent, textColor: p.onAccent);
  }
}

class SecondaryButton extends StatelessWidget {
  const SecondaryButton({super.key, required this.label, required this.onPressed, this.icon, this.height = 56});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return _HPButton(label: label, onPressed: onPressed, icon: icon, height: height, fill: Colors.transparent, textColor: p.text, border: p.outline);
  }
}

class SuccessButton extends StatelessWidget {
  const SuccessButton({super.key, required this.label, required this.onPressed, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  @override
  Widget build(BuildContext context) =>
      _HPButton(label: label, onPressed: onPressed, icon: icon, fill: context.hp.success, textColor: context.hp.isDark ? HPColors.onCardamom : HPColors.paperCard);
}

class DangerButton extends StatelessWidget {
  const DangerButton({super.key, required this.label, required this.onPressed, this.icon, this.busy = false, this.height = 56});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final double height;
  @override
  Widget build(BuildContext context) => _HPButton(label: label, onPressed: onPressed, icon: icon, busy: busy, height: height, fill: context.hp.danger, textColor: HPColors.onChili);
}

// ------------------------------------------------------------------ status

/// 36-tall tinted pill with a dot and words (hub online, sync counts, restaurant status…).
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, this.tone = HPTone.neutral, this.icon});
  final String label;
  final HPTone tone;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final c = p.tone(tone);
    final textColor = p.isDark ? Color.lerp(c, Colors.white, .35)! : c;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: HPSpace.md),
      decoration: BoxDecoration(color: c.withValues(alpha: p.isDark ? .16 : .12), borderRadius: BorderRadius.circular(HPRadius.pill)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) Icon(icon, size: 14, color: textColor) else Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: HPSpace.sm),
        Flexible(child: Text(label, style: HPType.label(textColor).copyWith(fontSize: 13), overflow: TextOverflow.ellipsis, maxLines: 1)),
      ]),
    );
  }
}

/// Full-width banner shown while the hub or cloud is unreachable.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, required this.message, this.pending = 0, this.onRetry});
  final String message;
  final int pending;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Container(
          width: double.infinity,
          color: context.hp.danger.withValues(alpha: .14),
          padding: const EdgeInsets.symmetric(horizontal: HPSpace.lg, vertical: HPSpace.sm),
          child: Row(children: [
            Icon(Icons.wifi_off_rounded, size: 18, color: context.hp.danger),
            const SizedBox(width: HPSpace.sm),
            Expanded(child: Text(pending > 0 ? '$message · $pending changes waiting' : message, style: HPType.label(context.hp.text))),
            if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
          ]),
        ),
      );
}

// ------------------------------------------------------------------ states

class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.label = 'Loading…'});
  final String label;
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(height: HPSpace.md),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.message, this.icon = Icons.restaurant_menu_rounded, this.action});
  final String title;
  final String? message;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(HPSpace.x3),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(color: context.hp.raised, shape: BoxShape.circle),
              child: Icon(icon, size: 34, color: context.hp.muted),
            ),
            const SizedBox(height: HPSpace.md),
            Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
            if (message != null) ...[const SizedBox(height: HPSpace.sm), Text(message!, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center)],
            if (action != null) ...[const SizedBox(height: HPSpace.lg), action!],
          ]),
        ),
      );
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.error_outline_rounded,
        title: 'Something went wrong',
        message: message,
        action: onRetry == null ? null : SecondaryButton(label: 'Try again', icon: Icons.refresh_rounded, onPressed: onRetry),
      );
}

// ------------------------------------------------------------------ dialogs

/// Rounded dialog with a title, body and actions.
class HPDialog extends StatelessWidget {
  const HPDialog({super.key, required this.title, required this.child, this.actions = const []});
  final String title;
  final Widget child;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(HPSpace.x2),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 24)),
              const SizedBox(height: HPSpace.lg),
              Flexible(child: SingleChildScrollView(child: child)),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: HPSpace.x2),
                Wrap(alignment: WrapAlignment.end, spacing: HPSpace.md, runSpacing: HPSpace.sm, children: actions),
              ],
            ]),
          ),
        ),
      );
}

/// Every destructive action asks for a reason (≥ 3 characters) before it can be confirmed.
class ReasonDialog extends StatefulWidget {
  const ReasonDialog({super.key, required this.title, required this.confirmLabel, this.message, this.destructive = true});
  final String title;
  final String confirmLabel;
  final String? message;
  final bool destructive;

  /// Returns the trimmed reason, or null if cancelled.
  static Future<String?> show(BuildContext context, {required String title, required String confirmLabel, String? message, bool destructive = true}) =>
      showDialog<String>(context: context, builder: (_) => ReasonDialog(title: title, confirmLabel: confirmLabel, message: message, destructive: destructive));

  @override
  State<ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<ReasonDialog> {
  final _ctrl = TextEditingController();
  bool get _valid => _ctrl.text.trim().length >= 3;
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HPDialog(
        title: widget.title,
        actions: [
          SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(context)),
          widget.destructive
              ? DangerButton(label: widget.confirmLabel, onPressed: _valid ? () => Navigator.pop(context, _ctrl.text.trim()) : null)
              : PrimaryButton(label: widget.confirmLabel, height: 56, onPressed: _valid ? () => Navigator.pop(context, _ctrl.text.trim()) : null),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.message != null) ...[Text(widget.message!), const SizedBox(height: HPSpace.lg)],
          TextField(
            key: const Key('reason-field'),
            controller: _ctrl,
            autofocus: true,
            maxLines: 3,
            maxLength: 500,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Reason (required)', helperText: 'Recorded in the audit log'),
          ),
        ]),
      );
}

// ------------------------------------------------------------------ keypad

/// 3×4 keypad with Fraunces digits and optional quick-amount chips (cash, PIN entry).
class NumericKeypad extends StatelessWidget {
  const NumericKeypad({super.key, required this.onKey, this.onBackspace, this.onClear, this.quickAmounts = const [], this.onQuickAmount});
  final ValueChanged<String> onKey;
  final VoidCallback? onBackspace;
  final VoidCallback? onClear;
  final List<(String label, int value)> quickAmounts;
  final ValueChanged<int>? onQuickAmount;

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    Widget key(String label, VoidCallback? onTap, {IconData? icon, String? semantics}) => Padding(
          padding: const EdgeInsets.all(HPSpace.xs),
          child: Semantics(
            button: true,
            label: semantics ?? label,
            excludeSemantics: true,
            child: Material(
              color: p.raised,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HPRadius.key), side: BorderSide(color: p.line)),
              child: InkWell(
                key: Key('key-$label'),
                borderRadius: BorderRadius.circular(HPRadius.key),
                onTap: onTap == null
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        onTap();
                      },
                child: SizedBox(
                  height: 58,
                  child: Center(child: icon != null ? Icon(icon, color: p.text) : Text(label, style: HPType.titleCard(p.text).copyWith(fontSize: 24))),
                ),
              ),
            ),
          ),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (quickAmounts.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: HPSpace.sm),
          child: Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
            for (final q in quickAmounts) ActionChip(label: Text(q.$1), onPressed: onQuickAmount == null ? null : () => onQuickAmount!(q.$2)),
          ]),
        ),
      for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']])
        Row(children: [for (final d in row) Expanded(child: key(d, () => onKey(d)))]),
      Row(children: [
        Expanded(child: key('C', onClear, semantics: 'Clear')),
        Expanded(child: key('0', () => onKey('0'))),
        Expanded(child: key('⌫', onBackspace, icon: Icons.backspace_outlined, semantics: 'Backspace')),
      ]),
    ]);
  }
}

// ------------------------------------------------------------------ food

/// Signature plate illustration (STYLE.md §6): rim, well, food, topping, garnish dots, shine.
class PlateIcon extends StatelessWidget {
  const PlateIcon({super.key, required this.base, required this.sauce, required this.garnish, this.size = 64});
  final Color base;
  final Color sauce;
  final Color garnish;
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox(width: size, height: size, child: CustomPaint(painter: _PlatePainter(base, sauce, garnish)));
}

class _PlatePainter extends CustomPainter {
  _PlatePainter(this.base, this.sauce, this.garnish);
  final Color base, sauce, garnish;
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 96; // designed on a 96 grid, rim radius 44
    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(c + Offset(0, 3 * s), 44 * s, Paint()..color = Colors.black.withValues(alpha: .35));
    canvas.drawCircle(c, 44 * s, Paint()..color = const Color(0xFFF3E9DC));
    canvas.drawCircle(c, 36 * s, Paint()..color = const Color(0xFFE6D8C4));
    canvas.drawCircle(c, 29 * s, Paint()..color = base);
    canvas.drawCircle(c + Offset(-6 * s, -6 * s), 13 * s, Paint()..color = sauce.withValues(alpha: .9));
    for (final (dx, dy, r) in [(10.0, 8.0, 4.0), (-12.0, 12.0, 3.0), (14.0, -10.0, 3.5)]) {
      canvas.drawCircle(c + Offset(dx * s, dy * s), r * s, Paint()..color = garnish);
    }
    canvas.save();
    canvas.translate(c.dx - 22 * s, c.dy - 24 * s);
    canvas.rotate(-math.pi / 5);
    canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: 22 * s, height: 9 * s), Paint()..color = Colors.white.withValues(alpha: .28));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PlatePainter o) => o.base != base || o.sauce != sauce || o.garnish != garnish;
}

/// Indian veg / non-veg mark: square outline with a centred dot.
class VegMark extends StatelessWidget {
  const VegMark({super.key, required this.isVeg, this.size = 16});
  final bool isVeg;
  final double size;
  @override
  Widget build(BuildContext context) {
    final c = isVeg ? HPColors.vegGreen : context.hp.danger;
    return Semantics(
      label: isVeg ? 'Vegetarian' : 'Non-vegetarian',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(border: Border.all(color: c, width: 2), borderRadius: BorderRadius.circular(3)),
        child: Center(child: Container(width: size * .45, height: size * .45, decoration: BoxDecoration(color: c, shape: BoxShape.circle))),
      ),
    );
  }
}

class QtyStepper extends StatelessWidget {
  const QtyStepper({super.key, required this.qty, required this.onChanged, this.min = 1});
  final int qty;
  final int min;
  final ValueChanged<int>? onChanged;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: context.hp.raised, borderRadius: BorderRadius.circular(HPRadius.pill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: 'Decrease', icon: const Icon(Icons.remove_rounded), onPressed: onChanged == null || qty <= min ? null : () => onChanged!(qty - 1)),
          Text('$qty', style: HPType.label().copyWith(fontSize: 17)),
          IconButton(tooltip: 'Increase', icon: const Icon(Icons.add_rounded), onPressed: onChanged == null ? null : () => onChanged!(qty + 1)),
        ]),
      );
}

class CategoryChip extends StatelessWidget {
  const CategoryChip({super.key, required this.label, required this.selected, required this.onTap, this.count});
  final String label;
  final bool selected;
  final int? count;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final fg = selected ? p.onAccent : p.text;
    return Semantics(
      selected: selected,
      button: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        decoration: ShapeDecoration(color: selected ? p.accent : p.surface, shape: StadiumBorder(side: BorderSide(color: selected ? Colors.transparent : p.line))),
        child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: HPSpace.lg),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(label, style: HPType.label(fg)),
                if (count != null) ...[const SizedBox(width: 6), Text('$count', style: HPType.body(fg.withValues(alpha: .7)))],
              ]),
            ),
          ),
        ),
      ),
      ),
    );
  }
}

// ------------------------------------------------------------------ restaurant floor

enum TableState { free, ordering, served, billPrinted, reserved }

/// Table on the map: dashed outline when free; filled by state when occupied (always with words, not colour alone).
/// With [expand] it fills its grid cell, so a floor of tables lines up evenly on any screen.
class TableTile extends StatelessWidget {
  const TableTile({super.key, required this.name, required this.seats, required this.state, this.runningTotal, this.minutesSeated, this.caption, this.onTap, this.expand = false});
  final String name;
  final int seats;
  final TableState state;
  final String? runningTotal;
  final int? minutesSeated;

  /// Extra line on an occupied table, e.g. the waiter's name.
  final String? caption;
  final VoidCallback? onTap;
  final bool expand;

  (Color, Color, String) _style(HPPalette p) => switch (state) {
        TableState.free => (Colors.transparent, p.muted, 'Free'),
        TableState.ordering => (HPColors.amber, HPColors.onAmber, 'Ordering'),
        TableState.served => (p.success, p.isDark ? HPColors.onCardamom : HPColors.paperCard, 'Served'),
        TableState.billPrinted => (p.danger, HPColors.onChili, 'Bill printed'),
        TableState.reserved => (p.pending, p.isDark ? HPColors.onJamun : HPColors.paperCard, 'Reserved'),
      };

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final (fill, fg, word) = _style(p);
    final free = state == TableState.free;
    final radius = BorderRadius.circular(expand ? HPRadius.card : (seats <= 2 ? 52 : 18));
    final body = AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      width: expand ? null : (seats >= 6 ? 150 : 104),
      height: expand ? null : (seats >= 6 ? 96 : 104),
      padding: const EdgeInsets.all(HPSpace.md),
      decoration: BoxDecoration(
        color: free ? p.surface.withValues(alpha: p.isDark ? .35 : .7) : fill,
        borderRadius: radius,
        boxShadow: free ? null : [BoxShadow(color: fill.withValues(alpha: .35), blurRadius: 22, offset: const Offset(0, 8), spreadRadius: -10)],
      ),
      alignment: Alignment.center,
      child: FittedBox(fit: BoxFit.scaleDown, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
        FittedBox(fit: BoxFit.scaleDown, child: Text(name, style: HPType.titleCard(free ? p.text : fg).copyWith(fontSize: 26, fontWeight: FontWeight.w700))),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(free ? '$seats seats' : (runningTotal ?? word), style: HPType.label(free ? p.muted : fg).copyWith(fontSize: 13)),
        ),
        if (!free && (minutesSeated != null || caption != null))
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text([if (minutesSeated != null) '$minutesSeated min', ?caption].join(' · '), style: HPType.body(fg.withValues(alpha: .85)).copyWith(fontSize: 11)),
          ),
      ])),
    );
    return Semantics(
      button: true,
      label: 'Table $name, $word${free ? ', $seats seats' : ''}',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
          child: CustomPaint(foregroundPainter: free ? _DashedRRect(color: p.outline, radius: radius.topLeft.x) : null, child: body),
        ),
      ),
    );
  }
}

class _DashedRRect extends CustomPainter {
  _DashedRRect({required this.color, this.radius = 18});
  final Color color;
  final double radius;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius((Offset.zero & size).deflate(.75), Radius.circular(radius)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 10) {
        canvas.drawPath(m.extractPath(d, d + 6), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRect o) => o.color != color || o.radius != radius;
}

/// Compact order summary card (table / takeaway, line count, total, status).
class OrderCard extends StatelessWidget {
  const OrderCard({super.key, required this.title, required this.subtitle, required this.total, required this.status, this.tone = HPTone.saffron, this.onTap, this.leading});
  final String title;
  final String subtitle;
  final String total;
  final String status;
  final HPTone tone;
  final VoidCallback? onTap;
  final Widget? leading;
  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(HPSpace.lg),
            child: Row(children: [
              if (leading != null) ...[leading!, const SizedBox(width: HPSpace.md)],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: Theme.of(context).textTheme.titleLarge, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: HPSpace.xs),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                ]),
              ),
              const SizedBox(width: HPSpace.sm),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(total, style: HPType.titleCard(context.hp.text)),
                const SizedBox(height: HPSpace.xs),
                StatusChip(label: status, tone: tone),
              ]),
            ]),
          ),
        ),
      );
}

// ------------------------------------------------------------------ layout & data display

/// Overline section label with an optional trailing action ("TAKEAWAY · 3   View all").
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.padding = const EdgeInsets.only(bottom: HPSpace.sm)});
  final String title;
  final Widget? trailing;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(children: [
          Expanded(child: Text(title.toUpperCase(), style: HPType.overline(context.hp.muted))),
          ?trailing,
        ]),
      );
}

/// KPI card for dashboards: label, big Fraunces value, optional caption and icon.
class KpiCard extends StatelessWidget {
  const KpiCard({super.key, required this.label, required this.value, this.caption, this.icon, this.tone = HPTone.neutral});
  final String label;
  final String value;
  final String? caption;
  final IconData? icon;
  final HPTone tone;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HPSpace.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: Text(label.toUpperCase(), style: HPType.overline(p.muted), overflow: TextOverflow.ellipsis)),
            if (icon != null)
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: p.tone(tone).withValues(alpha: .14), borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 18, color: p.tone(tone)),
              ),
          ]),
          const SizedBox(height: HPSpace.sm),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: HPType.displayTotal(p.text).copyWith(fontSize: 32))),
          if (caption != null) ...[const SizedBox(height: 2), Text(caption!, style: HPType.body(p.muted), overflow: TextOverflow.ellipsis)],
        ]),
      ),
    );
  }
}

/// Rounded search field with a clear button.
class HPSearchField extends StatefulWidget {
  const HPSearchField({super.key, required this.onChanged, this.hint = 'Search', this.controller});
  final ValueChanged<String> onChanged;
  final String hint;
  final TextEditingController? controller;
  @override
  State<HPSearchField> createState() => _HPSearchFieldState();
}

class _HPSearchFieldState extends State<HPSearchField> {
  late final TextEditingController _c = widget.controller ?? TextEditingController();
  @override
  Widget build(BuildContext context) => TextField(
        controller: _c,
        onChanged: (v) {
          setState(() {});
          widget.onChanged(v);
        },
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: widget.hint,
          prefixIcon: const Icon(Icons.search_rounded),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: HPSpace.md),
          suffixIcon: _c.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    _c.clear();
                    setState(() {});
                    widget.onChanged('');
                  }),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(HPRadius.pill), borderSide: BorderSide(color: context.hp.line)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(HPRadius.pill), borderSide: BorderSide(color: context.hp.line)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(HPRadius.pill), borderSide: BorderSide(color: context.hp.accent, width: 2)),
        ),
      );
}

/// Shimmering placeholder block shown while content loads (no blocking spinners).
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({super.key, this.width, this.height = 16, this.radius = 10});
  final double? width;
  final double height;
  final double radius;
  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);
  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return AnimatedBuilder(
      animation: _a,
      builder: (_, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(color: Color.lerp(p.raised, p.line, _a.value * .6), borderRadius: BorderRadius.circular(widget.radius)),
      ),
    );
  }
}

/// Grid of skeleton cards — the loading state for menus, tables and lists.
class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({super.key, this.count = 8, this.maxExtent = 200, this.aspect = 1});
  final int count;
  final double maxExtent;
  final double aspect;
  @override
  Widget build(BuildContext context) => GridView.extent(
        padding: const EdgeInsets.all(HPSpace.lg),
        maxCrossAxisExtent: maxExtent,
        mainAxisSpacing: HPSpace.md,
        crossAxisSpacing: HPSpace.md,
        childAspectRatio: aspect,
        physics: const NeverScrollableScrollPhysics(),
        children: [for (var i = 0; i < count; i++) const SkeletonBox(height: double.infinity, radius: HPRadius.card)],
      );
}

/// Small count badge (cart quantity, pending tickets).
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key, this.color});
  final int count;
  final Color? color;
  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
        child: count <= 0
            ? const SizedBox.shrink()
            : Container(
                key: ValueKey(count),
                constraints: const BoxConstraints(minWidth: 22),
                height: 22,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(color: color ?? context.hp.accent, borderRadius: BorderRadius.circular(HPRadius.pill)),
                alignment: Alignment.center,
                child: Text('$count', style: HPType.label(context.hp.onAccent).copyWith(fontSize: 12)),
              ),
      );
}

/// Dish photo cropped into the plate circle (STYLE.md §6), or the illustrated plate when there is no photo.
class DishImage extends StatelessWidget {
  const DishImage({super.key, this.image, required this.base, required this.sauce, required this.garnish, this.size = 64});
  final ImageProvider? image;
  final Color base, sauce, garnish;
  final double size;
  @override
  Widget build(BuildContext context) {
    final plate = PlateIcon(base: base, sauce: sauce, garnish: garnish, size: size);
    if (image == null) return plate;
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: Image(
          image: image!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          frameBuilder: (c, child, frame, sync) => sync || frame != null ? child : plate,
          errorBuilder: (_, _, _) => plate,
        ),
      ),
    );
  }
}

/// Menu dish card (STYLE.md §7 DishCard): plate or photo, veg mark, name, price, and a quantity badge once added.
class DishCard extends StatelessWidget {
  const DishCard({
    super.key,
    required this.name,
    required this.price,
    required this.isVeg,
    required this.base,
    required this.sauce,
    required this.garnish,
    this.image,
    this.qty = 0,
    this.available = true,
    this.onTap,
  });
  final String name;
  final String price;
  final bool isVeg;
  final Color base, sauce, garnish;
  final ImageProvider? image;
  final int qty;
  final bool available;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final added = qty > 0;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: available ? 1 : .45,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(HPRadius.card),
          border: Border.all(color: added ? p.accent : p.line, width: added ? 1.5 : 1),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(HPRadius.card),
            onTap: available && onTap != null
                ? () {
                    HapticFeedback.selectionClick();
                    onTap!();
                  }
                : null,
            child: LayoutBuilder(builder: (c, box) {
              final small = box.maxWidth < 170;
              return Padding(
                padding: EdgeInsets.all(small ? HPSpace.sm + 2 : HPSpace.md),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    DishImage(image: image, base: base, sauce: sauce, garnish: garnish, size: small ? 48 : 60),
                    const Spacer(),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      VegMark(isVeg: isVeg),
                      const SizedBox(height: HPSpace.sm),
                      CountBadge(qty),
                    ]),
                  ]),
                  const Spacer(),
                  Text(name, style: HPType.titleCard(p.text).copyWith(fontSize: small ? 15 : 17, height: 1.15), maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Row(children: [
                    Expanded(child: Text(available ? price : 'Sold out', style: HPType.label(available ? p.muted : p.danger), overflow: TextOverflow.ellipsis)),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: small ? 30 : 34,
                      height: small ? 30 : 34,
                      decoration: BoxDecoration(color: added ? p.accent : p.raised, shape: BoxShape.circle),
                      child: Icon(Icons.add_rounded, size: small ? 18 : 20, color: added ? p.onAccent : p.text),
                    ),
                  ]),
                ]),
              );
            }),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ appearance

/// Appearance picker: follow the device (default), always light, or always dark.
class ThemeModeSwitch extends StatelessWidget {
  const ThemeModeSwitch({super.key, required this.value, required this.onChanged, this.compact = false});
  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  /// Icons only (sidebars, top bars).
  final bool compact;

  @override
  Widget build(BuildContext context) => SegmentedButton<ThemeMode>(
        key: const Key('theme-mode'),
        showSelectedIcon: false,
        style: compact ? const ButtonStyle(visualDensity: VisualDensity.compact, minimumSize: WidgetStatePropertyAll(Size(0, 40))) : null,
        segments: [
          ButtonSegment(value: ThemeMode.system, icon: const Icon(Icons.brightness_auto_rounded, size: 18), label: compact ? null : const Text('Auto'), tooltip: 'Follow this device'),
          ButtonSegment(value: ThemeMode.light, icon: const Icon(Icons.light_mode_rounded, size: 18), label: compact ? null : const Text('Light'), tooltip: 'Light'),
          ButtonSegment(value: ThemeMode.dark, icon: const Icon(Icons.dark_mode_rounded, size: 18), label: compact ? null : const Text('Dark'), tooltip: 'Dark'),
        ],
        selected: {value},
        onSelectionChanged: (v) {
          HapticFeedback.selectionClick();
          onChanged(v.first);
        },
      );
}
