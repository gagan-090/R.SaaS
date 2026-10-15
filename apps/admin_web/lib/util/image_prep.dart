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

/// A restaurant logo for `PUT /tenant/branding/logo`: longest side at most 512 px, PNG so transparency survives.
PreparedImage prepareLogo(Uint8List raw, {int maxSide = 512}) {
  final decoded = img.decodeImage(raw);
  if (decoded == null) throw const FormatException('That file is not an image we can read (use JPG, PNG or WebP).');
  final big = decoded.width > maxSide || decoded.height > maxSide;
  final out = !big ? decoded : (decoded.width >= decoded.height ? img.copyResize(decoded, width: maxSide) : img.copyResize(decoded, height: maxSide));
  final png = img.encodePng(out);
  return (contentType: 'image/png', base64: base64Encode(png), bytes: png);
}

/// Opens the file chooser for one image. Null when the user cancels.
Future<Uint8List?> pickPhoto() async {
  final r = await FilePicker.pickFiles(type: FileType.image, withData: true);
  return r?.files.single.bytes;
}

/// Floor plans keep their original aspect ratio, with a bounded upload size.
PreparedImage prepareFloorPhoto(Uint8List raw) {
  if (raw.length > 15 * 1024 * 1024) throw const FormatException('Choose an image smaller than 15 MB.');
  final decoded = img.decodeImage(raw);
  if (decoded == null) throw const FormatException('Choose a JPG, PNG or WebP floor image.');
  final resized = decoded.width >= decoded.height ? img.copyResize(decoded, width: 1200) : img.copyResize(decoded, height: 1200);
  final bytes = img.encodeJpg(resized, quality: 72);
  if (bytes.length > 650000) throw const FormatException('This image is too detailed. Choose a smaller floor plan.');
  return (contentType: 'image/jpeg', base64: base64Encode(bytes), bytes: bytes);
}
