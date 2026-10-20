import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';


final apiProvider = Provider<ApiClient>((ref) => ApiClient());

/// Sign-in progress: password → (MFA challenge | first-time enrolment) → signed in.
sealed class AuthState {
  const AuthState();
}

class RestoringSession extends AuthState { const RestoringSession(); }

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

  String? get restaurantName => (me['tenant'] as Map?)?['name'] as String?;
  String? get restaurantCode => (me['tenant'] as Map?)?['code'] as String?;
  String get restaurantPrefix => restaurantShortPrefix(name: restaurantName, fallbackCode: restaurantCode);
}

/// Calculates a concise short prefix from a restaurant name.
/// e.g. "Demo Dhaba" -> "DD-", "The Spice Route" -> "TSR-", "McDonald's" -> "MCD-".
/// If only 1 word and <= 4 chars: e.g. "Chai" -> "CHAI-", "KFC" -> "KFC-".
/// Falls back to fallbackCode (e.g. tenant code "R000000") or 'RST-'.
String restaurantShortPrefix({String? name, String? fallbackCode}) {
  if (name != null && name.trim().isNotEmpty) {
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .map((w) => w.replaceAll(RegExp(r'[^A-Za-z0-9]'), ''))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.length >= 2) {
      final initials = words.take(4).map((w) => w[0].toUpperCase()).join();
      if (initials.isNotEmpty) return '$initials-';
    } else if (words.length == 1) {
      final clean = words.first.toUpperCase();
      if (clean.length <= 4) return '$clean-';
      return '${clean.substring(0, 3)}-';
    }
  }
  if (fallbackCode != null && fallbackCode.trim().isNotEmpty) {
    final clean = fallbackCode.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (clean.isNotEmpty) return '$clean-';
  }
  return 'RST-';
}

class AuthNotifier extends Notifier<AuthState> with ChangeNotifier {
  @override
  AuthState build() {
    ref.read(apiProvider).onSessionExpired = () => _set(const SignedOut());
    Future.microtask(_restore);
    return const RestoringSession();
  }

  Future<void> _restore() async {
    try { if (await _api.restoreSession()) { await _loadMe(); } else { _set(const SignedOut()); } } catch (_) { _set(const SignedOut()); }
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

  Future<void> pinLogin(String email, String pin) async {
    await _api.pinLogin(email, pin);
    await _loadMe();
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

/// Plans that can be sold right now (not archived) — used by registration, license changes and filters.
final activePlansProvider = FutureProvider<List<Json>>((ref) async => (await ref.read(apiProvider).plans()).cast<Json>());

/// Admin types (platform roles) for the sidebar's Admins sub-menu.
final adminRolesProvider = FutureProvider<List<Json>>((ref) async => (await ref.read(apiProvider).roles()).cast<Json>());

/// Light / dark / follow the device. Remembered on this device (browser storage on the web).
class ThemeModeNotifier extends Notifier<ThemeMode> {
  // v2: the white (Light) theme became the default on 13 Oct 2026, so earlier "Auto" choices start over
  static const _key = 'appearance.v2';

  @override
  ThemeMode build() {
    _load();
    return ThemeMode.light;
  }

  Future<void> _load() async {
    try {
      final v = (await SharedPreferences.getInstance()).getString(_key);
      if (v != null) state = ThemeMode.values.firstWhere((m) => m.name == v, orElse: () => ThemeMode.light);
    } catch (_) {
      // storage unavailable (private window, tests): stay on the white theme
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    try {
      await (await SharedPreferences.getInstance()).setString(_key, mode.name);
    } catch (_) {}
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

/// The signed-in restaurant's name and look. `brand` is null unless its plan includes "branding" and the owner set one;
/// Super Admins always see House Plating. Bump [brandRefreshProvider] after saving branding.
typedef RestaurantLook = ({String name, HPBrand? brand});
final brandRefreshProvider = StateProvider<int>((ref) => 0);
final restaurantLookProvider = FutureProvider<RestaurantLook?>((ref) async {
  ref.watch(brandRefreshProvider);
  final a = ref.watch(authProvider);
  if (a is! SignedIn || !a.isRestaurant || !a.can('restaurant.profile.read')) return null;
  final o = await ref.read(apiProvider).overview();
  return (name: '${(o['restaurant'] as Map?)?['name'] ?? ''}', brand: HPBrand.fromJson(o['branding']));
});
