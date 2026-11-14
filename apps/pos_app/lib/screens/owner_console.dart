import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rsaas_admin_web/embed.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';
import '../state/app_state.dart';
import '../ui/common.dart';
import '../ui/shell.dart' show switchUser;

/// Where the owner console keeps its sign-in between app starts: per POS person, in the device's secure storage.
abstract class ConsoleSessionStore {
  Future<String?> read(String userId);
  Future<void> write(String userId, String? refreshToken);
}

class SecureConsoleSessionStore implements ConsoleSessionStore {
  final _s = const FlutterSecureStorage();
  String _key(String userId) => 'owner-console-session-$userId';
  @override
  Future<String?> read(String userId) async {
    try {
      return await _s.read(key: _key(userId));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String userId, String? refreshToken) async {
    try {
      refreshToken == null ? await _s.delete(key: _key(userId)) : await _s.write(key: _key(userId), value: refreshToken);
    } catch (_) {
      // storage unavailable: they sign in again next time
    }
  }
}

final consoleSessionStoreProvider = Provider<ConsoleSessionStore>((ref) => SecureConsoleSessionStore());

/// Owner and Restaurant Admin: the full restaurant console (everything the web console does). Opens signed in through
/// the main device (their PIN sign-in on the POS is enough) unless they turned on two-step verification.
/// Every action is still checked by the server for that account.
bool canOpenOwnerConsole(StaffSession? s) => s != null && (s.roles.contains('owner') || s.roles.contains('it_admin'));

Future<void> openOwnerConsole(BuildContext context, WidgetRef ref, {String? location}) async {
  final s = ref.read(sessionProvider);
  final hub = ref.read(hubApiProvider);
  if (!canOpenOwnerConsole(s) || hub == null) return;
  final store = ref.read(consoleSessionStoreProvider);
  String? session;
  var mfa = false;
  if (!EmbeddedAdminConsole.isSignedInFor(s!.userId)) {
    // signed in on the POS with the PIN: the main device gets the console session — no second sign-in
    try {
      session = await _withProgress(context, () => _consoleSession(hub));
    } on HubApiException catch (e) {
      if (e.code != 'mfa_required') {
        if (context.mounted) toast(context, _why(e), error: true);
        return;
      }
      // the person turned on two-step verification: only then the console's own sign-in (remembered on this device)
      session = await store.read(s.userId);
      mfa = true;
    }
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (c) => EmbeddedAdminConsole(
      key: const Key('owner-console'),
      userKey: s.userId,
      initialSession: session,
      initialLocation: location,
      onSessionChanged: mfa ? (t) => store.write(s.userId, t) : null,
      // a console session that runs out while open is renewed the same way, never by the sign-in page
      renewSession: mfa ? null : () => _consoleSession(hub),
      onExit: () => Navigator.of(c).pop(),
      // Sign out from the console: off the console and off this terminal, back to "Who is working?"
      onSignOut: () {
        Navigator.of(c).pop();
        if (context.mounted) switchUser(context, ref);
      },
    ),
  ));
}

/// The console refresh token through the main device; one more try when the cloud was still waking up.
Future<String?> _consoleSession(HubApi hub) async {
  for (var attempt = 0;; attempt++) {
    try {
      return (await hub.consoleSession())['refreshToken'] as String?;
    } on HubApiException catch (e) {
      final waking = const {'cloud_starting', 'cloud_error', 'internal'}.contains(e.code) || (e.status >= 500 && e.code != 'offline');
      if (attempt > 0 || !waking) rethrow;
    }
  }
}

String _why(HubApiException e) => switch (e.code) {
      'hub_offline' => 'Cannot reach the main device. Check it is on and on this Wi-Fi, then try again.',
      'offline' => 'The owner console needs internet on the main device.',
      _ => e.message,
    };

/// "Opening the owner console…" over the POS while the main device asks the cloud (can take a while the first time).
Future<T> _withProgress<T>(BuildContext context, Future<T> Function() task) async {
  final nav = Navigator.of(context, rootNavigator: true);
  var shown = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => PopScope(
      canPop: false,
      child: AlertDialog(
        key: const Key('console-opening'),
        content: Row(children: [
          const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: HPSpace.lg),
          Expanded(child: Text('Opening the owner console…', style: HPType.body(c.hp.text))),
        ]),
      ),
    ),
  ).whenComplete(() => shown = false);
  try {
    return await task();
  } finally {
    if (shown) nav.pop();
  }
}
