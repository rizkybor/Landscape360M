import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

// Photos for Community (compressPhoto in src/lib/community.ts): at most 1600 px on the longest
// side (a club photo 640 px), re-encoded as JPEG at quality 80 (lower until it fits 700 KB, the
// bucket's limit). Re-encoding writes the pixels only: the camera's metadata (EXIF, including where the photo
// was taken) is not carried over. The camera's rotation is applied to the pixels first.

const maxPhotoSide = 1600;
const maxPhotoBytes = 700 * 1024;

class CompressedPhoto {
  const CompressedPhoto({required this.bytes, required this.width, required this.height});

  final Uint8List bytes; // JPEG
  final int width;
  final int height;
}

class PhotoException implements Exception {
  const PhotoException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Compresses on this isolate (tests); the app uses [compressPhotoInBackground]
CompressedPhoto compressPhoto(Uint8List original, {int maxSide = maxPhotoSide}) {
  final decoded = img.decodeImage(original);
  if (decoded == null) throw const PhotoException('This file is not a photo the app can read (use JPEG or PNG).');
  var image = img.bakeOrientation(decoded);
  final longest = image.width > image.height ? image.width : image.height;
  if (longest > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: maxSide, interpolation: img.Interpolation.average);
  }
  // Nothing of the original file's metadata goes along
  image.exif = img.ExifData();
  image.iccProfile = null;
  image.textData = null;
  for (final quality in const [80, 70, 60, 50]) {
    final bytes = img.encodeJpg(image, quality: quality);
    if (bytes.length <= maxPhotoBytes) return CompressedPhoto(bytes: bytes, width: image.width, height: image.height);
  }
  throw const PhotoException('This photo is too large even after compressing it.');
}

/// [compressPhoto] off the UI thread (decoding a 12 MP photo takes a moment)
Future<CompressedPhoto> compressPhotoInBackground(Uint8List original, {int maxSide = maxPhotoSide}) =>
    Isolate.run(() => compressPhoto(original, maxSide: maxSide));
