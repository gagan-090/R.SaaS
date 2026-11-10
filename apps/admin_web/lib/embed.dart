import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'api/api_client.dart';
import 'app.dart';
import 'state/providers.dart';

/// Set when the console runs inside another app (the POS): its assets then live under packages/rsaas_admin_web/.
String? adminAssetPackage;

/// Tells the console it is hosted: a "Back to …" bar on every page, including sign-in.
class AdminHost extends InheritedWidget {
  const AdminHost({super.key, required this.onExit, this.exitLabel = 'Back to POS', required super.child});
  final VoidCallback onExit;
  final String exitLabel;
  static AdminHost? maybeOf(BuildContext c) => c.dependOnInheritedWidgetOfExactType<AdminHost>();
  @override
  bool updateShouldNotify(AdminHost old) => old.exitLabel != exitLabel;
}

/// The full restaurant console inside the POS: same screens, same server checks as the web. One provider container per
/// [userKey] for the app's lifetime, so closing and reopening keeps the person signed in; the refresh token is kept by
/// the host ([initialSession] / [onSessionChanged]) — never shared between POS users.
class EmbeddedAdminConsole extends StatefulWidget {
  const EmbeddedAdminConsole({super.key, required this.userKey, required this.onExit, this.initialSession, this.onSessionChanged, this.exitLabel = 'Back to POS'});
  final String userKey;
  final VoidCallback onExit;
  final String? initialSession;
  final void Function(String? refreshToken)? onSessionChanged;
  final String exitLabel;

  static final Map<String, ProviderContainer> _containers = {};

  /// Forget a person's console state (e.g. when they sign out of the POS).
  static void forget(String userKey) => _containers.remove(userKey)?.dispose();

  @override
  State<EmbeddedAdminConsole> createState() => _EmbeddedAdminConsoleState();
}

class _EmbeddedAdminConsoleState extends State<EmbeddedAdminConsole> {
  late final ProviderContainer _container = EmbeddedAdminConsole._containers.putIfAbsent(widget.userKey, () {
    var session = widget.initialSession;
    return ProviderContainer(overrides: [
      apiProvider.overrideWithValue(ApiClient(
        sessionReader: () => session,
        sessionWriter: (v) {
          session = v;
          widget.onSessionChanged?.call(v);
        },
      )),
    ]);
  });

  @override
  Widget build(BuildContext context) {
    adminAssetPackage = 'rsaas_admin_web';
    return AdminHost(
      onExit: widget.onExit,
      exitLabel: widget.exitLabel,
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
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(right: HPSpace.md),
              child: Text('OWNER CONSOLE', style: HPType.overline(p.muted)),
            ),
          ]),
        ),
      ),
    );
  }
}
