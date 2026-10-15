import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rsaas_admin_web/api/api_client.dart';
void main() {
 test('reload rotates the saved refresh token and logout clears it', () async {
   String? saved = 'old-refresh';
   final client = ApiClient(sessionReader: () => saved, sessionWriter: (s) => saved = s, client: MockClient((r) async {
     if (r.url.path.endsWith('/auth/refresh')) {
       expect(jsonDecode(r.body)['refreshToken'], 'old-refresh');
       return http.Response(jsonEncode({'accessToken': 'access', 'refreshToken': 'rotated'}), 200);
     }
     return http.Response('{}', 200);
   }));
   expect(await client.restoreSession(), isTrue);
   expect(saved, 'rotated'); expect(client.accessToken, 'access');
   await client.logout(); expect(saved, isNull);
 });
 test('expired saved session is cleared', () async {
   String? saved = 'expired';
   final client = ApiClient(sessionReader: () => saved, sessionWriter: (s) => saved = s, client: MockClient((_) async => http.Response('{"message":"expired"}', 401)));
   expect(await client.restoreSession(), isFalse); expect(saved, isNull);
 });
}
