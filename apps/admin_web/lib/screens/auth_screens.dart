import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../api/api_client.dart';
import '../state/providers.dart';
import '../util/pin_policy.dart';
import '../widgets/common.dart';

class _AuthFrame extends ConsumerWidget {
  const _AuthFrame({required this.title, required this.subtitle, required this.child});
  final String title;
  final String subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        appBar: AppBar(
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: HPSpace.lg),
              child: ThemeModeSwitch(compact: true, value: ref.watch(themeModeProvider), onChanged: ref.read(themeModeProvider.notifier).set),
            ),
          ],
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(HPSpace.x2),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 480 ? HPSpace.lg : HPSpace.x4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(color: HPColors.saffron, shape: BoxShape.circle),
                        child: Icon(Icons.restaurant_rounded, size: 20, color: HPColors.onSaffron),
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
  const LoginScreen({super.key, this.employee = false});
  final bool employee;
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController(), _password = TextEditingController(), _pin = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  late bool _usePin = widget.employee;
  String? _error;

  @override
  void didUpdateWidget(LoginScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.employee != widget.employee) {
      _usePin = widget.employee;
      _error = null;
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = ref.read(authProvider.notifier);
      if (_usePin) {
        await auth.pinLogin(_email.text.trim(), _pin.text.trim());
      } else {
        await auth.login(_email.text.trim(), _password.text);
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Cannot reach the server. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgotPin() async {
    final email = TextEditingController(text: _email.text.trim());
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => HPDialog(
        title: 'Forgot your PIN?',
        actions: [SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(c)), PrimaryButton(key: const Key('send-pin-reset'), label: 'Send link', height: 56, onPressed: () => Navigator.pop(c, true))],
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('We email you a link to choose a new PIN. Your current PIN keeps working until then.', style: HPType.body(c.hp.muted)),
          const SizedBox(height: HPSpace.md),
          TextField(key: const Key('reset-email'), controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Your work email')),
        ]),
      ),
    );
    if (go != true || !mounted) return;
    try {
      final r = await ref.read(apiProvider).pinResetRequest(email.text.trim());
      if (mounted) showDone(context, '${r['message']}');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthFrame(
        title: 'Sign in',
        subtitle: _usePin ? 'Employees: your work email and PIN' : 'Restaurant owners and platform admins',
        child: Form(
          key: _form,
          child: AutofillGroup(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SegmentedButton<bool>(
                key: const Key('login-mode'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Password'), icon: Icon(Icons.lock_outline_rounded)),
                  ButtonSegment(value: true, label: Text('Employee PIN'), icon: Icon(Icons.pin_outlined)),
                ],
                selected: {_usePin},
                onSelectionChanged: (v) => setState(() {
                  _usePin = v.first;
                  _error = null;
                }),
              ),
              const SizedBox(height: HPSpace.lg),
              TextFormField(
                key: const Key('login-email'),
                controller: _email,
                autofillHints: const [AutofillHints.email],
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (v) => (v == null || !v.contains('@')) ? 'Enter your email' : null,
              ),
              const SizedBox(height: HPSpace.md),
              if (_usePin)
                TextFormField(
                  key: const Key('login-pin'),
                  controller: _pin,
                  obscureText: true,
                  maxLength: 8,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'PIN', counterText: ''),
                  validator: (v) => (v == null || v.length < 4) ? 'Enter your PIN' : null,
                  onFieldSubmitted: (_) => _submit(),
                )
              else
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
                const SizedBox(height: HPSpace.xs),
                if (!_usePin)
                  // generic on purpose (no hint whether the email exists), but tells new owners what to do
                  Text('New restaurant? Activate it first with the link in your email, or ask your platform admin to resend it.',
                      key: const Key('login-hint'), style: HPType.body(context.hp.muted).copyWith(fontSize: 13)),
              ],
              const SizedBox(height: HPSpace.x2),
              PrimaryButton(label: 'Sign in', busy: _busy, onPressed: _submit),
              if (_usePin) ...[
                const SizedBox(height: HPSpace.sm),
                TextButton(key: const Key('forgot-pin'), onPressed: _forgotPin, child: const Text('Forgot PIN?')),
              ],
            ]),
          ),
        ),
      );
}

/// Opened from an emailed invite / reset link: the employee chooses their own PIN (never sent by email).
class SetPinScreen extends ConsumerStatefulWidget {
  const SetPinScreen({super.key, required this.token});
  final String? token;
  @override
  ConsumerState<SetPinScreen> createState() => _SetPinScreenState();
}

class _SetPinScreenState extends ConsumerState<SetPinScreen> {
  final _pin = TextEditingController(), _again = TextEditingController();
  Json? _info;
  String? _error, _done;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (widget.token == null || widget.token!.isEmpty) return setState(() => _error = 'This link is incomplete. Open it again from your email.');
    try {
      final r = await ref.read(apiProvider).pinLinkCheck(widget.token!);
      if (mounted) setState(() => _info = r);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Cannot reach the server. Check your connection.');
    }
  }

  Future<void> _save() async {
    final pin = _pin.text.trim();
    final problem = pinProblem(pin) ?? (pin != _again.text.trim() ? 'The two PINs do not match' : null);
    if (problem != null) return setState(() => _error = problem);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref.read(apiProvider).pinLinkComplete(widget.token!, pin);
      if (mounted) setState(() => _done = r['webAccess'] == true ? 'Your PIN is set. Sign in with your email and PIN.' : 'Your PIN is set. Use it on the POS.');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    if (_done != null) {
      return _AuthFrame(
        title: 'All set',
        subtitle: _done!,
        child: PrimaryButton(key: const Key('to-login'), label: 'Go to sign in', onPressed: () => GoRouter.of(context).go('/login')),
      );
    }
    if (_info == null) {
      return _AuthFrame(
        title: 'Choose your PIN',
        subtitle: _error ?? 'Checking your link…',
        child: _error == null ? const LinearProgressIndicator() : const SizedBox.shrink(),
      );
    }
    return _AuthFrame(
      title: _info!['purpose'] == 'reset' ? 'Choose a new PIN' : 'Choose your PIN',
      subtitle: '${_info!['name']} · ${_info!['restaurantName']}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('6 to 8 digits. Not all the same digit and not a run like 123456. Never share it.', style: HPType.body(p.muted)),
        const SizedBox(height: HPSpace.md),
        TextField(key: const Key('new-pin'), controller: _pin, obscureText: true, maxLength: 8, keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'New PIN', counterText: '')),
        const SizedBox(height: HPSpace.sm),
        TextField(key: const Key('new-pin-again'), controller: _again, obscureText: true, maxLength: 8, keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'Type it again', counterText: ''), onSubmitted: (_) => _save()),
        if (_error != null) ...[const SizedBox(height: HPSpace.sm), Text(_error!, key: const Key('set-pin-error'), style: HPType.body(p.danger))],
        const SizedBox(height: HPSpace.lg),
        PrimaryButton(key: const Key('save-pin'), label: 'Save PIN', busy: _busy, onPressed: _save),
      ]),
    );
  }
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
