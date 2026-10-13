import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../api/api_client.dart';
import '../state/providers.dart';

class _AuthFrame extends StatelessWidget {
  const _AuthFrame({required this.title, required this.subtitle, required this.child});
  final String title;
  final String subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(HPSpace.x2),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(HPSpace.x4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: const BoxDecoration(color: HPColors.saffron, shape: BoxShape.circle),
                        child: const Icon(Icons.restaurant_rounded, size: 20, color: HPColors.onSaffron),
                      ),
                      const SizedBox(width: HPSpace.sm),
                      Text('HOUSE PLATING', style: HPType.overline(context.hp.accentInk)),
                    ]),
                    const SizedBox(height: HPSpace.lg),
                    Text(title, style: HPType.titleScreen(context.hp.text)),
                    const SizedBox(height: HPSpace.xs),
                    Text(subtitle, style: HPType.body(context.hp.muted)),
                    const SizedBox(height: HPSpace.x2),
                    child,
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}

/// P1 Login.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController(), _password = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).login(_email.text.trim(), _password.text);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Cannot reach the server. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthFrame(
        title: 'Sign in',
        subtitle: 'Restaurant owners, IT admins and platform admins',
        child: Form(
          key: _form,
          child: AutofillGroup(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextFormField(
                key: const Key('login-email'),
                controller: _email,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (v) => (v == null || !v.contains('@')) ? 'Enter your email' : null,
              ),
              const SizedBox(height: HPSpace.md),
              TextFormField(
                key: const Key('login-password'),
                controller: _password,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(labelText: 'Password'),
                validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: HPSpace.md),
                Text(_error!, key: const Key('login-error'), style: HPType.body(context.hp.danger)),
              ],
              const SizedBox(height: HPSpace.x2),
              PrimaryButton(label: 'Sign in', busy: _busy, onPressed: _submit),
            ]),
          ),
        ),
      );
}

/// P2 MFA: verify a code (or recovery code), or first-time enrolment with QR + 10 recovery codes.
class MfaScreen extends ConsumerStatefulWidget {
  const MfaScreen({super.key});
  @override
  ConsumerState<MfaScreen> createState() => _MfaScreenState();
}

class _MfaScreenState extends ConsumerState<MfaScreen> {
  final _code = TextEditingController();
  bool _recovery = false, _busy = false;
  String? _error;
  Map<String, dynamic>? _enroll; // {secret, otpauthUrl}
  List<String>? _codes;

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(authProvider);
    if (s is MfaEnrollment) return _enrollment(s);
    return _AuthFrame(
      title: 'Two-step verification',
      subtitle: _recovery ? 'Enter one of your saved recovery codes.' : 'Enter the 6-digit code from your authenticator app.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          key: const Key('mfa-code'),
          controller: _code,
          autofocus: true,
          keyboardType: _recovery ? TextInputType.text : TextInputType.number,
          maxLength: _recovery ? 12 : 6,
          style: HPType.titleCard(context.hp.text).copyWith(letterSpacing: 6),
          decoration: InputDecoration(labelText: _recovery ? 'Recovery code' : 'Code'),
        ),
        if (_error != null) Text(_error!, style: HPType.body(context.hp.danger)),
        const SizedBox(height: HPSpace.lg),
        PrimaryButton(
          label: 'Verify',
          busy: _busy,
          onPressed: () => _run(() => ref.read(authProvider.notifier).verify(
                code: _recovery ? null : _code.text.trim(),
                recoveryCode: _recovery ? _code.text.trim() : null,
              )),
        ),
        TextButton(onPressed: () => setState(() => _recovery = !_recovery), child: Text(_recovery ? 'Use authenticator code' : 'Use a recovery code')),
      ]),
    );
  }

  Widget _enrollment(MfaEnrollment s) {
    final api = ref.read(apiProvider);
    if (_codes != null) {
      return _AuthFrame(
        title: 'Save your recovery codes',
        subtitle: 'Each code works once if you lose your phone. They will not be shown again.',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.all(HPSpace.lg),
            decoration: BoxDecoration(color: context.hp.raised, borderRadius: BorderRadius.circular(14), border: Border.all(color: context.hp.line)),
            child: Wrap(spacing: HPSpace.x2, runSpacing: HPSpace.sm, children: [for (final c in _codes!) SelectableText(c, style: HPType.mono(context.hp.text))]),
          ),
          const SizedBox(height: HPSpace.x2),
          PrimaryButton(label: 'I have saved them', onPressed: () => _run(() => ref.read(authProvider.notifier).finishEnrollment())),
        ]),
      );
    }
    return _AuthFrame(
      title: 'Set up two-step verification',
      subtitle: 'Required for every platform administrator.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_enroll == null)
          PrimaryButton(label: 'Start', busy: _busy, onPressed: () => _run(() async => _enroll = await api.enrollStart(s.enrollmentToken)))
        else ...[
          Center(child: QrImageView(data: _enroll!['otpauthUrl'] as String, size: 200, backgroundColor: Colors.white)),
          const SizedBox(height: HPSpace.sm),
          SelectableText('Key: ${_enroll!['secret']}', textAlign: TextAlign.center, style: HPType.mono(context.hp.muted)),
          const SizedBox(height: HPSpace.lg),
          TextField(controller: _code, keyboardType: TextInputType.number, maxLength: 6, decoration: const InputDecoration(labelText: 'Code from the app')),
          if (_error != null) Text(_error!, style: HPType.body(context.hp.danger)),
          const SizedBox(height: HPSpace.md),
          PrimaryButton(label: 'Confirm', busy: _busy, onPressed: () => _run(() async {
                final codes = await api.enrollConfirm(s.enrollmentToken, _code.text.trim());
                setState(() => _codes = codes);
              })),
        ],
      ]),
    );
  }
}
