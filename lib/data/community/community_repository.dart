import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/community/community.dart';
import '../../domain/community/community_attachments.dart';
import '../../domain/sos/sos_outbox.dart' show OutboxStorage;
import 'photo_compress.dart';

// Community in the cloud (src/lib/community.ts): every read and write goes through the
// functions of 20261102000024_community.sql, photos to the public bucket community-photos.
// The database checks the plan, the daily limits, bans and who may change what; these calls
// only surface its messages.

class CommunityException implements Exception {
  const CommunityException(this.message, {this.offline = false});

  final String message;

  /// The server was not reached (no signal): worth trying again later
  final bool offline;

  @override
  String toString() => message;
}

/// The calls the repository needs; tests use a fake
abstract interface class CommunityBackend {
  /// Calls a database function; returns its rows (a list), its value, or null
  Future<Object?> rpc(String fn, Map<String, dynamic> params);

  /// Uploads a JPEG to the photos bucket at [path]
  Future<void> upload(String path, Uint8List bytes);

  /// Removes files from the photos bucket
  Future<void> remove(List<String> paths);
}

// The functions are missing until the migration is run
final _missing = RegExp(
  r'PGRST202|PGRST205|42P01|could not find the (function|table)|relation .* does not exist',
  caseSensitive: false,
);

const offlineMessage = 'No connection. Check your signal and try again.';

class SupabaseCommunityBackend implements CommunityBackend {
  SupabaseCommunityBackend(this.client);

  final SupabaseClient client;

  static const _rpcTimeout = Duration(seconds: 30);
  static const _uploadTimeout = Duration(seconds: 90);

  Future<T> _call<T>(Future<T> Function() run, Duration timeout) async {
    try {
      return await run().timeout(timeout);
    } on PostgrestException catch (e) {
      throw CommunityException(
        _missing.hasMatch('${e.code ?? ''} ${e.message}')
            ? 'Community is not set up yet (run the 20261102000024 migration)'
            : e.message,
      );
    } on StorageException catch (e) {
      throw CommunityException(e.message);
    } on CommunityException {
      rethrow;
    } on Object {
      // Socket, TLS, timeout: the request did not get through
      throw const CommunityException(offlineMessage, offline: true);
    }
  }

  @override
  Future<Object?> rpc(String fn, Map<String, dynamic> params) =>
      _call<Object?>(() async => await client.rpc<dynamic>(fn, params: params) as Object?, _rpcTimeout);

  @override
  Future<void> upload(String path, Uint8List bytes) => _call(() async {
    try {
      await client.storage
          .from(photoBucket)
          .uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'image/jpeg'));
    } on StorageException catch (e) {
      // Sent before (the answer was lost): the file is already there
      if (e.statusCode == '409' || RegExp('duplicate|already exists', caseSensitive: false).hasMatch(e.message)) {
        return;
      }
      rethrow;
    }
  }, _uploadTimeout);

  @override
  Future<void> remove(List<String> paths) => _call(() => client.storage.from(photoBucket).remove(paths), _rpcTimeout);
}

List<Map<String, dynamic>> _rows(Object? data) => [
  for (final r in (data is List ? data : const <Object?>[]))
    if (r is Map) Map<String, dynamic>.from(r),
];

const feedCacheKey = 'l360-community-feed';

/// The last feed page read, for reading without signal
class CachedFeed {
  const CachedFeed({required this.posts, required this.savedAt});

  final List<CommunityPost> posts;
  final DateTime savedAt;
}

class CommunityRepository {
  CommunityRepository({required this.backend, this.cache});

  final CommunityBackend backend;
  final OutboxStorage? cache;

  // --- Reading (anyone, signed in or not)

  Future<List<CommunityPost>> feed({
    Bounds? bounds,
    Set<PostKind> kinds = const {},
    Set<String> conditions = const {},
    DateTime? since,
    DateTime? before,
    int limit = feedPageSize,
    String? clubId,
  }) async {
    final data = await backend.rpc(
      'community_feed',
      feedParams(
        bounds: bounds,
        kinds: kinds,
        conditions: conditions,
        since: since,
        before: before,
        limit: limit,
        clubId: clubId,
      ),
    );
    return _rows(data).map(CommunityPost.fromRow).toList();
  }

  /// My own posts, newest first, also those hidden or removed (with their status)
  Future<List<CommunityPost>> myPosts({DateTime? before, int limit = feedPageSize}) async =>
      _rows(await backend.rpc('my_community_posts', {'p_before': before?.toUtc().toIso8601String(), 'p_limit': limit}))
          .map(CommunityPost.fromRow)
          .toList();

  /// One post in full; null when it is gone or hidden
  Future<CommunityPost?> post(String id) async {
    final rows = _rows(await backend.rpc('community_post', {'p_id': id}));
    return rows.isEmpty ? null : CommunityPost.fromRow(rows.first);
  }

  Future<List<CommunityComment>> comments(String postId) async =>
      _rows(await backend.rpc('community_comments', {'p_post_id': postId})).map(CommunityComment.fromRow).toList();

  /// Null when signed out
  Future<CommunityLimits?> limits() async {
    final rows = _rows(await backend.rpc('my_community_limits', const {}));
    return rows.isEmpty ? null : CommunityLimits.fromRow(rows.first);
  }

  // --- The feed kept on the phone

  /// Kept per account ([userId] null: signed out), since club posts are for members only
  Future<void> saveFeed(List<CommunityPost> posts, {String? userId, DateTime? now}) async {
    final store = cache;
    if (store == null) return;
    try {
      await store.write(
        feedCacheKey,
        jsonEncode({
          'savedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
          'userId': userId,
          'posts': [for (final p in posts) p.toRow()],
        }),
      );
    } on Object {
      // Not kept: the feed still shows while online
    }
  }

  /// The kept page, only for the account that read it
  Future<CachedFeed?> cachedFeed({String? userId}) async {
    try {
      final raw = await cache?.read(feedCacheKey);
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['userId'] != userId) return null;
      return CachedFeed(
        posts: [
          for (final r in (j['posts'] as List? ?? const [])) CommunityPost.fromRow(Map<String, dynamic>.from(r as Map)),
        ],
        savedAt: DateTime.tryParse('${j['savedAt']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    } on Object {
      return null;
    }
  }

  // --- Writing (signed in)

  /// Creates the post (without photos); returns its id
  Future<String> create(NewPost post) async {
    final id = await backend.rpc('create_community_post', post.toRpcParams());
    if (id is! String || !isPostId(id)) throw const CommunityException('The post could not be saved. Try again.');
    return id;
  }

  /// Uploads the n-th photo of a post to `<user id>/<post id>-<n>.jpg` and records it
  Future<void> addPhoto(String userId, String postId, int n, CompressedPhoto photo) async {
    final path = photoPath(userId, postId, n);
    await backend.upload(path, photo.bytes);
    await backend.rpc('add_community_photo', {
      'p_post_id': postId,
      'p_path': path,
      'p_width': photo.width,
      'p_height': photo.height,
      'p_size': photo.bytes.length,
    });
  }

  /// Creates the post, then uploads its photos; returns the post id
  Future<String> createWithPhotos(String userId, NewPost post, List<CompressedPhoto> photos) async {
    final id = await create(post);
    for (final (n, photo) in photos.indexed) {
      try {
        await addPhoto(userId, id, n, photo);
      } on CommunityException catch (e) {
        throw CommunityException('The post was saved, but a photo could not be uploaded: ${e.message}');
      }
    }
    return id;
  }

  /// The author's changes within 24 hours (title, text, conditions, place name)
  Future<void> update(
    String id, {
    required String title,
    required String body,
    required List<String> conditions,
    required String placeName,
  }) => backend.rpc('update_community_post', {
    'p_id': id,
    'p_title': title.trim().isEmpty ? null : title.trim(),
    'p_body': body.trim(),
    'p_conditions': conditions,
    'p_place_name': placeName.trim().isEmpty ? null : placeName.trim(),
  });

  /// Deletes my post, then its photo files
  Future<void> delete(String id) async {
    final paths = [
      for (final p in (await backend.rpc('delete_community_post', {'p_id': id}) as List? ?? const [])) '$p',
    ];
    if (paths.isEmpty) return;
    try {
      await backend.remove(paths);
    } on Object {
      // The post is gone; a leftover file is not shown anywhere
    }
  }

  /// Marks or unmarks "Helpful"; returns whether I find it helpful and the new count
  Future<({bool helpful, int count})> toggleHelpful(String postId) async {
    final rows = _rows(await backend.rpc('toggle_community_helpful', {'p_post_id': postId}));
    final r = rows.isEmpty ? const <String, dynamic>{} : rows.first;
    return (helpful: r['helpful'] == true, count: (r['helpful_count'] as num? ?? 0).toInt());
  }

  Future<String> addComment(String postId, String body) async =>
      '${await backend.rpc('add_community_comment', {'p_post_id': postId, 'p_body': body.trim()})}';

  Future<void> deleteComment(String id) => backend.rpc('delete_community_comment', {'p_id': id});

  /// [kind]: post or comment; [reason]: one of [reportReasons]
  Future<void> report(String kind, String id, String reason, String note) => backend.rpc('report_community', {
    'p_kind': kind,
    'p_id': id,
    'p_reason': reason,
    'p_note': note.trim().isEmpty ? null : note.trim(),
  });

  // --- Clubs

  Future<List<CommunityClub>> myClubs() async =>
      _rows(await backend.rpc('my_community_clubs', const {})).map(CommunityClub.fromRow).toList();

  Future<List<ClubMember>> clubMembers(String clubId) async =>
      _rows(await backend.rpc('community_club_members', {'p_club_id': clubId})).map(ClubMember.fromRow).toList();

  /// Enterprise and the admin; returns the new club's id
  Future<String> createClub(String name, String description) async =>
      '${await backend.rpc('create_community_club', {'p_name': name.trim(), 'p_description': description.trim().isEmpty ? null : description.trim()})}';

  /// The leader edits the profile: name, about, home base and contact
  Future<void> updateClub(
    String id, {
    required String name,
    String description = '',
    String region = '',
    String contact = '',
  }) {
    String? opt(String v) => v.trim().isEmpty ? null : v.trim();
    return backend.rpc('update_community_club', {
      'p_id': id,
      'p_name': name.trim(),
      'p_description': opt(description),
      'p_region': opt(region),
      'p_contact': opt(contact),
    });
  }

  /// A new club photo (or with null removes it): uploaded under a new name, recorded, then the
  /// previous file removed; a photo the server refuses is removed again (setClubPhoto on the web)
  Future<void> setClubPhoto(String userId, String clubId, CompressedPhoto? photo, {DateTime? now}) async {
    String? path;
    if (photo != null) {
      path = clubPhotoPath(userId, clubId, (now ?? DateTime.now()).millisecondsSinceEpoch);
      try {
        await backend.upload(path, photo.bytes);
      } on CommunityException catch (e) {
        throw CommunityException('The photo could not be uploaded: ${e.message}', offline: e.offline);
      }
    }
    final Object? old;
    try {
      old = await backend.rpc('set_community_club_photo', {'p_id': clubId, 'p_path': path});
    } on Object {
      if (path != null) await backend.remove([path]).catchError((Object _) {});
      rethrow;
    }
    if (old is String && old.isNotEmpty) await backend.remove([old]).catchError((Object _) {});
  }

  /// Deletes the club with its posts, then their photo files
  Future<void> deleteClub(String id) async {
    final paths = [
      for (final p in (await backend.rpc('delete_community_club', {'p_id': id}) as List? ?? const [])) '$p',
    ];
    if (paths.isEmpty) return;
    try {
      await backend.remove(paths);
    } on Object {
      // The club is gone; leftover files are not shown anywhere
    }
  }

  /// Adds the account that uses [email]; returns its display name
  Future<String> addClubMember(String clubId, String email) async =>
      '${await backend.rpc('add_community_club_member', {'p_club_id': clubId, 'p_email': email.trim()})}';

  /// The owner removes a member; my own id leaves the club
  Future<void> removeClubMember(String clubId, String userId) =>
      backend.rpc('remove_community_club_member', {'p_club_id': clubId, 'p_user_id': userId});

  /// The leader makes a member an admin, or back (`admin` / `member`)
  Future<void> setClubRole(String clubId, String userId, ClubRole role) => backend.rpc('set_community_club_role', {
    'p_club_id': clubId,
    'p_user_id': userId,
    'p_role': role == ClubRole.admin ? 'admin' : 'member',
  });

  /// Seen the club's feed: its "new posts" count starts again
  Future<void> markClubRead(String clubId) => backend.rpc('mark_community_club_read', {'p_club_id': clubId});

  /// A club leader or admin pins (up to 3) or unpins a club post
  Future<void> pinPost(String postId, bool pinned) =>
      backend.rpc('pin_community_post', {'p_post_id': postId, 'p_pinned': pinned});

  // --- Invite links

  /// A new link (7 days); returns its token
  Future<String> createInvite(String clubId) async =>
      '${await backend.rpc('create_community_club_invite', {'p_club_id': clubId})}';

  Future<List<ClubInvite>> invites(String clubId) async =>
      _rows(await backend.rpc('community_club_invites', {'p_club_id': clubId})).map(ClubInvite.fromRow).toList();

  Future<void> revokeInvite(String token) => backend.rpc('revoke_community_club_invite', {'p_token': token});

  /// The club behind a link (anyone may look); null when the link is unknown
  Future<ClubInviteInfo?> inviteInfo(String token) async {
    final rows = _rows(await backend.rpc('community_club_invite_info', {'p_token': token}));
    return rows.isEmpty ? null : ClubInviteInfo.fromRow(rows.first);
  }

  /// Joins with a link; returns the club id
  Future<String> joinClub(String token) async => '${await backend.rpc('join_community_club', {'p_token': token})}';

  // --- Workspace

  Future<List<ClubFolder>> clubFolders(String clubId) async =>
      _rows(await backend.rpc('community_club_folders', {'p_club_id': clubId})).map(ClubFolder.fromRow).toList();

  /// Creates ([id] null) or renames a folder; returns its id
  Future<String> saveClubFolder(String clubId, String? id, String name) async =>
      '${await backend.rpc('save_community_club_folder', {'p_club_id': clubId, 'p_id': id, 'p_name': name.trim()})}';

  /// Deletes a folder; its items stay, outside any folder
  Future<void> deleteClubFolder(String id) => backend.rpc('delete_community_club_folder', {'p_id': id});

  Future<List<ClubItem>> clubItems(String clubId) async =>
      _rows(await backend.rpc('community_club_items', {'p_club_id': clubId})).map(ClubItem.fromRow).toList();

  /// One item's map data in full, to show it on the map; null when gone
  Future<Attachment?> clubItemData(String id) async {
    final data = await backend.rpc('community_club_item', {'p_id': id});
    return data is Map ? Attachment.fromJson(Map<String, dynamic>.from(data)) : null;
  }

  /// Adds a copy of my map data (tracks thinned to 5000 points by the caller); returns its id
  Future<String> addClubItem(String clubId, String? folderId, Attachment data, {String note = ''}) async =>
      '${await backend.rpc('add_community_club_item', {'p_club_id': clubId, 'p_folder_id': folderId, 'p_data': data.toJson(), 'p_note': note.trim().isEmpty ? null : note.trim()})}';

  Future<void> updateClubItem(String id, {required String name, String note = '', String? folderId}) => backend.rpc(
    'update_community_club_item',
    {'p_id': id, 'p_name': name.trim(), 'p_note': note.trim().isEmpty ? null : note.trim(), 'p_folder_id': folderId},
  );

  Future<void> deleteClubItem(String id) => backend.rpc('delete_community_club_item', {'p_id': id});

  // --- Admin

  Future<List<ReportQueueItem>> reportQueue() async =>
      _rows(await backend.rpc('community_report_queue', const {})).map(ReportQueueItem.fromRow).toList();

  /// [action]: restore, hide or remove
  Future<void> moderate(String kind, String id, String action) =>
      backend.rpc('moderate_community', {'p_kind': kind, 'p_id': id, 'p_action': action});

  /// [days]: 7 etc.; null blocks until lifted; 0 lifts the block
  Future<void> setBan(String userId, int? days, {String reason = ''}) => backend.rpc('set_community_ban', {
    'p_user_id': userId,
    'p_reason': reason.trim().isEmpty ? null : reason.trim(),
    'p_days': days,
  });
}
