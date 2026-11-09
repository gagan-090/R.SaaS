import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

/// A main device answering on the restaurant Wi-Fi: its address, the certificate fingerprint it presented (pinned for
/// everything after), and its /pairing/info (restaurant name, hub name, branch).
typedef ProbedHub = ({String host, int port, String fingerprint, Map<String, dynamic> info});

bool _privateIp(String ip) {
  final p = ip.split('.').map(int.parse).toList();
  return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] >= 16 && p[1] <= 31);
}

/// Finds BhojMitra main devices on this device's Wi-Fi / Ethernet: probes every address of the local /24 network on
/// the hub port (64 at a time, under a second each), or only [onlyHost] when the address was typed in.
/// No multicast or extra permissions needed. The certificate is trusted on first use and pinned from then on.
Future<List<ProbedHub>> probeHubs({String? onlyHost, int port = 8443, Duration timeout = const Duration(milliseconds: 900)}) async {
  final hosts = <String>[];
  if (onlyHost != null) {
    hosts.add(onlyHost);
  } else {
    final own = <String>{};
    for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      final n = ni.name.toLowerCase();
      if (n.startsWith('rmnet') || n.startsWith('ccmni') || n.startsWith('pdp') || n.startsWith('tun')) continue; // mobile data / VPN
      for (final a in ni.addresses) {
        if (!a.isLoopback && !a.isLinkLocal && _privateIp(a.address)) own.add(a.address);
      }
    }
    for (final ip in own) {
      final prefix = ip.substring(0, ip.lastIndexOf('.'));
      for (var i = 1; i < 255; i++) {
        final h = '$prefix.$i';
        if (!own.contains(h) && !hosts.contains(h)) hosts.add(h);
      }
    }
  }
  final found = <ProbedHub>[];
  Future<void> probe(String h) async {
    String? fp;
    final c = HttpClient()
      ..connectionTimeout = timeout
      ..badCertificateCallback = (cert, host, p) {
        fp = _fp(cert);
        return true; // trust on first use: only /pairing/info is read this way
      };
    try {
      final req = await c.getUrl(Uri.parse('https://$h:$port/hub/v1/pairing/info')).timeout(timeout);
      final res = await req.close().timeout(timeout * 2);
      if (res.statusCode != 200) return;
      final j = jsonDecode(await res.transform(utf8.decoder).join().timeout(timeout * 2));
      if (j is! Map<String, dynamic> || fp == null || !j.containsKey('certFingerprint')) return;
      if (j['certFingerprint'] != null && j['certFingerprint'] != fp) return; // the certificate is not the one it claims
      found.add((host: h, port: port, fingerprint: fp!, info: j));
    } catch (_) {
      // nothing listening there
    } finally {
      c.close(force: true);
    }
  }

  for (var i = 0; i < hosts.length; i += 64) {
    await Future.wait(hosts.sublist(i, math.min(i + 64, hosts.length)).map(probe));
  }
  return found;
}
