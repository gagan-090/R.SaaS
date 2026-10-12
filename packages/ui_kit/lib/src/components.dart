import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';
import 'tokens.dart';

bool _isDark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;

// ------------------------------------------------------------------ buttons

class _HPButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: enabled ? 1 : .5,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(HPRadius.button),
            boxShadow: glow && enabled ? [BoxShadow(color: fill.withValues(alpha: .45), blurRadius: 30, offset: const Offset(0, 10), spreadRadius: -10)] : null,
          ),
          child: Material(
            color: fill,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HPRadius.button), side: border == null ? BorderSide.none : BorderSide(color: border!, width: 1.5)),
            child: InkWell(
              borderRadius: BorderRadius.circular(HPRadius.button),
              onTap: enabled ? onPressed : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: HPSpace.x2),
                // scaleDown: a long label in a narrow slot shrinks instead of overflowing
                child: FittedBox(fit: BoxFit.scaleDown, child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (busy)
                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: textColor))
                  else if (icon != null)
                    Icon(icon, size: 20, color: textColor),
                  if (busy || icon != null) const SizedBox(width: HPSpace.sm),
                  Text(label, style: HPType.label(textColor).copyWith(fontSize: 16)),
                  if (trailing != null) ...[const SizedBox(width: HPSpace.sm), Icon(trailing, size: 20, color: textColor)],
                ])),
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
    final dark = _isDark(context);
    return _HPButton(label: label, onPressed: onPressed, icon: icon, trailing: trailing, busy: busy, height: height, glow: true,
        fill: dark ? HPColors.saffron : HPColors.wine, textColor: dark ? HPColors.onSaffron : HPColors.paper);
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
    final dark = _isDark(context);
    return _HPButton(label: label, onPressed: onPressed, icon: icon, height: height, fill: Colors.transparent,
        textColor: dark ? HPColors.ghee : HPColors.ink, border: dark ? HPColors.outline : HPColors.paperLine);
  }
}

class SuccessButton extends StatelessWidget {
  const SuccessButton({super.key, required this.label, required this.onPressed, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => _HPButton(label: label, onPressed: onPressed, icon: icon, fill: HPColors.cardamom, textColor: HPColors.onCardamom);
}

class DangerButton extends StatelessWidget {
  const DangerButton({super.key, required this.label, required this.onPressed, this.icon, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  @override
  Widget build(BuildContext context) => _HPButton(label: label, onPressed: onPressed, icon: icon, busy: busy, fill: HPColors.chili, textColor: HPColors.onChili);
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
    final dark = _isDark(context);
    final textColor = dark ? tone.tint : Color.lerp(tone.color, HPColors.ink, .45)!;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: HPSpace.md),
      decoration: BoxDecoration(color: tone.color.withValues(alpha: .14), borderRadius: BorderRadius.circular(HPRadius.pill)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) Icon(icon, size: 14, color: textColor) else Container(width: 8, height: 8, decoration: BoxDecoration(color: tone.color, shape: BoxShape.circle)),
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
          color: HPColors.chili.withValues(alpha: .16),
          padding: const EdgeInsets.symmetric(horizontal: HPSpace.lg, vertical: HPSpace.sm),
          child: Row(children: [
            const Icon(Icons.wifi_off_rounded, size: 18, color: HPColors.chili),
            const SizedBox(width: HPSpace.sm),
            Expanded(child: Text(pending > 0 ? '$message · $pending changes waiting' : message, style: HPType.label(_isDark(context) ? HPColors.ghee : HPColors.ink))),
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
            Icon(icon, size: 40, color: Theme.of(context).colorScheme.outline),
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
    final dark = _isDark(context);
    Widget key(String label, VoidCallback? onTap, {IconData? icon, String? semantics}) => Padding(
          padding: const EdgeInsets.all(HPSpace.xs),
          child: Semantics(
            button: true,
            label: semantics ?? label,
            excludeSemantics: true,
            child: Material(
              color: dark ? HPColors.emberRaised : HPColors.paperCard,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HPRadius.key), side: BorderSide(color: dark ? HPColors.clayLine : HPColors.paperLine)),
              child: InkWell(
                key: Key('key-$label'),
                borderRadius: BorderRadius.circular(HPRadius.key),
                onTap: onTap,
                child: SizedBox(
                  height: 58,
                  child: Center(child: icon != null ? Icon(icon, color: dark ? HPColors.ghee : HPColors.ink) : Text(label, style: HPType.titleCard(dark ? HPColors.ghee : HPColors.ink).copyWith(fontSize: 24))),
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
    final c = isVeg ? HPColors.vegGreen : HPColors.chili;
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
        decoration: BoxDecoration(color: _isDark(context) ? HPColors.emberRaised : HPColors.paper, borderRadius: BorderRadius.circular(HPRadius.pill)),
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
    final dark = _isDark(context);
    final fg = selected ? (dark ? HPColors.onSaffron : HPColors.paper) : (dark ? HPColors.ghee : HPColors.ink);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? (dark ? HPColors.saffron : HPColors.wine) : (dark ? HPColors.ember : HPColors.paperCard),
        shape: StadiumBorder(side: BorderSide(color: selected ? Colors.transparent : (dark ? HPColors.clayLine : HPColors.paperLine))),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
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
    );
  }
}

// ------------------------------------------------------------------ restaurant floor

enum TableState { free, ordering, served, billPrinted, reserved }

/// Table on the map: dashed outline when free; filled by state when occupied (always with words, not colour alone).
class TableTile extends StatelessWidget {
  const TableTile({super.key, required this.name, required this.seats, required this.state, this.runningTotal, this.minutesSeated, this.onTap});
  final String name;
  final int seats;
  final TableState state;
  final String? runningTotal;
  final int? minutesSeated;
  final VoidCallback? onTap;

  (Color, Color, String) get _style => switch (state) {
        TableState.free => (Colors.transparent, HPColors.husk, 'Free'),
        TableState.ordering => (HPColors.saffron, HPColors.onSaffron, 'Ordering'),
        TableState.served => (HPColors.cardamom, HPColors.onCardamom, 'Served'),
        TableState.billPrinted => (HPColors.chili, HPColors.onChili, 'Bill printed'),
        TableState.reserved => (HPColors.jamun, HPColors.onJamun, 'Reserved'),
      };

  @override
  Widget build(BuildContext context) {
    final (fill, fg, word) = _style;
    final free = state == TableState.free;
    final shape = seats >= 6 ? const Size(150, 96) : const Size(104, 104);
    return Semantics(
      button: true,
      label: 'Table $name, $word${free ? ', $seats seats' : ''}',
      child: GestureDetector(
        onTap: onTap,
        child: CustomPaint(
          painter: free ? _DashedRRect(color: HPColors.clayLine) : null,
          child: Container(
            width: shape.width,
            height: shape.height,
            padding: const EdgeInsets.all(HPSpace.md),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(seats <= 2 ? 52 : 18),
              boxShadow: free ? null : [BoxShadow(color: fill.withValues(alpha: .4), blurRadius: 24, spreadRadius: -8)],
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(name, style: HPType.titleCard(free ? HPColors.ghee : fg).copyWith(fontSize: 24, fontWeight: FontWeight.w700)),
              Text(free ? '$seats seats' : (runningTotal ?? word), style: HPType.body(free ? HPColors.husk : fg).copyWith(fontSize: 12)),
              if (!free && minutesSeated != null) Text('$minutesSeated min', style: HPType.body(fg).copyWith(fontSize: 11)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _DashedRRect extends CustomPainter {
  _DashedRRect({required this.color});
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(18)));
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 10) {
        canvas.drawPath(m.extractPath(d, d + 6), p);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRect o) => o.color != color;
}

/// Compact order summary card (table / takeaway, line count, total, status).
class OrderCard extends StatelessWidget {
  const OrderCard({super.key, required this.title, required this.subtitle, required this.total, required this.status, this.tone = HPTone.saffron, this.onTap});
  final String title;
  final String subtitle;
  final String total;
  final String status;
  final HPTone tone;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(HPRadius.card),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(HPSpace.lg),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: HPSpace.xs),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(total, style: HPType.titleCard(Theme.of(context).colorScheme.onSurface)),
                const SizedBox(height: HPSpace.xs),
                StatusChip(label: status, tone: tone),
              ]),
            ]),
          ),
        ),
      );
}
