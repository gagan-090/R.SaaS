import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/state/providers.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fixture_api.dart';

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  testWidgets('tapping empty space closes the keyboard (tablet / phone)', (t) async {
    t.view.physicalSize = const Size(800, 1280);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final fx = FixtureApi();
    await t.pumpWidget(ProviderScope(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fx.client()))], child: const AdminApp()));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('login-email')));
    await t.pump();
    bool editing() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null || FocusManager.instance.primaryFocus?.debugLabel == 'EditableText';
    expect(editing(), isTrue);
    expect(t.testTextInput.isVisible, isTrue);
    await t.tapAt(const Offset(20, 1260)); // empty space under the sign-in card
    await t.pump();
    expect(editing(), isFalse);
    expect(t.testTextInput.isVisible, isFalse);
  });
}
