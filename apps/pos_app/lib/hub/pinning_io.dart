import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

String _fp(X509Certificate c) => sha256.convert(c.der).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':').toUpperCase();

/// Accepts the hub's self-signed certificate only when its SHA-256 fingerprint equals the one from the pairing QR.
HttpClient _pinned(String? fingerprint) => HttpClient()
  ..connectionTimeout = const Duration(seconds: 5)
  ..badCertificateCallback = (cert, host, port) => fingerprint != null && _fp(cert) == fingerprint;

http.Client pinnedHttpClient(String? fingerprint) => IOClient(_pinned(fingerprint));

WebSocketChannel connectPinnedWebSocket(Uri uri, String? fingerprint) =>
    IOWebSocketChannel.connect(uri, customClient: _pinned(fingerprint));
