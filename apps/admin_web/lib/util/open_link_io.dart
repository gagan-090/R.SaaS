import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

String? lastOpened;

/// Android / iOS / Windows: opens [url] in the system browser. Widget tests only record it.
void openLink(String url) {
  lastOpened = url;
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  final uri = Uri.tryParse(url);
  if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
}
