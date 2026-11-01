import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/community/community.dart';
import '../../domain/sos/sos_outbox.dart' show OutboxStorage;
import 'community_repository.dart';
import 'photo_compress.dart';

// Trail reports written without signal (COMMUNITY_PRD.md 8.6): the report and its compressed
// photos stay on the phone and are sent as soon as the connection is back. Each step is
// written down as it succeeds (post created, n photos sent), so a send that stops halfway
// goes on where it stopped instead of posting twice. A report the server refuses (daily
// limit, blocked account) stays with its message until the user sends it again or drops it.

const communityOutboxKey = 'l360-community-outbox';

/// Where the photos of queued reports wait (files, not preferences: up to 4 × 700 KB each)
abstract interface class OutboxFiles {
  Future<void> write(String name, Uint8List bytes);
  Future<Uint8List?> read(String name);
  Future<void> delete(String name);
}

class DiskOutboxFiles implements OutboxFiles {
  Future<Directory> get _dir async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'community-outbox'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String name) async => File(p.join((await _dir).path, name));

  @override
  Future<void> write(String name, Uint8List bytes) async => (await _file(name)).writeAsBytes(bytes, flush: true);

  @override
  Future<Uint8List?> read(String name) async {
    final f = await _file(name);
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<void> delete(String name) async {
    final f = await _file(name);
    if (await f.exists()) await f.delete();
  }
}

class OutboxPhoto {
  const OutboxPhoto({required this.file, required this.width, required this.height});

  factory OutboxPhoto.fromJson(Map<String, dynamic> j) =>
      OutboxPhoto(file: '${j['file']}', width: (j['width'] as num).toInt(), height: (j['height'] as num).toInt());

  final String file;
  final int width;
  final int height;

  Map<String, dynamic> toJson() => {'file': file, 'width': width, 'height': height};
}

/// A report waiting to be sent
class OutboxItem {
  const OutboxItem({
    required this.clientId,
    required this.userId,
    required this.post,
    this.photos = const [],
    required this.queuedAt,
    this.postId,
    this.photosSent = 0,
    this.error,
  });

  factory OutboxItem.fromJson(Map<String, dynamic> j) => OutboxItem(
    clientId: '${j['clientId']}',
    userId: '${j['userId']}',
    post: NewPost.fromJson(Map<String, dynamic>.from(j['post'] as Map)),
    photos: [
      for (final x in (j['photos'] as List? ?? const [])) OutboxPhoto.fromJson(Map<String, dynamic>.from(x as Map)),
    ],
    queuedAt: DateTime.tryParse('${j['queuedAt']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
    postId: j['postId'] as String?,
    photosSent: (j['photosSent'] as num? ?? 0).toInt(),
    error: j['error'] as String?,
  );

  final String clientId;
  final String userId;
  final NewPost post;
  final List<OutboxPhoto> photos;
  final DateTime queuedAt;
  final String? postId; // set once the server has the post
  final int photosSent;
  final String? error; // the server refused it: waits for the user

  OutboxItem copyWith({String? postId, int? photosSent, String? Function()? error}) => OutboxItem(
    clientId: clientId,
    userId: userId,
    post: post,
    photos: photos,
    queuedAt: queuedAt,
    postId: postId ?? this.postId,
    photosSent: photosSent ?? this.photosSent,
    error: error == null ? this.error : error(),
  );

  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    'userId': userId,
    'post': post.toJson(),
    'photos': [for (final x in photos) x.toJson()],
    'queuedAt': queuedAt.toUtc().toIso8601String(),
    'postId': postId,
    'photosSent': photosSent,
    'error': error,
  };
}

/// What a flush did: the posts that reached the server and whether it is still offline
typedef FlushResult = ({List<String> sentPostIds, bool offline});

final _random = math.Random();

String _clientId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${_random.nextInt(1 << 32).toRadixString(16)}';

class CommunityOutbox {
  CommunityOutbox({required this.storage, required this.files, required CommunityRepository Function() repository})
    : _repository = repository; // ignore: prefer_initializing_formals

  final OutboxStorage storage;
  final OutboxFiles files;

  // Made only when something is sent (signed-out phones and tests never need the server)
  final CommunityRepository Function() _repository;
  Future<FlushResult>? _flushing;

  Future<List<OutboxItem>> _read() async {
    try {
      final raw = jsonDecode(await storage.read(communityOutboxKey) ?? '[]');
      if (raw is! List) return [];
      return [
        for (final x in raw)
          if (x is Map) OutboxItem.fromJson(Map<String, dynamic>.from(x)),
      ];
    } on Object {
      return [];
    }
  }

  Future<void> _write(List<OutboxItem> items) =>
      storage.write(communityOutboxKey, jsonEncode([for (final x in items) x.toJson()]));

  Future<void> _replace(OutboxItem item) async {
    final items = await _read();
    await _write([for (final x in items) x.clientId == item.clientId ? item : x]);
  }

  /// Reports of this account still on the phone, oldest first
  Future<List<OutboxItem>> pending(String userId) async => [
    for (final x in await _read())
      if (x.userId == userId) x,
  ];

  /// Keeps a trail report and its photos on the phone until it can be sent
  Future<OutboxItem> queue(String userId, NewPost post, List<CompressedPhoto> photos, {DateTime? now}) async {
    final id = _clientId();
    final saved = <OutboxPhoto>[];
    for (final (n, photo) in photos.indexed) {
      final name = '$id-$n.jpg';
      await files.write(name, photo.bytes);
      saved.add(OutboxPhoto(file: name, width: photo.width, height: photo.height));
    }
    final item = OutboxItem(
      clientId: id,
      userId: userId,
      post: post,
      photos: saved,
      queuedAt: (now ?? DateTime.now()).toUtc(),
    );
    await _write([...await _read(), item]);
    return item;
  }

  /// Drops a queued report (and its photos) without sending it
  Future<void> discard(String clientId) async {
    final items = await _read();
    for (final x in items.where((x) => x.clientId == clientId)) {
      for (final photo in x.photos) {
        await files.delete(photo.file).catchError((Object _) {});
      }
    }
    await _write(items.where((x) => x.clientId != clientId).toList());
  }

  /// A report the server refused goes back in line (e.g. the next day, under the limit)
  Future<void> retry(String clientId) async {
    final item = (await _read()).where((x) => x.clientId == clientId).firstOrNull;
    if (item != null) await _replace(item.copyWith(error: () => null));
  }

  /// Sends this account's waiting reports, one after the other; stops at the first that
  /// cannot reach the server. Only one flush runs at a time.
  Future<FlushResult> flush(String userId) {
    final running = _flushing;
    if (running != null) return running;
    final future = _flush(userId);
    _flushing = future;
    future.then((_) {}, onError: (_) {}).whenComplete(() => _flushing = null);
    return future;
  }

  Future<FlushResult> _flush(String userId) async {
    final sent = <String>[];
    for (var item in await pending(userId)) {
      if (item.error != null) continue;
      try {
        var postId = item.postId;
        if (postId == null) {
          postId = await _repository().create(item.post);
          item = item.copyWith(postId: postId);
          await _replace(item);
        }
        for (var n = item.photosSent; n < item.photos.length; n++) {
          final photo = item.photos[n];
          final bytes = await files.read(photo.file);
          if (bytes != null) {
            await _repository().addPhoto(
              userId,
              postId,
              n,
              CompressedPhoto(bytes: bytes, width: photo.width, height: photo.height),
            );
          }
          item = item.copyWith(photosSent: n + 1);
          await _replace(item);
        }
        await discard(item.clientId);
        sent.add(postId);
      } on CommunityException catch (e) {
        if (e.offline) return (sentPostIds: sent, offline: true);
        await _replace(item.copyWith(error: () => e.message));
      }
    }
    return (sentPostIds: sent, offline: false);
  }
}
