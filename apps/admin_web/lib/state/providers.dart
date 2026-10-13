import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';

final apiProvider = Provider<ApiClient>((ref) => ApiClient());

/// Sign-in progress: password → (MFA challenge | first-time enrolment) → signed in.
sealed class AuthState {
  const AuthState();
}

class SignedOut extends AuthState {
  const SignedOut();
}

class MfaChallenge extends AuthState {
  const MfaChallenge(this.challengeToken);
  final String challengeToken;
}

class MfaEnrollment extends AuthState {
  const MfaEnrollment(this.enrollmentToken);
  final String enrollmentToken;
}

class SignedIn extends AuthState {
  const SignedIn(this.me);
  final Map<String, dynamic> me;
  Set<String> get permissions => ((me['permissions'] as List?) ?? const []).cast<String>().toSet();
  bool can(String p) => permissions.contains(p);

  /// Restaurant user (owner / IT admin …) rather than a platform administrator.
  bool get isRestaurant => me['type'] == 'user';
  List<String> get roles => ((me['roles'] as List?) ?? const []).cast<String>();
}

class AuthNotifier extends Notifier<AuthState> with ChangeNotifier {
  @override
  AuthState build() {
    ref.read(apiProvider).onSessionExpired = () => _set(const SignedOut());
    return const SignedOut();
  }

  ApiClient get _api => ref.read(apiProvider);

  void _set(AuthState s) {
    state = s;
    notifyListeners();
  }

  Future<void> login(String email, String password) async {
    final r = await _api.login(email, password);
    switch (r['status']) {
      case 'mfa_required':
        _set(MfaChallenge(r['challengeToken'] as String));
      case 'mfa_enrollment_required':
        _set(MfaEnrollment(r['enrollmentToken'] as String));
      default:
        await _loadMe();
    }
  }

  Future<void> verify({String? code, String? recoveryCode}) async {
    final s = state;
    if (s is! MfaChallenge) return;
    await _api.verifyMfa(s.challengeToken, code: code, recoveryCode: recoveryCode);
    await _loadMe();
  }

  /// Called once the admin has saved their recovery codes.
  Future<void> finishEnrollment() => _loadMe();

  Future<void> _loadMe() async => _set(SignedIn(await _api.me()));

  Future<void> logout() async {
    await _api.logout();
    _set(const SignedOut());
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
