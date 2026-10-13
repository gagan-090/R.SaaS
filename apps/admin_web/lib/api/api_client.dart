import 'dart:convert';

import 'package:http/http.dart' as http;

/// Build-time API base URL: flutter run/build --dart-define=API_BASE_URL=https://api.example.com/api/v1
const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:3000/api/v1');

class ApiException implements Exception {
  ApiException(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;
  @override
  String toString() => message;
}

typedef Json = Map<String, dynamic>;

/// Thin client for the cloud API (contract: packages/contracts/openapi.json).
/// Tokens live in memory only — a browser refresh signs the admin out (no tokens in localStorage).
class ApiClient {
  ApiClient({String baseUrl = apiBaseUrl, http.Client? client})
      : _base = baseUrl,
        _http = client ?? http.Client();

  final String _base;
  final http.Client _http;
  String? accessToken;
  String? refreshToken;
  void Function()? onSessionExpired;

  Future<dynamic> _send(String method, String path, {Object? body, Map<String, String>? query, Map<String, String>? headers, String? bearer, bool retry = true}) async {
    final uri = Uri.parse('$_base$path').replace(queryParameters: query == null || query.isEmpty ? null : query);
    final req = http.Request(method, uri)
      ..headers['content-type'] = 'application/json'
      ..headers.addAll(headers ?? const {});
    final tok = bearer ?? accessToken;
    if (tok != null) req.headers['authorization'] = 'Bearer $tok';
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await _http.send(req));
    if (res.statusCode == 401 && retry && bearer == null && refreshToken != null && !path.startsWith('/auth/')) {
      if (await _refresh()) return _send(method, path, body: body, query: query, headers: headers, retry: false);
      onSessionExpired?.call();
    }
    final decoded = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      final m = decoded is Map ? decoded : const {};
      throw ApiException(res.statusCode, '${m['code'] ?? 'http_${res.statusCode}'}', '${m['message'] ?? 'Request failed (${res.statusCode})'}');
    }
    return decoded;
  }

  Future<bool> _refresh() async {
    try {
      final r = await _send('POST', '/auth/refresh', body: {'refreshToken': refreshToken}, retry: false) as Json;
      accessToken = r['accessToken'] as String;
      refreshToken = r['refreshToken'] as String;
      return true;
    } catch (_) {
      accessToken = refreshToken = null;
      return false;
    }
  }

  void _setTokens(Json t) {
    accessToken = t['accessToken'] as String;
    refreshToken = t['refreshToken'] as String;
  }

  // ---- auth
  Future<Json> login(String email, String password) async {
    final r = await _send('POST', '/auth/login', body: {'email': email, 'password': password}) as Json;
    if (r['status'] == 'ok') _setTokens(r);
    return r;
  }

  Future<void> verifyMfa(String challengeToken, {String? code, String? recoveryCode}) async =>
      _setTokens(await _send('POST', '/auth/mfa/verify', body: {'challengeToken': challengeToken, 'code': ?code, 'recoveryCode': ?recoveryCode}) as Json);

  Future<Json> enrollStart(String enrollmentToken) async => await _send('POST', '/me/mfa/enroll', bearer: enrollmentToken) as Json;

  Future<List<String>> enrollConfirm(String enrollmentToken, String code) async {
    final r = await _send('POST', '/me/mfa/confirm', body: {'code': code}, bearer: enrollmentToken) as Json;
    if (r['tokens'] != null) _setTokens(r['tokens'] as Json);
    return (r['recoveryCodes'] as List).cast<String>();
  }

  Future<String> stepUp(String password, String code) async => (await _send('POST', '/auth/step-up', body: {'password': password, 'code': code}) as Json)['stepUpToken'] as String;

  Future<void> logout() async {
    if (refreshToken != null) {
      try {
        await _send('POST', '/auth/logout', body: {'refreshToken': refreshToken});
      } catch (_) {}
    }
    accessToken = refreshToken = null;
  }

  Future<Json> me() async => await _send('GET', '/me') as Json;

  // ---- restaurants
  Future<Json> restaurants({String? q, String? status, String? plan, String? owner, String? expiresBefore, int page = 1}) async => await _send('GET', '/restaurants', query: {
        if (q != null && q.isNotEmpty) 'q': q,
        'status': ?status,
        'plan': ?plan,
        if (owner != null && owner.isNotEmpty) 'owner': owner,
        'expiresBefore': ?expiresBefore,
        'page': '$page',
        'pageSize': '25',
      }) as Json;
  Future<Json> restaurant(String id) async => await _send('GET', '/restaurants/$id') as Json;
  Future<Json> registerRestaurant(Json body) async => await _send('POST', '/restaurants', body: body) as Json;
  Future<Json> setStatus(String id, String action, String reason) async => await _send('POST', '/restaurants/$id/status', body: {'action': action, 'reason': reason}) as Json;
  Future<Json> licenseAction(String id, String action, String reason, {String? planCode}) async =>
      await _send('POST', '/restaurants/$id/licenses', body: {'action': action, 'reason': reason, 'planCode': ?planCode}) as Json;
  Future<Json> recordPayment(String id, Json body) async => await _send('POST', '/restaurants/$id/payments', body: body) as Json;
  Future<List<dynamic>> plans() async => await _send('GET', '/plans') as List<dynamic>;

  // ---- platform admins
  Future<List<dynamic>> admins() async => await _send('GET', '/platform/admins') as List<dynamic>;
  Future<List<dynamic>> roles() async => await _send('GET', '/platform/roles') as List<dynamic>;
  Future<Json> invite(String email, String name, List<String> roleIds) async => await _send('POST', '/platform/admins', body: {'email': email, 'name': name, 'roleIds': roleIds}) as Json;
  Future<Json> setRoles(String id, List<String> roleIds) async => await _send('PATCH', '/platform/admins/$id/roles', body: {'roleIds': roleIds}) as Json;
  Future<Json> deactivate(String id, String reason) async => await _send('POST', '/platform/admins/$id/deactivate', body: {'reason': reason}) as Json;
  Future<Json> resetMfa(String id, String reason, String stepUpToken) async =>
      await _send('POST', '/platform/admins/$id/mfa/reset', body: {'reason': reason}, headers: {'x-step-up-token': stepUpToken}) as Json;
  Future<Json> audit({String? action, String? tenantId, int page = 1}) async => await _send('GET', '/platform/audit', query: {
        if (action != null && action.isNotEmpty) 'action': action,
        if (tenantId != null && tenantId.isNotEmpty) 'tenantId': tenantId,
        'page': '$page',
        'pageSize': '50',
      }) as Json;

  // ---- restaurant console (owner / IT admin)
  Future<Json> overview() async => await _send('GET', '/tenant/overview') as Json;
  Future<Json> dashboard({int days = 7}) async => await _send('GET', '/tenant/dashboard', query: {'days': '$days'}) as Json;
  Future<Json> profile() async => await _send('GET', '/tenant/profile') as Json;
  Future<Json> updateProfile(Json body) async => await _send('PATCH', '/tenant/profile', body: body) as Json;

  Future<List<dynamic>> taxRules() async => await _send('GET', '/tax-rules') as List<dynamic>;
  Future<Json> createTaxRule(String name, int rateBp) async => await _send('POST', '/tax-rules', body: {'name': name, 'rateBp': rateBp}) as Json;
  Future<List<dynamic>> categories() async => await _send('GET', '/menu/categories') as List<dynamic>;
  Future<Json> createCategory(String name, {int sortOrder = 0}) async => await _send('POST', '/menu/categories', body: {'name': name, 'sortOrder': sortOrder}) as Json;
  Future<Json> updateCategory(String id, Json body) async => await _send('PATCH', '/menu/categories/$id', body: body) as Json;
  Future<void> deleteCategory(String id) async => _send('DELETE', '/menu/categories/$id');
  Future<List<dynamic>> items() async => await _send('GET', '/menu/items') as List<dynamic>;
  Future<Json> createItem(Json body) async => await _send('POST', '/menu/items', body: body) as Json;
  Future<Json> updateItem(String id, Json body) async => await _send('PATCH', '/menu/items/$id', body: body) as Json;
  Future<void> deleteItem(String id) async => _send('DELETE', '/menu/items/$id');
  Future<Json> setItemImage(String id, String contentType, String dataBase64) async =>
      await _send('PUT', '/menu/items/$id/image', body: {'contentType': contentType, 'dataBase64': dataBase64}) as Json;
  Future<void> removeItemImage(String id) async => _send('DELETE', '/menu/items/$id/image');

  /// Public URL of a menu photo (no auth needed; ids are unguessable).
  String mediaUrl(String id) => '$_base/media/$id';

  Future<List<dynamic>> floors() async => await _send('GET', '/floors') as List<dynamic>;
  Future<Json> createFloor(String branchId, String name, {int sortOrder = 0}) async =>
      await _send('POST', '/floors', body: {'branchId': branchId, 'name': name, 'sortOrder': sortOrder}) as Json;
  Future<Json> updateFloor(String id, Json body) async => await _send('PATCH', '/floors/$id', body: body) as Json;
  Future<void> deleteFloor(String id) async => _send('DELETE', '/floors/$id');
  Future<Json> createTable(String floorId, String name, int seats) async => await _send('POST', '/tables', body: {'floorId': floorId, 'name': name, 'seats': seats}) as Json;
  Future<Json> updateTable(String id, Json body) async => await _send('PATCH', '/tables/$id', body: body) as Json;
  Future<void> deleteTable(String id) async => _send('DELETE', '/tables/$id');

  Future<List<dynamic>> staff() async => await _send('GET', '/staff') as List<dynamic>;
  Future<Json> createStaff(Json body) async => await _send('POST', '/staff', body: body) as Json;
  Future<Json> updateStaff(String id, Json body) async => await _send('PATCH', '/staff/$id', body: body) as Json;

  Future<List<dynamic>> devices() async => await _send('GET', '/devices') as List<dynamic>;
  Future<Json> revokeDevice(String id, String reason) async => await _send('POST', '/devices/$id/revoke', body: {'reason': reason}) as Json;

  /// Base URL the POS app should use for "This device is the hub".
  String get baseUrl => _base;
}
