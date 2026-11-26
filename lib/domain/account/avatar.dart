import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../data/community/photo_compress.dart' show PhotoException;

// Profile photo (src/lib/avatar.ts on the web, 20261127000035_profile_avatar.sql): a square
// JPEG of at most 256 px in the public "avatars" bucket, in the account's own folder
// (<user id>/avatar-<time>.jpg); profiles.avatar_path points at it and changes only through
// set_my_avatar(). The bucket takes at most 100 KB per file.

const avatarBucket = 'avatars';

/// Width and height of the stored photo (px)
const avatarSide = 256;

/// The bucket's limit (keep in sync with the migration); a 256 px JPEG is usually 15–40 KB
const avatarMaxBytes = 100 * 1024;

/// Larger picked files are refused before reading them
const avatarPickMaxBytes = 10 * 1024 * 1024;

/// Public address of a photo in the avatars bucket
String avatarUrl(String supabaseUrl, String path) =>
    '${supabaseUrl.replaceAll(RegExp(r'/+$'), '')}/storage/v1/object/public/$avatarBucket/$path';

/// Where my new photo goes (the server checks this shape)
String avatarPathFor(String userId, int nowMs) => '$userId/avatar-$nowMs.jpg';

/// The middle square of an image (where a face usually is): x, y and side
({int x, int y, int side}) squareCrop(int width, int height) {
  final side = width < height ? width : height;
  return (x: (width - side) ~/ 2, y: (height - side) ~/ 2, side: side);
}

/// A picked image as the stored photo: the middle square, at most 256 px, JPEG within 100 KB
Uint8List makeAvatar(Uint8List original) {
  if (original.length > avatarPickMaxBytes) {
    throw const PhotoException('This photo is larger than 10 MB. Pick a smaller one.');
  }
  final decoded = img.decodeImage(original);
  if (decoded == null) throw const PhotoException('This file is not a photo the app can read (use JPEG or PNG).');
  var image = img.bakeOrientation(decoded);
  final c = squareCrop(image.width, image.height);
  image = img.copyCrop(image, x: c.x, y: c.y, width: c.side, height: c.side);
  if (image.width > avatarSide) {
    image = img.copyResize(image, width: avatarSide, height: avatarSide, interpolation: img.Interpolation.average);
  }
  // White behind transparent PNGs (JPEG has no transparency); nothing of the file's metadata
  if (image.hasAlpha) {
    final white = img.Image(width: image.width, height: image.height);
    img.fill(white, color: img.ColorRgb8(255, 255, 255));
    image = img.compositeImage(white, image);
  }
  image.exif = img.ExifData();
  image.iccProfile = null;
  image.textData = null;
  for (final quality in const [80, 70, 60, 50]) {
    final bytes = img.encodeJpg(image, quality: quality);
    if (bytes.length <= avatarMaxBytes) return bytes;
  }
  throw const PhotoException('This photo is too large even after compressing it.');
}

/// [makeAvatar] off the UI thread
Future<Uint8List> makeAvatarInBackground(Uint8List original) => Isolate.run(() => makeAvatar(original));
