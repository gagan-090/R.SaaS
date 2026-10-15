import 'package:web/web.dart' as web;
const _key = 'house-plating.session.v1';
String? readSession() { try { return web.window.sessionStorage.getItem(_key); } catch (_) { return null; } }
void writeSession(String? value) { try { if (value == null) { web.window.sessionStorage.removeItem(_key); } else { web.window.sessionStorage.setItem(_key, value); } } catch (_) {} }
