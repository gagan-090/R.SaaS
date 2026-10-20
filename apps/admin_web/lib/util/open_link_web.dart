import 'package:web/web.dart' as web;

String? lastOpened;

void openLink(String url) {
  lastOpened = url;
  web.window.open(url, '_blank', 'noopener');
}
