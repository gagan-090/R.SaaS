import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;

/// A photo ready for `PUT /menu/items/:id/image`: square-cropped to 640 px and JPEG-compressed in the browser,
/// so uploads stay small and every dish photo fits the plate circle the POS draws.
typedef PreparedImage = ({String contentType, String base64, Uint8List bytes});

PreparedImage prepareDishPhoto(Uint8List raw, {int size = 640, int quality = 82}) {
  final decoded = img.decodeImage(raw);
  if (decoded == null) throw const FormatException('That file is not a photo we can read (use JPG, PNG or WebP).');
  final square = img.copyResizeCropSquare(decoded, size: decoded.width < size || decoded.height < size ? (decoded.width < decoded.height ? decoded.width : decoded.height) : size);
  final jpg = img.encodeJpg(square, quality: quality);
  return (contentType: 'image/jpeg', base64: base64Encode(jpg), bytes: jpg);
}

/// Opens the file chooser for one image. Null when the user cancels.
Future<Uint8List?> pickPhoto() async {
  final r = await FilePicker.pickFiles(type: FileType.image, withData: true);
  return r?.files.single.bytes;
}
