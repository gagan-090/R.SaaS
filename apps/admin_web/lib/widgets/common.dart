import 'package:flutter/material.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../api/api_client.dart';

/// Shows an API error (or any error) as a snackbar.
void showError(BuildContext context, Object e) {
  final msg = e is ApiException ? e.message : 'Unexpected error: $e';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: HPColors.chili));
}

void showDone(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: HPColors.olive));

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
          if (s.connectionState != ConnectionState.done) return const LoadingState();
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
              Expanded(child: Text(title.toUpperCase(), style: HPType.overline(HPColors.inkMuted))),
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
