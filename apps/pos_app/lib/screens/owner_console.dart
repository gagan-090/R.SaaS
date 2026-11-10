import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rsaas_admin_web/embed.dart';

import '../hub/hub_api.dart';
import '../state/app_state.dart';
import '../ui/common.dart';

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
  if (!canOpenOwnerConsole(s)) return;
  final store = ref.read(consoleSessionStoreProvider);
  String? session;
  var remember = false;
  if (!EmbeddedAdminConsole.isOpenFor(s!.userId)) {
    // signed in on the POS with the PIN: the main device gets the console session — no second sign-in
    try {
      session = (await ref.read(hubApiProvider)!.consoleSession())['refreshToken'] as String?;
    } on HubApiException catch (e) {
      if (e.code != 'mfa_required') {
        if (context.mounted) toast(context, e.message, error: true);
        return;
      }
      // two-step verification is on: the normal console sign-in, remembered on this device
      session = await store.read(s.userId);
      remember = true;
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
      onSessionChanged: remember ? (t) => store.write(s.userId, t) : null,
      onExit: () => Navigator.of(c).pop(),
    ),
  ));
}
