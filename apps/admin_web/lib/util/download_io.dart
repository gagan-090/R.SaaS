import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

({String name, Uint8List bytes})? lastSaved;

/// Android / iOS / Windows: a native "Save as" dialog. Widget tests only record the file (no plugin host).
Future<void> saveFile(String name, Uint8List bytes, String mime) async {
  lastSaved = (name: name, bytes: bytes);
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? null : name.substring(dot + 1);
  final path = await FilePicker.saveFile(
    fileName: name,
    bytes: bytes,
    type: ext == null ? FileType.any : FileType.custom,
    allowedExtensions: ext == null ? null : [ext],
  );
  // Mobile plugins write the bytes themselves; on desktop the dialog only returns the chosen path.
  if (path != null && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    await File(path).writeAsBytes(bytes, flush: true);
  }
}
