import 'dart:typed_data';
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

  /// A file from the API (templates, reports), with the same sign-in and refresh as JSON calls.
  Future<Uint8List> getBytes(String path, {bool retry = true}) async {
    final req = http.Request('GET', Uri.parse('$_base$path'));
    if (accessToken != null) req.headers['authorization'] = 'Bearer $accessToken';
    final res = await http.Response.fromStream(await _http.send(req));
    if (res.statusCode == 401 && retry && refreshToken != null && await _refresh()) return getBytes(path, retry: false);
    if (res.statusCode >= 400) {
      final m = (() {
        try {
          return jsonDecode(utf8.decode(res.bodyBytes)) as Map;
        } catch (_) {
          return const {};
        }
      })();
      throw ApiException(res.statusCode, '${m['code'] ?? 'http_${res.statusCode}'}', '${m['message'] ?? 'Download failed (${res.statusCode})'}');
    }
    return res.bodyBytes;
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

  /// Employee web portal: email + PIN (plan feature "staff_portal").
  Future<Json> pinLogin(String email, String pin) async {
    final r = await _send('POST', '/auth/pin-login', body: {'email': email, 'pin': pin}) as Json;
    if (r['status'] == 'ok') _setTokens(r);
    return r;
  }

  Future<Json> pinResetRequest(String email) async => await _send('POST', '/auth/pin-reset-request', body: {'email': email}) as Json;
  Future<Json> pinLinkCheck(String token) async => await _send('POST', '/auth/pin-link/check', body: {'token': token}) as Json;
  Future<Json> pinLinkComplete(String token, String pin) async => await _send('POST', '/auth/pin-link/complete', body: {'token': token, 'pin': pin}) as Json;

  Future<void> verifyMfa(String challengeToken, {String? code, String? recoveryCode}) async =>
      _setTokens(await _send('POST', '/auth/mfa/verify', body: {'challengeToken': challengeToken, 'code': ?code, 'recoveryCode': ?recoveryCode}) as Json);

  Future<Json> enrollStart(String enrollmentToken) async => await _send('POST', '/me/mfa/enroll', bearer: enrollmentToken) as Json;

  Future<List<String>> enrollConfirm(String enrollmentToken, String code) async {
    final r = await _send('POST', '/me/mfa/confirm', body: {'code': code}, bearer: enrollmentToken) as Json;
    if (r['tokens'] != null) _setTokens(r['tokens'] as Json);
    return (r['recoveryCodes'] as List).cast<String>();
  }

  Future<String> stepUp(String password, String code) async => (await _send('POST', '/auth/step-up', body: {'password': password, if (code.isNotEmpty) 'code': code}) as Json)['stepUpToken'] as String;
  Future<Json> setAdminMfa(String id, bool enabled, String reason, String stepUpToken) async => await _send('POST', '/platform/admins/$id/mfa/policy', body: {'enabled': enabled, 'reason': reason}, headers: {'x-step-up-token': stepUpToken}) as Json;

  Future<void> logout() async {
    if (refreshToken != null) {
      try {
        await _send('POST', '/auth/logout', body: {'refreshToken': refreshToken});
      } catch (_) {}
    }
    accessToken = refreshToken = null;
  }

  Future<Json> me() async => await _send('GET', '/me') as Json;

  /// Owner opens the emailed link: confirms the email, sets the password, and the restaurant is created.
  Future<Json> verifyEmail(String token, String password) async =>
      await _send('POST', '/restaurants/verify-email', body: {'token': token, 'password': password}) as Json;

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
  Future<Json> registrations({String state = 'awaiting', String? q}) async =>
      await _send('GET', '/restaurants/registrations', query: {'state': state, if (q != null && q.isNotEmpty) 'q': q}) as Json;
  Future<Json> resendVerification(String id) async => await _send('POST', '/restaurants/registrations/$id/resend') as Json;
  Future<Json> cancelRegistration(String id, String reason) async => await _send('POST', '/restaurants/registrations/$id/cancel', body: {'reason': reason}) as Json;
  Future<Json> restaurant(String id) async => await _send('GET', '/restaurants/$id') as Json;
  Future<Json> registerRestaurant(Json body) async => await _send('POST', '/restaurants', body: body) as Json;
  Future<Json> setStatus(String id, String action, String reason) async => await _send('POST', '/restaurants/$id/status', body: {'action': action, 'reason': reason}) as Json;
  Future<Json> licenseAction(String id, String action, String reason, {String? planCode}) async =>
      await _send('POST', '/restaurants/$id/licenses', body: {'action': action, 'reason': reason, 'planCode': ?planCode}) as Json;
  Future<Json> archiveRestaurant(String id, String reason) async => await _send('POST', '/restaurants/$id/archive', body: {'reason': reason}) as Json;
  Future<Uint8List> downloadArchive(String id) => getBytes('/restaurants/$id/archive/download');
  Future<Json> restoreRestaurant(String id, String reason) async => await _send('POST', '/restaurants/$id/restore', body: {'reason': reason}) as Json;
  Future<Json> deleteRestaurant(String id, String reason) async => await _send('POST', '/restaurants/$id/delete', body: {'reason': reason}) as Json;
  Future<Json> recordPayment(String id, Json body) async => await _send('POST', '/restaurants/$id/payments', body: body) as Json;

  Future<List<dynamic>> plans({bool includeArchived = false}) async =>
      await _send('GET', '/plans', query: {if (includeArchived) 'includeArchived': 'true'}) as List<dynamic>;
  Future<Json> createPlan(Json body) async => await _send('POST', '/plans', body: body) as Json;
  Future<Json> updatePlan(String id, Json body) async => await _send('PATCH', '/plans/$id', body: body) as Json;

  // ---- platform admins
  Future<List<dynamic>> admins() async => await _send('GET', '/platform/admins') as List<dynamic>;
  Future<List<dynamic>> roles() async => await _send('GET', '/platform/roles') as List<dynamic>;
  Future<Json> invite(String email, String name, List<String> roleIds) async => await _send('POST', '/platform/admins', body: {'email': email, 'name': name, 'roleIds': roleIds}) as Json;
  Future<Json> createAdmin(String email, String name, String password) async => await _send('POST', '/platform/admins/create', body: {'email': email, 'name': name, 'password': password}) as Json;
  Future<Json> activateAdmin(String id, String password) async => await _send('POST', '/platform/admins/$id/activate', body: {'password': password}) as Json;
  Future<Json> setRoles(String id, List<String> roleIds) async => await _send('PATCH', '/platform/admins/$id/roles', body: {'roleIds': roleIds}) as Json;
  Future<Json> deactivate(String id, String reason) async => await _send('POST', '/platform/admins/$id/deactivate', body: {'reason': reason}) as Json;
  Future<Json> deleteAdmin(String id, String reason) async => await _send('POST', '/platform/admins/$id/delete', body: {'reason': reason}) as Json;
  Future<Json> resetMfa(String id, String reason, String stepUpToken) async =>
      await _send('POST', '/platform/admins/$id/mfa/reset', body: {'reason': reason}, headers: {'x-step-up-token': stepUpToken}) as Json;

  // ---- platform attention & audit
  Future<Json> attention() async => await _send('GET', '/platform/attention') as Json;
  Future<Json> audit({String? category, String? action, String? tenantId, String? q, String? from, String? to, int page = 1}) async => await _send('GET', '/platform/audit', query: {
        if (category != null && category.isNotEmpty) 'category': category,
        if (action != null && action.isNotEmpty) 'action': action,
        if (tenantId != null && tenantId.isNotEmpty) 'tenantId': tenantId,
        if (q != null && q.isNotEmpty) 'q': q,
        if (from != null && from.isNotEmpty) 'from': from,
        if (to != null && to.isNotEmpty) 'to': to,
        'page': '$page',
        'pageSize': '50',
      }) as Json;

  // ---- restaurant console (owner / IT admin)
  Future<Json> overview() async => await _send('GET', '/tenant/overview') as Json;
  Future<Json> dashboard({String range = '7d'}) async => await _send('GET', '/tenant/dashboard', query: {'range': range}) as Json;
  Future<Json> billDetail(String id) async => await _send('GET', '/tenant/bills/$id') as Json;
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
  Future<Json> setVariants(String id, List<Json> variants) async => await _send('PUT', '/menu/items/$id/variants', body: {'variants': variants}) as Json;
  Future<void> orderCategories(List<String> ids) async => _send('PUT', '/menu/categories/order', body: {'ids': ids});
  Future<void> deleteItem(String id) async => _send('DELETE', '/menu/items/$id');
  Future<Json> setItemImage(String id, String contentType, String dataBase64) async =>
      await _send('PUT', '/menu/items/$id/image', body: {'contentType': contentType, 'dataBase64': dataBase64}) as Json;
  Future<void> removeItemImage(String id) async => _send('DELETE', '/menu/items/$id/image');

  /// Public URL of a menu photo (no auth needed; ids are unguessable).
  String mediaUrl(String id) => '$_base/media/$id';

  // ---- inventory (plan feature "inventory")
  Future<List<dynamic>> invProducts({bool includeInactive = false}) async =>
      await _send('GET', '/inventory/products', query: {if (includeInactive) 'includeInactive': 'true'}) as List<dynamic>;
  Future<Json> createInvProduct(Json body) async => await _send('POST', '/inventory/products', body: body) as Json;
  Future<Json> updateInvProduct(String id, Json body) async => await _send('PATCH', '/inventory/products/$id', body: body) as Json;
  Future<List<dynamic>> invLocations() async => await _send('GET', '/inventory/locations') as List<dynamic>;
  Future<Json> createLocation(String name) async => await _send('POST', '/inventory/locations', body: {'name': name}) as Json;
  Future<List<dynamic>> invSuppliers() async => await _send('GET', '/inventory/suppliers') as List<dynamic>;
  Future<Json> createSupplier(Json body) async => await _send('POST', '/inventory/suppliers', body: body) as Json;
  Future<Json> invMove(Json body) async => await _send('POST', '/inventory/movements', body: body) as Json;
  Future<List<dynamic>> invMovements({String? type, String? productId}) async =>
      await _send('GET', '/inventory/movements', query: {'type': ?type, 'productId': ?productId}) as List<dynamic>;
  Future<Json> invAlerts() async => await _send('GET', '/inventory/alerts') as Json;
  Future<Json> invValuation() async => await _send('GET', '/inventory/valuation') as Json;
  Future<List<dynamic>> invRequests() async => await _send('GET', '/inventory/requests') as List<dynamic>;
  Future<Json> invRequest(Json body) async => await _send('POST', '/inventory/requests', body: body) as Json;
  Future<Json> invUpdateRequest(String id, String status) async => await _send('PATCH', '/inventory/requests/$id', body: {'status': status}) as Json;
  Future<Json> recipe(String variantId) async => await _send('GET', '/menu/variants/$variantId/recipe') as Json;
  Future<Json> setRecipe(String variantId, List<Json> lines) async => await _send('PUT', '/menu/variants/$variantId/recipe', body: {'lines': lines}) as Json;

  // ---- Excel import (plan feature "import.excel")
  Future<Uint8List> importTemplate(String kind) => getBytes('/imports/templates/$kind');
  Future<Json> validateImport(String kind, String fileName, String dataBase64, String mode) async =>
      await _send('POST', '/imports/$kind/validate', body: {'fileName': fileName, 'dataBase64': dataBase64, 'mode': mode}) as Json;
  Future<Json> commitImport(String id, {bool partial = false}) async => await _send('POST', '/imports/$id/commit', body: {'partial': partial}) as Json;
  Future<List<dynamic>> imports() async => await _send('GET', '/imports') as List<dynamic>;
  Future<Uint8List> importErrorReport(String id) => getBytes('/imports/$id/errors.csv');

  // ---- audit & records (read-only)
  Future<List<dynamic>> auditEvents(Map<String, String> q) async => await _send('GET', '/audit/events', query: q) as List<dynamic>;
  Future<Uint8List> auditCsv(Map<String, String> q) => getBytes('/audit/events.csv${q.isEmpty ? '' : '?${Uri(queryParameters: q).query}'}');
  Future<Json> auditFacets() async => await _send('GET', '/audit/facets') as Json;
  Future<List<dynamic>> auditImports() async => await _send('GET', '/audit/imports') as List<dynamic>;
  Future<Json> salesRecords(Map<String, String> q) async => await _send('GET', '/records/sales', query: q) as Json;
  Future<Uint8List> salesCsv(Map<String, String> q) => getBytes('/records/sales.csv?${Uri(queryParameters: q).query}');
  Future<List<dynamic>> liveOrders() async => await _send('GET', '/records/live-orders') as List<dynamic>;

  // ---- expenses (plan feature "expenses")
  Future<Json> expenses({bool includeVoided = false}) async => await _send('GET', '/expenses', query: {if (includeVoided) 'includeVoided': 'true'}) as Json;
  Future<Json> createExpense(Json body) async => await _send('POST', '/expenses', body: body) as Json;
  Future<Json> voidExpense(String id, String reason) async => await _send('POST', '/expenses/$id/void', body: {'reason': reason}) as Json;

  // ---- branding (plan feature "branding")
  Future<Json> branding() async => await _send('GET', '/tenant/branding') as Json;
  Future<Json> setBranding(Json body) async => await _send('PUT', '/tenant/branding', body: body) as Json;
  Future<Json> setLogo(String contentType, String dataBase64) async =>
      await _send('PUT', '/tenant/branding/logo', body: {'contentType': contentType, 'dataBase64': dataBase64}) as Json;
  Future<void> removeLogo() async => _send('DELETE', '/tenant/branding/logo');

  Future<List<dynamic>> floors() async => await _send('GET', '/floors') as List<dynamic>;
  Future<Json> floorLayout(String floorId) async => await _send('GET', '/floors/$floorId/layout') as Json;
  Future<Json> saveFloorLayout(String floorId, Json body) async => await _send('PUT', '/floors/$floorId/layout', body: body) as Json;
  Future<Json> setTableStatus(String tableId, String status) async => await _send('POST', '/tables/$tableId/status', body: {'status': status}) as Json;
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
  Future<Json> staffLimits() async => await _send('GET', '/staff/limits') as Json;
  Future<Json> staffPinLink(String id) async => await _send('POST', '/staff/$id/pin-link') as Json;
  Future<Json> staffUnlock(String id) async => await _send('POST', '/staff/$id/unlock') as Json;
  Future<Json> restaurantRoles() async => await _send('GET', '/roles') as Json;
  Future<Json> createRole(Json body) async => await _send('POST', '/roles', body: body) as Json;
  Future<Json> updateRole(String id, Json body) async => await _send('PATCH', '/roles/$id', body: body) as Json;
  Future<void> deleteRole(String id) async => _send('DELETE', '/roles/$id');
  Future<void> setMyPin(String pin) async => _send('PUT', '/me/pin', body: {'pin': pin});

  Future<List<dynamic>> devices() async => await _send('GET', '/devices') as List<dynamic>;
  Future<Json> revokeDevice(String id, String reason) async => await _send('POST', '/devices/$id/revoke', body: {'reason': reason}) as Json;

  /// Base URL the POS app should use for "This device is the hub".
  String get baseUrl => _base;
}
