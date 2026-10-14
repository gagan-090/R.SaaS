import 'dart:typed_data';

import 'download_stub.dart' if (dart.library.js_interop) 'download_web.dart' as impl;

/// Saves bytes as a file in the browser's downloads (tests record the last file instead).
Future<void> saveFile(String name, Uint8List bytes, String mime) => impl.saveFile(name, bytes, mime);

/// The last "downloaded" file in tests / non-web builds.
({String name, Uint8List bytes})? get lastSavedFile => impl.lastSaved;
