import 'package:flutter/material.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../api/api_client.dart';

/// Shows an API error (or any error) as a snackbar.
void showError(BuildContext context, Object e) {
  final msg = e is ApiException ? e.message : 'Unexpected error: $e';
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(children: [const Icon(Icons.error_outline_rounded, color: HPColors.onChili), const SizedBox(width: HPSpace.sm), Expanded(child: Text(msg, style: HPType.label(HPColors.onChili)))]),
      backgroundColor: context.hp.danger,
    ));
}

void showDone(BuildContext context, String msg) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(
    content: Row(children: [Icon(Icons.check_circle_rounded, color: context.hp.isDark ? context.hp.success : context.hp.ground), const SizedBox(width: HPSpace.sm), Expanded(child: Text(msg))]),
    duration: const Duration(seconds: 2),
  ));

/// Narrow = phone browser: one column, drawer navigation, 16 px gutters.
bool isNarrowWeb(BuildContext c) => MediaQuery.sizeOf(c).width < 900;

/// Short = little height to spare (a phone in landscape, a small split-screen window): pages must scroll as one
/// piece instead of pinning headers and filters above a list that would be left with no room.
bool isShortScreen(BuildContext c) => MediaQuery.sizeOf(c).height < 600;

/// Phone-style layout: narrow OR short. One scrolling column, tabs instead of side-by-side panels.
bool compactLayout(BuildContext c) => isNarrowWeb(c) || isShortScreen(c);

/// "✓ Tables, ✓ Dine-in orders, ✓ Takeaway" — a feature list that wraps like a sentence instead of one per line.
class InlineChecks extends StatelessWidget {
  const InlineChecks(this.labels, {super.key, this.fontSize = 13});
  final List<String> labels;
  final double fontSize;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 3),
                child: Icon(Icons.check_rounded, size: fontSize + 2, color: p.success),
              ),
            ),
            TextSpan(text: labels[i]),
            if (i < labels.length - 1) const TextSpan(text: ',  '),
          ],
        ],
      ),
      style: HPType.body(p.text).copyWith(fontSize: fontSize, height: 1.6),
    );
  }
}

/// Tabs for phone layouts: a row of choice chips that scrolls sideways; the page shows the selected section below.
class ChipTabs<T> extends StatelessWidget {
  const ChipTabs({super.key, required this.tabs, required this.value, required this.onChanged});
  final List<(T, String, IconData)> tabs;
  final T value;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final (v, label, icon) in tabs)
          Padding(
            padding: const EdgeInsets.only(right: HPSpace.xs),
            child: Builder(
              builder: (chipContext) => ChoiceChip(
                key: Key('tab-$label'),
                avatar: Icon(icon, size: 16),
                label: Text(label),
                selected: v == value,
                showCheckmark: false,
                onSelected: (_) {
                  onChanged(v);
                  // a tab half off either edge slides just far enough to be fully in view
                  Scrollable.ensureVisible(chipContext, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd, duration: const Duration(milliseconds: 150));
                  Scrollable.ensureVisible(chipContext, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart, duration: const Duration(milliseconds: 150));
                },
              ),
            ),
          ),
      ],
    ),
  );
}

/// Collapsible panels where opening one closes the others (tablet / phone dashboards).
class OneOpenAccordion extends StatefulWidget {
  const OneOpenAccordion({super.key, required this.panels, this.initiallyOpen = 0});
  final List<(String title, IconData icon, Widget body)> panels;
  final int? initiallyOpen;
  @override
  State<OneOpenAccordion> createState() => _OneOpenAccordionState();
}

class _OneOpenAccordionState extends State<OneOpenAccordion> {
  late int? _open = widget.initiallyOpen;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < widget.panels.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: HPSpace.sm),
            child: Card(
              key: Key('panel-${widget.panels[i].$1}'),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    key: Key('panel-toggle-${widget.panels[i].$1}'),
                    leading: Icon(widget.panels[i].$2, color: _open == i ? p.accentInk : p.muted),
                    title: Text(widget.panels[i].$1.toUpperCase(), style: HPType.overline(_open == i ? p.text : p.muted)),
                    trailing: Icon(_open == i ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                    // tapping the open panel keeps it open; it closes only when another panel is opened
                    onTap: _open == i ? null : () => setState(() => _open = i),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: _open == i ? Padding(padding: const EdgeInsets.fromLTRB(HPSpace.lg, 0, HPSpace.lg, HPSpace.lg), child: widget.panels[i].$3) : const SizedBox(width: double.infinity),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The title the phone app bar is showing, so a page under it does not repeat it as a heading.
class AppBarTitle extends InheritedWidget {
  const AppBarTitle({super.key, required this.title, required super.child});
  final String title;
  static String? of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<AppBarTitle>()?.title;
  @override
  bool updateShouldNotify(AppBarTitle old) => old.title != title;
}

/// Page frame used by every console screen: Fraunces title, subtitle, actions, responsive padding, scrolling body.
class PageFrame extends StatelessWidget {
  const PageFrame({super.key, required this.title, this.subtitle, this.actions = const [], required this.child, this.scroll = true, this.maxWidth = 1240});
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;
  final bool scroll;
  final double maxWidth;
  @override
  Widget build(BuildContext context) {
    final narrow = isNarrowWeb(context);
    // short = phone in landscape: the app bar already names the page, so the heading shrinks and padding tightens
    final short = isShortScreen(context);
    final pad = short ? HPSpace.md : (narrow ? HPSpace.lg : HPSpace.x4);
    // the phone app bar already names the page: no second "Dashboard" heading under it
    final showTitle = !(narrow && AppBarTitle.of(context) == title);
    final titleBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (showTitle) Text(HPType.heading(title), style: HPType.titleScreen(context.hp.text).copyWith(fontSize: short ? 22 : (narrow ? 28 : 36))),
          if (subtitle != null) ...[if (showTitle) const SizedBox(height: 4), Text(subtitle!, style: HPType.body(context.hp.muted).copyWith(fontSize: short ? 13 : 15))],
        ]);
    final noHeading = !showTitle && subtitle == null;
    // title and actions share a row whenever there is room (tablets, landscape phones); stacked only on narrow phones
    final header = LayoutBuilder(
      builder: (c, box) {
        if (actions.isEmpty) return titleBlock;
        final actionsWrap = Wrap(alignment: WrapAlignment.end, spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: actions);
        // no heading left to show: the actions sit alone at the top right
        if (noHeading) return Align(alignment: Alignment.centerRight, child: actionsWrap);
        if (box.maxWidth < 560 && showTitle) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleBlock,
              const SizedBox(height: HPSpace.md),
              actionsWrap,
      ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: titleBlock),
            const SizedBox(width: HPSpace.lg),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * .55),
              child: actionsWrap,
            ),
          ],
        );
      },
    );
    final headerGap = (noHeading || !showTitle) ? HPSpace.md : (short ? HPSpace.md : (narrow ? HPSpace.lg : HPSpace.x2));
    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!(noHeading && actions.isEmpty)) ...[header, SizedBox(height: headerGap)],
      if (scroll) child else Expanded(child: child),
    ]);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: scroll ? SingleChildScrollView(padding: EdgeInsets.all(pad), child: body) : Padding(padding: EdgeInsets.all(pad), child: body),
      ),
    );
  }
}

/// Error codes the API uses when the restaurant's plan (or the lack of one) blocks a page.
const planErrorCodes = {'feature_not_in_plan', 'no_active_plan', 'license_read_only'};

bool isPlanError(Object? e) => e is ApiException && planErrorCodes.contains(e.code);

/// A page that failed to load. A plan refusal gets a plain "not in your plan" page instead of
/// "Something went wrong" with a pointless Try again; anything else keeps the error + retry.
Widget loadErrorView(Object error, {required String page, VoidCallback? onRetry}) {
  if (!isPlanError(error)) return ErrorState(message: error is ApiException ? error.message : '$error', onRetry: onRetry);
  return PageFrame(
    title: page,
    child: EmptyState(
      key: const Key('plan-locked'),
      icon: Icons.lock_outline_rounded,
      title: 'Not in your plan',
      message: '$page is not included in your restaurant\'s current plan, or the plan is no longer active.\n'
          'Ask House Plating to activate or upgrade your plan, then open this page again.',
    ),
  );
}

/// Yes / no confirmation without a reason; destructive (red) by default, [destructive] false for a plain action.
Future<bool> confirm(BuildContext context, {required String title, required String message, String confirmLabel = 'Delete', bool destructive = true}) async =>
    await showDialog<bool>(
      barrierDismissible: false,
      context: context,
      builder: (c) => HPDialog(
        title: title,
        actions: [
          SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c, false)),
          destructive
              ? DangerButton(label: confirmLabel, onPressed: () => Navigator.pop(c, true))
              : PrimaryButton(key: const Key('confirm-ok'), label: confirmLabel, height: 48, onPressed: () => Navigator.pop(c, true)),
        ],
        child: Text(message),
      ),
    ) ??
    false;

HPTone toneForStatus(String? s) => switch (s) {
      'active' => HPTone.success,
      'pending' || 'invited' => HPTone.pending,
      'suspended' || 'grace' => HPTone.saffron,
      'blocked' || 'disabled' || 'read_only' || 'tenant_blocked' || 'revoked' => HPTone.danger,
      _ => HPTone.neutral,
    };

String shortDate(Object? iso) {
  if (iso == null) return '—';
  final d = DateTime.tryParse('$iso')?.toLocal();
  if (d == null) return '—';
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${m[d.month - 1]} ${d.year}';
}

/// Loads a future and renders loading / error / data states consistently.
class AsyncView<T> extends StatefulWidget {
  const AsyncView({super.key, required this.load, required this.builder, this.isEmpty, this.emptyTitle = 'Nothing here yet'});
  final Future<T> Function() load;
  final Widget Function(BuildContext, T data, VoidCallback reload) builder;
  final bool Function(T)? isEmpty;
  final String emptyTitle;
  @override
  State<AsyncView<T>> createState() => _AsyncViewState<T>();
}

class _AsyncViewState<T> extends State<AsyncView<T>> {
  late Future<T> _f = widget.load();
  void _reload() => setState(() => _f = widget.load());
  @override
  void didUpdateWidget(covariant AsyncView<T> old) {
    super.didUpdateWidget(old);
    if (old.load != widget.load) _f = widget.load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: _f,
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done && !s.hasData) return const LoadingState();
          if (s.hasError) return loadErrorView(s.error!, page: 'This page', onRetry: _reload);
          final data = s.data as T;
          if (widget.isEmpty?.call(data) ?? false) return EmptyState(title: widget.emptyTitle);
          return widget.builder(c, data, _reload);
        },
      );
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child, this.actions = const []});
  final String title;
  final Widget child;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(HPSpace.x2),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // title and its actions share a line when they fit, otherwise the actions wrap underneath
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: HPSpace.sm,
            children: [
              Text(title.toUpperCase(), style: HPType.overline(context.hp.muted)),
              if (actions.isNotEmpty) Wrap(spacing: HPSpace.xs, children: actions),
            ],
          ),
            const SizedBox(height: HPSpace.lg),
            child,
          ]),
        ),
      );
}

/// P10 step-up prompt: password + the admin's own current TOTP code. Returns (password, code) or null.
Future<(String, String)?> askStepUp(BuildContext context, {bool mfaRequired = true}) {
  final pw = TextEditingController(), code = TextEditingController();
  return showDialog<(String, String)>(
    barrierDismissible: false,
    context: context,
    builder: (c) => HPDialog(
      title: 'Confirm it is you',
      actions: [
        SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c)),
        PrimaryButton(label: 'Verify', height: 56, onPressed: () => Navigator.pop(c, (pw.text, code.text.trim()))),
      ],
      child: Column(children: [
        Text(mfaRequired ? 'This action needs fresh verification: enter your password and the current code from your authenticator app.' : 'Confirm this action with your current password.'),
        const SizedBox(height: HPSpace.lg),
        TextField(key: const Key('stepup-password'), controller: pw, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
        if (mfaRequired) ...[
          const SizedBox(height: HPSpace.md),
          TextField(key: const Key('stepup-code'), controller: code, keyboardType: TextInputType.number, maxLength: 6, decoration: const InputDecoration(labelText: '6-digit code')),
        ],
      ]),
    ),
  );
}
