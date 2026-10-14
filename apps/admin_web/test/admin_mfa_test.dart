import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';
import 'admin_web_test.dart' show pumpApp, signIn;
import 'fixture_api.dart';

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);
  testWidgets('Super Admin turns another admin MFA off with reason and fresh verification', (t) async {
    final fx = await pumpApp(t);
    final target = {'id': 'policy-id', 'name': 'Policy Admin', 'email': 'policy@example.test', 'status': 'active', 'mfaEnabled': true, 'mfaEnrolled': true, 'roles': [{'id': 'r1', 'name': 'Platform Auditor'}]};
    fx.overrides['GET /platform/admins'] = (200, [target]);
    await signIn(t);
    await t.tap(find.text('Admins'));
    await t.pumpAndSettle();
    await t.tap(find.descendant(of: find.byKey(const Key('admin-policy@example.test')), matching: find.byTooltip('Actions')));
    await t.pumpAndSettle();
    await t.tap(find.text('Turn MFA off'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('reason-field')), 'Approved account policy change');
    await t.pumpAndSettle();
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('stepup-password')), 'acting-admin-password');
    await t.enterText(find.byKey(const Key('stepup-code')), '654321');
    fx.overrides['POST /platform/admins/policy-id/mfa/policy'] = (200, {...target, 'mfaEnabled': false, 'sessionsRevoked': true});
    fx.overrides['GET /platform/admins'] = (200, [{...target, 'mfaEnabled': false}]);
    await t.tap(find.widgetWithText(PrimaryButton, 'Verify'));
    await t.pumpAndSettle();
    final request = fx.where('POST', '/mfa/policy').single;
    expect(jsonDecode(request.body), {'enabled': false, 'reason': 'Approved account policy change'});
    expect(request.headers['x-step-up-token'], (FixtureApi.fixture('POST_auth_step_up.json')! as Map)['stepUpToken']);
    expect(find.text('MFA off'), findsOneWidget);
    expect(fx.where('POST', '/auth/logout'), isEmpty);
  });

  testWidgets('Super Admin enables own MFA from off with password confirmation and signs out', (t) async {
    final fx = await pumpApp(t);
    final me = (FixtureApi.fixture('GET_me.json')! as Map).cast<String, dynamic>();
    fx.overrides['GET /me'] = (200, {...me, 'mfaEnabled': false});
    fx.overrides['GET /platform/admins'] = (200, [{'id': me['id'], 'name': me['name'], 'email': me['email'], 'status': 'active', 'mfaEnabled': false, 'mfaEnrolled': true, 'roles': [{'id': 'sa-role', 'name': 'Super Admin'}]}]);
    await signIn(t);
    await t.tap(find.text('Admins'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Actions'));
    await t.pumpAndSettle();
    expect(find.text('Edit roles'), findsNothing);
    await t.tap(find.text('Turn MFA on'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('reason-field')), 'Require MFA for my account');
    await t.pumpAndSettle();
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('stepup-code')), findsNothing);
    await t.enterText(find.byKey(const Key('stepup-password')), 'acting-admin-password');
    fx.overrides['POST /platform/admins/${me['id']}/mfa/policy'] = (200, {'mfaEnabled': true, 'sessionsRevoked': true});
    await t.tap(find.widgetWithText(PrimaryButton, 'Verify'));
    await t.pumpAndSettle();
    expect(jsonDecode(fx.where('POST', '/auth/step-up').single.body), {'password': 'acting-admin-password'});
    expect(jsonDecode(fx.where('POST', '/mfa/policy').single.body), {'enabled': true, 'reason': 'Require MFA for my account'});
    expect(fx.where('POST', '/auth/logout'), hasLength(1));
    expect(find.byKey(const Key('login-password')), findsOneWidget);
  });

  testWidgets('delegated MFA reset permission does not show Super Admin policy controls', (t) async {
    final fx = await pumpApp(t);
    final me = (FixtureApi.fixture('GET_me.json')! as Map).cast<String, dynamic>();
    fx.overrides['GET /me'] = (200, {...me, 'roles': ['Platform Auditor'], 'permissions': ['platform.admin.read', 'platform.mfa.reset']});
    fx.overrides['GET /platform/admins'] = (200, [{'id': 'other-id', 'name': 'Other Admin', 'email': 'other@example.test', 'status': 'active', 'mfaEnabled': true, 'mfaEnrolled': true, 'roles': []}]);
    await signIn(t);
    await t.tap(find.text('Admins'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Actions'));
    await t.pumpAndSettle();
    expect(find.text('Turn MFA off'), findsNothing);
    expect(find.text('Turn MFA on'), findsNothing);
    expect(find.text('Reset MFA…'), findsOneWidget);
  });
}
