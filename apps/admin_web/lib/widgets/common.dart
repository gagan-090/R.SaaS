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
    final pad = narrow ? HPSpace.lg : HPSpace.x4;
    final header = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.end,
      runSpacing: HPSpace.md,
      spacing: HPSpace.lg,
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(HPType.heading(title), style: HPType.titleScreen(context.hp.text).copyWith(fontSize: narrow ? 28 : 36)),
          if (subtitle != null) ...[const SizedBox(height: 4), Text(subtitle!, style: HPType.body(context.hp.muted).copyWith(fontSize: 15))],
        ]),
        if (actions.isNotEmpty) Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: actions),
      ],
    );
    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, SizedBox(height: narrow ? HPSpace.lg : HPSpace.x2), if (scroll) child else Expanded(child: child)]);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: scroll ? SingleChildScrollView(padding: EdgeInsets.all(pad), child: body) : Padding(padding: EdgeInsets.all(pad), child: body),
      ),
    );
  }
}

/// Yes / no confirmation for destructive actions without a reason.
Future<bool> confirm(BuildContext context, {required String title, required String message, String confirmLabel = 'Delete'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => HPDialog(
        title: title,
        actions: [
          SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c, false)),
          DangerButton(label: confirmLabel, onPressed: () => Navigator.pop(c, true)),
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
          if (s.hasError) return ErrorState(message: '${s.error}', onRetry: _reload);
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
            Row(children: [
              Expanded(child: Text(title.toUpperCase(), style: HPType.overline(context.hp.muted))),
              ...actions,
            ]),
            const SizedBox(height: HPSpace.lg),
            child,
          ]),
        ),
      );
}

/// P10 step-up prompt: password + the admin's own current TOTP code. Returns (password, code) or null.
Future<(String, String)?> askStepUp(BuildContext context) {
  final pw = TextEditingController(), code = TextEditingController();
  return showDialog<(String, String)>(
    context: context,
    builder: (c) => HPDialog(
      title: 'Confirm it is you',
      actions: [
        SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c)),
        PrimaryButton(label: 'Verify', height: 56, onPressed: () => Navigator.pop(c, (pw.text, code.text.trim()))),
      ],
      child: Column(children: [
        const Text('This action needs fresh verification: enter your password and the current code from your authenticator app.'),
        const SizedBox(height: HPSpace.lg),
        TextField(key: const Key('stepup-password'), controller: pw, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
        const SizedBox(height: HPSpace.md),
        TextField(key: const Key('stepup-code'), controller: code, keyboardType: TextInputType.number, maxLength: 6, decoration: const InputDecoration(labelText: '6-digit code')),
      ]),
    ),
  );
}
