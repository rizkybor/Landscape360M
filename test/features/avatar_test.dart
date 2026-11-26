import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:landscape360/data/community/photo_compress.dart' show PhotoException;
import 'package:landscape360/domain/account/avatar.dart';
import 'package:landscape360/domain/account/profile.dart';

// Profile photo: the stored file is the middle square at most 256 px, a JPEG within the
// bucket's 100 KB, without the file's metadata; the path and address the apps agree on

Uint8List _png(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(40, 120, 60));
  // A mark on the left edge: a middle crop must lose it
  img.fillRect(image, x1: 0, y1: 0, x2: 10, y2: h - 1, color: img.ColorRgb8(255, 0, 0));
  return img.encodePng(image);
}

void main() {
  test('the middle square, at most 256 px, as a small JPEG', () {
    final out = makeAvatar(_png(1200, 800));
    expect(out.length, lessThanOrEqualTo(avatarMaxBytes));
    final decoded = img.decodeJpg(out)!;
    expect((decoded.width, decoded.height), (256, 256));
    final left = decoded.getPixel(0, 128);
    expect(left.r > 200 && left.g < 80, isFalse, reason: 'the red edge was cropped away');
    final small = img.decodeJpg(makeAvatar(_png(100, 160)))!;
    expect((small.width, small.height), (100, 100), reason: 'small photos are not enlarged');
  });

  test('junk and oversized files are refused', () {
    expect(() => makeAvatar(Uint8List.fromList([1, 2, 3])), throwsA(isA<PhotoException>()));
    expect(() => makeAvatar(Uint8List(avatarPickMaxBytes + 1)), throwsA(isA<PhotoException>()));
  });

  test('the path and the public address', () {
    expect(avatarPathFor('u1', 1700000000000), 'u1/avatar-1700000000000.jpg');
    expect(
      avatarUrl('https://x.supabase.co/', 'u1/avatar-1.jpg'),
      'https://x.supabase.co/storage/v1/object/public/avatars/u1/avatar-1.jpg',
    );
    expect(squareCrop(1200, 800), (x: 200, y: 0, side: 800));
  });

  test('the profile carries the photo path', () {
    final p = AccountProfile.resolve(
      userId: 'u',
      email: 'a@x.id',
      displayName: 'A',
      row: {'avatar_path': 'u/avatar-1.jpg'},
    );
    expect(p.avatarPath, 'u/avatar-1.jpg');
    expect(
      AccountProfile.resolve(userId: 'u', email: 'a@x.id', displayName: 'A', row: {'avatar_path': ' '}).avatarPath,
      isNull,
    );
  });
}
