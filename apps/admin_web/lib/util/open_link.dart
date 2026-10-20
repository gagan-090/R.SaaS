import 'open_link_stub.dart' if (dart.library.js_interop) 'open_link_web.dart' as impl;

/// Opens [url] in a new browser tab (tests record the last link instead).
void openLink(String url) => impl.openLink(url);

/// The last link "opened" in tests / non-web builds.
String? get lastOpenedLink => impl.lastOpened;
