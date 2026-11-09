import 'open_link_stub.dart'
    if (dart.library.js_interop) 'open_link_web.dart'
    if (dart.library.io) 'open_link_io.dart' as impl;

/// Opens [url] in a new browser tab (web) or the system browser (native) (tests record the last link instead).
void openLink(String url) => impl.openLink(url);

/// The last link "opened" in tests / non-web builds.
String? get lastOpenedLink => impl.lastOpened;
