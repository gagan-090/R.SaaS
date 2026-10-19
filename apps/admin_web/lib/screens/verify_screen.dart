import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../api/api_client.dart';
import '../state/providers.dart';

/// Opened from the verification email: the owner confirms their email by choosing a password; the API then
/// creates the restaurant (tenant, main branch, owner account, license) and they can sign in.
class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key, required this.token});
  final String? token;
  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  final _pw = TextEditingController(), _pw2 = TextEditingController();
  bool _busy = false, _show = false;
  String? _error;
  Json? _done;

  static const minLength = 8;
  bool get _longEnough => _pw.text.length >= minLength;
  bool get _mixed => RegExp(r'[A-Za-z]').hasMatch(_pw.text) && RegExp(r'[0-9]').hasMatch(_pw.text);
  bool get _matches => _pw.text.isNotEmpty && _pw.text == _pw2.text;

  String? _check() {
    if (!_longEnough) return 'Use at least $minLength characters (you have ${_pw.text.length})';
    if (!_mixed) return 'Use both letters and numbers';
    if (!_matches) return 'The two passwords do not match';
    return null;
  }

  Future<void> _submit() async {
    final err = _check();
    if (err != null) return setState(() => _error = err);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref.read(apiProvider).verifyEmail(widget.token!, _pw.text);
      setState(() => _done = r);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Cannot reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final met = [_longEnough, _mixed, _pw.text.length >= 12].where((x) => x).length;
    final strength = _pw.text.isEmpty ? 0 : met.clamp(1, 3);
    Widget body;
    if (widget.token == null || widget.token!.isEmpty) {
      body = const EmptyState(icon: Icons.link_off_rounded, title: 'This link is incomplete', message: 'Open the link from your email again, or ask for a new one.');
    } else if (_done != null) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: p.success.withValues(alpha: .16), shape: BoxShape.circle),
            child: Icon(Icons.check_rounded, size: 40, color: p.success),
          ),
        ),
        const SizedBox(height: HPSpace.lg),
        Text('Your restaurant is ready', textAlign: TextAlign.center, style: HPType.titleScreen(p.text).copyWith(fontSize: 28)),
        const SizedBox(height: HPSpace.sm),
        Text('Restaurant code ${_done!['code']}. Sign in with your email and the password you just set, then add your menu, tables and staff.',
            textAlign: TextAlign.center, style: HPType.body(p.muted)),
        const SizedBox(height: HPSpace.x2),
        PrimaryButton(key: const Key('verify-signin'), label: 'Sign in', icon: Icons.login_rounded, onPressed: () => context.go('/login')),
      ]);
    } else {
      body = AutofillGroup(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Set your password', style: HPType.titleScreen(p.text)),
          const SizedBox(height: HPSpace.xs),
          Text('This confirms your email and activates your restaurant.', style: HPType.body(p.muted)),
          const SizedBox(height: HPSpace.x2),
          TextField(
            key: const Key('verify-password'),
            controller: _pw,
            obscureText: !_show,
            autofillHints: const [AutofillHints.newPassword],
            onChanged: (_) => setState(() => _error = null),
            decoration: InputDecoration(
              labelText: 'New password',
              suffixIcon: IconButton(tooltip: _show ? 'Hide' : 'Show', icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined), onPressed: () => setState(() => _show = !_show)),
            ),
          ),
          const SizedBox(height: HPSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: strength / 3,
              minHeight: 4,
              color: [p.danger, p.danger, HPColors.saffron, p.success][strength],
              backgroundColor: p.raised,
            ),
          ),
          const SizedBox(height: HPSpace.sm),
          Row(children: [
            Text(['', 'Weak', 'Good', 'Strong'][strength], style: HPType.label([p.muted, p.danger, HPColors.saffron, p.success][strength]).copyWith(fontSize: 12)),
            const Spacer(),
            Text('${_pw.text.length} characters', key: const Key('verify-count'), style: HPType.body(p.muted).copyWith(fontSize: 12)),
          ]),
          const SizedBox(height: HPSpace.md),
          TextField(
            key: const Key('verify-password2'),
            controller: _pw2,
            obscureText: !_show,
            autofillHints: const [AutofillHints.newPassword],
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(labelText: 'Repeat password'),
          ),
          const SizedBox(height: HPSpace.md),
          // live checklist: each rule turns green as soon as it is met
          for (final (ok, text) in [(_longEnough, 'At least $minLength characters'), (_mixed, 'Letters and numbers'), (_matches, 'Both passwords match')])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: Icon(ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, key: ValueKey(ok), size: 18, color: ok ? p.success : p.faint),
                ),
                const SizedBox(width: HPSpace.sm),
                Expanded(child: Text(text, style: HPType.body(ok ? p.text : p.muted))),
              ]),
            ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: HPSpace.md), child: Text(_error!, key: const Key('verify-error'), style: HPType.body(p.danger))),
          const SizedBox(height: HPSpace.x2),
          PrimaryButton(key: const Key('verify-submit'), label: 'Activate my restaurant', busy: _busy, onPressed: _submit),
        ]),
      );
    }
    return Scaffold(
      appBar: AppBar(actions: [
        Padding(
          padding: const EdgeInsets.only(right: HPSpace.lg),
          child: ThemeModeSwitch(compact: true, showAuto: false, value: ref.watch(themeModeProvider), onChanged: ref.read(themeModeProvider.notifier).set),
        ),
      ]),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(HPSpace.x2),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(child: Padding(padding: const EdgeInsets.all(HPSpace.x4), child: body)),
          ),
        ),
      ),
    );
  }
}
