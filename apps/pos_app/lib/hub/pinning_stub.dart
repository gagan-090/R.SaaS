import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Browsers cannot pin self-signed certificates; the POS is not a web target (web build is for CI compile checks only).
http.Client pinnedHttpClient(String? fingerprint) => http.Client();

WebSocketChannel connectPinnedWebSocket(Uri uri, String? fingerprint) => WebSocketChannel.connect(uri);

typedef ProbedHub = ({String host, int port, String fingerprint, Map<String, dynamic> info});

/// No LAN scanning in a browser.
Future<List<ProbedHub>> probeHubs({String? onlyHost, int port = 8443, Duration timeout = const Duration(milliseconds: 900)}) async => const [];
