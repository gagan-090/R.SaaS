import 'dart:typed_data';

({String name, Uint8List bytes})? lastSaved;

Future<void> saveFile(String name, Uint8List bytes, String mime) async => lastSaved = (name: name, bytes: bytes);
