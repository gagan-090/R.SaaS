import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'api/api_client.dart';
import 'app.dart';
import 'state/providers.dart';

/// Set when the console runs inside another app (the POS): its assets then live under packages/rsaas_admin_web/.
String? adminAssetPackage;

/// Tells the console it is hosted: a "Back to …" bar on every page, including sign-in.
class AdminHost extends InheritedWidget {
  const AdminHost({super.key, required this.onExit, this.exitLabel = 'Back to POS', this.onSignOut, required super.child});
  final VoidCallback onExit;
  final String exitLabel;

  /// Signs the person out of the host (POS: back to the PIN screen). Null: no Sign out inside the hosted console.
  final VoidCallback? onSignOut;
  static AdminHost? maybeOf(BuildContext c) => c.dependOnInheritedWidgetOfExactType<AdminHost>();
  @override
  bool updateShouldNotify(AdminHost old) => old.exitLabel != exitLabel || (old.onSignOut == null) != (onSignOut == null);
}

/// The full restaurant console inside the POS: same screens, same server checks as the web. One provider container per
/// [userKey] for the app's lifetime, so closing and reopening keeps the person signed in; the refresh token is kept by
/// the host ([initialSession] / [onSessionChanged]) — never shared between POS users.
class EmbeddedAdminConsole extends StatefulWidget {
  const EmbeddedAdminConsole({super.key, required this.userKey, required this.onExit, this.initialSession, this.onSessionChanged, this.renewSession, this.exitLabel = 'Back to POS', this.initialLocation, this.onSignOut});
  final String userKey;

  /// Sign out of the host app (see [AdminHost.onSignOut]); the console's own session is ended too.
  final VoidCallback? onSignOut;

  /// A fresh refresh token from the host (POS: through the main device) when the console's own one stops working, so
  /// the person is not sent to the sign-in page. Null: the console's normal sign-in (two-step verification on).
  final Future<String?> Function()? renewSession;
  final VoidCallback onExit;
  final String? initialSession;
  final void Function(String? refreshToken)? onSessionChanged;
  final String exitLabel;

  /// Page to open on, e.g. '/console/tables' (after sign-in the console stays on it).
  final String? initialLocation;

  static final Map<String, ProviderContainer> _containers = {};

  /// Tests: the cloud API the console talks to.
  @visibleForTesting
  static http.Client? debugHttpClient;

  /// True when this person already has a console open in this app run (signed in or signing in).
  static bool isOpenFor(String userKey) => _containers.containsKey(userKey);

  /// True when this person's console is open in this app run and signed in (reopening needs no new session).
  static bool isSignedInFor(String userKey) => _containers[userKey]?.read(authProvider) is SignedIn;

  // the latest host callbacks per person (a console outlives the widget that first opened it)
  static final Map<String, String?> _sessions = {};
  static final Map<String, void Function(String?)?> _sessionChanged = {};
  static final Map<String, Future<String?> Function()?> _renewers = {};

  /// Forget a person's console state (e.g. when they sign out of the POS).
  static void forget(String userKey) {
    _containers.remove(userKey)?.dispose();
    _sessions.remove(userKey);
    _sessionChanged.remove(userKey);
    _renewers.remove(userKey);
  }

  @override
  State<EmbeddedAdminConsole> createState() => _EmbeddedAdminConsoleState();
}

class _EmbeddedAdminConsoleState extends State<EmbeddedAdminConsole> {
  late final ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    final key = widget.userKey;
    EmbeddedAdminConsole._sessionChanged[key] = widget.onSessionChanged;
    EmbeddedAdminConsole._renewers[key] = widget.renewSession;
    final fresh = widget.initialSession;
    if (fresh != null) EmbeddedAdminConsole._sessions[key] = fresh;
    final existed = EmbeddedAdminConsole._containers.containsKey(key);
    _container = EmbeddedAdminConsole._containers.putIfAbsent(key, () => ProviderContainer(overrides: [
          apiProvider.overrideWithValue(ApiClient(
            client: EmbeddedAdminConsole.debugHttpClient,
            sessionReader: () => EmbeddedAdminConsole._sessions[key],
            sessionWriter: (v) {
              EmbeddedAdminConsole._sessions[key] = v;
              EmbeddedAdminConsole._sessionChanged[key]?.call(v);
            },
            renewSession: () async => EmbeddedAdminConsole._renewers[key]?.call(),
          )),
        ]));
    // reopened after the console lost its sign-in (expired, or it was showing the sign-in page): sign in again with
    // the session the host just brought, instead of showing the sign-in page
    // (after this build: the sign-in state must not change while the tree is being built)
    if (existed && fresh != null) Future.microtask(() => _container.read(authProvider.notifier).resume());
    final loc = widget.initialLocation;
    if (loc != null) WidgetsBinding.instance.addPostFrameCallback((_) => _container.read(routerProvider).go(loc));
  }

  @override
  Widget build(BuildContext context) {
    adminAssetPackage = 'rsaas_admin_web';
    return AdminHost(
      onExit: widget.onExit,
      exitLabel: widget.exitLabel,
      onSignOut: widget.onSignOut,
      child: UncontrolledProviderScope(container: _container, child: const AdminApp()),
    );
  }
}

/// The slim bar a hosted console shows above every page.
class AdminHostBar extends StatelessWidget {
  const AdminHostBar({super.key, required this.host});
  final AdminHost host;
  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return Material(
      color: p.raised,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 44,
          child: Row(children: [
            TextButton.icon(
              key: const Key('admin-host-exit'),
              onPressed: host.onExit,
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: Text(host.exitLabel),
            ),
            // small phones / large text: the label gives way, the Back button never does
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: HPSpace.md),
                child: Text('OWNER CONSOLE', style: HPType.overline(p.muted), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right),
              ),
            ),
            if (host.onSignOut != null)
              // very small phones / large text: shrinks rather than pushing Back off the bar
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Consumer(builder: (c, ref, _) => TextButton.icon(
                    key: const Key('admin-host-sign-out'),
                    onPressed: () => signOutOfHost(host, ref),
                    icon: const Icon(Icons.logout_rounded, size: 18),
                    label: const Text('Sign out'),
                  )),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Hosted console's Sign out: leaves the host (POS: back to the PIN screen) and ends the console's own session, so the
/// next person to open it gets a fresh one.
void signOutOfHost(AdminHost host, WidgetRef ref) {
  final auth = ref.read(authProvider.notifier);
  host.onSignOut!();
  auth.logout().catchError((_) {});
}
