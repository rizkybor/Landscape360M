import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:landscape360/data/community/community_outbox.dart';
import 'package:landscape360/data/community/community_repository.dart';
import 'package:landscape360/data/community/photo_compress.dart';
import 'package:landscape360/domain/community/community.dart';
import 'package:landscape360/domain/community/community_attachments.dart';

import '../domain/community_test.dart' show feedRow;
import '../domain/sos_test.dart' show MemoryStorage;

// Community over the RPCs of 20261102000024 / 20261102000025: the names and arguments the
// database expects, photos to <user>/<post>-<n>.jpg, the feed kept for offline reading, the
// outbox of trail reports written offline, and photo compression without metadata.

const postId = '6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b';
const clubId = '11111111-2222-4333-8444-555555555555';

/// Records every call; [answers] holds each function's result, [fail] makes one throw
class FakeCommunity implements CommunityBackend {
  final calls = <(String, Map<String, dynamic>)>[];
  final uploads = <String, Uint8List>{};
  final removed = <String>[];
  final answers = <String, Object?>{};
  final fail = <String, CommunityException>{};
  bool offline = false;

  Iterable<String> get names => calls.map((c) => c.$1);

  Map<String, dynamic> params(String fn) => calls.lastWhere((c) => c.$1 == fn).$2;

  @override
  Future<Object?> rpc(String fn, Map<String, dynamic> params) async {
    if (offline) throw const CommunityException(offlineMessage, offline: true);
    calls.add((fn, params));
    final f = fail.remove(fn);
    if (f != null) throw f;
    return answers[fn];
  }

  @override
  Future<void> upload(String path, Uint8List bytes) async {
    if (offline) throw const CommunityException(offlineMessage, offline: true);
    final f = fail.remove('upload');
    if (f != null) throw f;
    uploads[path] = bytes;
  }

  @override
  Future<void> remove(List<String> paths) async => removed.addAll(paths);
}

class MemoryFiles implements OutboxFiles {
  final files = <String, Uint8List>{};

  @override
  Future<void> write(String name, Uint8List bytes) async => files[name] = bytes;

  @override
  Future<Uint8List?> read(String name) async => files[name];

  @override
  Future<void> delete(String name) async => files.remove(name);
}

CompressedPhoto photo([int n = 1]) => CompressedPhoto(bytes: Uint8List.fromList([n, n, n]), width: 1600, height: 1200);

NewPost report({String body = 'Sumber air kering'}) => NewPost(
  kind: PostKind.report,
  body: body,
  conditions: const ['water_dry'],
  happenedOn: '2026-11-01',
  lat: -6.77,
  lng: 106.97,
);

void main() {
  late FakeCommunity backend;
  late CommunityRepository repo;
  late MemoryStorage storage;

  setUp(() {
    backend = FakeCommunity()..answers['create_community_post'] = postId;
    storage = MemoryStorage();
    repo = CommunityRepository(backend: backend, cache: storage);
  });

  group('repository', () {
    test('reads the feed, one post, its comments and my limits', () async {
      backend
        ..answers['community_feed'] = [feedRow()]
        ..answers['community_post'] = [feedRow()]
        ..answers['community_comments'] = [
          {
            'id': 'c1',
            'body': 'Mantap',
            'created_at': '2026-11-01T10:00:00Z',
            'author_name': 'Rina A.',
            'is_mine': false,
          },
        ]
        ..answers['my_community_limits'] = [
          {'reports_left': 4, 'stories_left': 1, 'photos': 1, 'attachments': false, 'banned': false},
        ];
      final feed = await repo.feed(kinds: {PostKind.report}, clubId: clubId);
      expect(feed.single.id, postId);
      expect(backend.params('community_feed')['p_kinds'], ['report']);
      expect(backend.params('community_feed')['p_club'], clubId);
      expect((await repo.post(postId))!.title, 'Kandang Badak');
      expect(backend.params('community_post'), {'p_id': postId});
      expect((await repo.comments(postId)).single.authorName, 'Rina A.');
      expect(backend.params('community_comments'), {'p_post_id': postId});
      expect((await repo.limits())!.reportsLeft, 4);
      backend.answers['community_post'] = const <Object>[];
      expect(await repo.post(postId), isNull);
      backend.answers['my_community_limits'] = const <Object>[];
      expect(await repo.limits(), isNull, reason: 'signed out');
    });

    test('creates the post, then uploads each photo and records it', () async {
      final id = await repo.createWithPhotos('u1', report(), [photo(1), photo(2)]);
      expect(id, postId);
      expect(backend.names, ['create_community_post', 'add_community_photo', 'add_community_photo']);
      expect(backend.uploads.keys, ['u1/$postId-0.jpg', 'u1/$postId-1.jpg']);
      expect(backend.params('add_community_photo'), {
        'p_post_id': postId,
        'p_path': 'u1/$postId-1.jpg',
        'p_width': 1600,
        'p_height': 1200,
        'p_size': 3,
      });
      expect(backend.calls.first.$2['p_club_id'], isNull);
    });

    test('a photo that fails says the post was saved', () async {
      backend.fail['upload'] = const CommunityException('Payload too large');
      await expectLater(
        repo.createWithPhotos('u1', report(), [photo()]),
        throwsA(
          isA<CommunityException>().having(
            (e) => e.message,
            'message',
            'The post was saved, but a photo could not be uploaded: Payload too large',
          ),
        ),
      );
    });

    test('the server refusing a post surfaces its message', () async {
      backend.fail['create_community_post'] = const CommunityException(
        "You have reached today's limit of 5 trail reports for your plan. Try again tomorrow.",
      );
      await expectLater(repo.create(report()), throwsA(isA<CommunityException>()));
    });

    test('editing, deleting with its photo files, Helpful, comments, reports', () async {
      backend
        ..answers['delete_community_post'] = ['u1/$postId-0.jpg']
        ..answers['toggle_community_helpful'] = [
          {'helpful': true, 'helpful_count': 4},
        ]
        ..answers['add_community_comment'] = 'c9';
      await repo.update(postId, title: '', body: ' Baru ', conditions: const ['safe'], placeName: 'Cibodas');
      expect(backend.params('update_community_post'), {
        'p_id': postId,
        'p_title': null,
        'p_body': 'Baru',
        'p_conditions': ['safe'],
        'p_place_name': 'Cibodas',
      });
      await repo.delete(postId);
      expect(backend.removed, ['u1/$postId-0.jpg']);
      expect(await repo.toggleHelpful(postId), (helpful: true, count: 4));
      expect(await repo.addComment(postId, ' Tanya '), 'c9');
      expect(backend.params('add_community_comment'), {'p_post_id': postId, 'p_body': 'Tanya'});
      await repo.deleteComment('c9');
      expect(backend.params('delete_community_comment'), {'p_id': 'c9'});
      await repo.report('comment', 'c9', 'spam', '  ');
      expect(backend.params('report_community'), {
        'p_kind': 'comment',
        'p_id': 'c9',
        'p_reason': 'spam',
        'p_note': null,
      });
    });

    test('admin: the queue, moderating and blocking', () async {
      backend.answers['community_report_queue'] = [
        {
          'target_kind': 'post',
          'target_id': postId,
          'post_id': postId,
          'status': 'hidden',
          'excerpt': 'x',
          'author_id': 'u9',
          'author_name': 'X',
          'reports': 3,
          'reasons': ['spam'],
          'notes': <String>[],
          'last_reported_at': '2026-11-02T00:00:00Z',
          'author_banned': false,
        },
      ];
      expect((await repo.reportQueue()).single.reports, 3);
      await repo.moderate('post', postId, 'hide');
      expect(backend.params('moderate_community'), {'p_kind': 'post', 'p_id': postId, 'p_action': 'hide'});
      await repo.setBan('u9', 7, reason: 'Spam');
      expect(backend.params('set_community_ban'), {'p_user_id': 'u9', 'p_reason': 'Spam', 'p_days': 7});
      await repo.setBan('u9', null);
      expect(backend.params('set_community_ban'), {'p_user_id': 'u9', 'p_reason': null, 'p_days': null});
      await repo.setBan('u9', 0);
      expect(backend.params('set_community_ban')['p_days'], 0);
    });

    test('clubs: list, members, create, rename, add and remove members, delete with photos', () async {
      backend
        ..answers['my_community_clubs'] = [
          {
            'id': clubId,
            'name': 'Mapala UI',
            'description': 'Latihan',
            'role': 'owner',
            'member_count': 2,
            'owner_name': 'Budi S.',
            'created_at': '2026-11-01T00:00:00Z',
          },
        ]
        ..answers['community_club_members'] = [
          {
            'user_id': 'u1',
            'name': 'Budi S.',
            'email': 'budi@example.com',
            'role': 'owner',
            'added_at': '2026-11-01T00:00:00Z',
            'is_me': true,
          },
        ]
        ..answers['create_community_club'] = clubId
        ..answers['add_community_club_member'] = 'Rina A.'
        ..answers['delete_community_club'] = ['u2/p-0.jpg', 'u1/q-1.jpg'];
      expect((await repo.myClubs()).single.isOwner, isTrue);
      expect((await repo.clubMembers(clubId)).single.isMe, isTrue);
      expect(backend.params('community_club_members'), {'p_club_id': clubId});
      expect(await repo.createClub(' Mapala UI ', ''), clubId);
      expect(backend.params('create_community_club'), {'p_name': 'Mapala UI', 'p_description': null});
      await repo.updateClub(clubId, name: 'Mapala', description: 'Baru', region: ' Bogor ', contact: '');
      expect(backend.params('update_community_club'), {
        'p_id': clubId,
        'p_name': 'Mapala',
        'p_description': 'Baru',
        'p_region': 'Bogor',
        'p_contact': null,
      });
      expect(await repo.addClubMember(clubId, ' rina@example.com '), 'Rina A.');
      expect(backend.params('add_community_club_member'), {'p_club_id': clubId, 'p_email': 'rina@example.com'});
      await repo.removeClubMember(clubId, 'u2');
      expect(backend.params('remove_community_club_member'), {'p_club_id': clubId, 'p_user_id': 'u2'});
      await repo.deleteClub(clubId);
      expect(backend.params('delete_community_club'), {'p_id': clubId});
      expect(backend.removed, ['u2/p-0.jpg', 'u1/q-1.jpg']);
    });

    test('club photo: uploaded under a new name, recorded, the old file removed', () async {
      final at = DateTime.fromMillisecondsSinceEpoch(1762070400000);
      backend.answers['set_community_club_photo'] = 'u1/club-$clubId-1.jpg';
      await repo.setClubPhoto('u1', clubId, photo(), now: at);
      final path = 'u1/club-$clubId-1762070400000.jpg';
      expect(backend.uploads.keys, [path]);
      expect(backend.params('set_community_club_photo'), {'p_id': clubId, 'p_path': path});
      expect(backend.removed, ['u1/club-$clubId-1.jpg']);
    });

    test('club photo: refused by the server, the upload is removed again; removing sends null', () async {
      backend.fail['set_community_club_photo'] = const CommunityException('Only the club owner can do this');
      await expectLater(
        repo.setClubPhoto('u1', clubId, photo(), now: DateTime.fromMillisecondsSinceEpoch(5)),
        throwsA(isA<CommunityException>()),
      );
      expect(backend.removed, ['u1/club-$clubId-5.jpg']);
      backend
        ..removed.clear()
        ..answers['set_community_club_photo'] = 'u1/club-$clubId-5.jpg';
      await repo.setClubPhoto('u1', clubId, null);
      expect(backend.params('set_community_club_photo'), {'p_id': clubId, 'p_path': null});
      expect(backend.uploads.keys, ['u1/club-$clubId-5.jpg'], reason: 'nothing new uploaded');
      expect(backend.removed, ['u1/club-$clubId-5.jpg']);
      backend.answers['set_community_club_photo'] = null;
      backend.removed.clear();
      await repo.setClubPhoto('u1', clubId, null);
      expect(backend.removed, isEmpty);
    });

    test('roles, pins, read marks and invite links', () async {
      const token = '0123456789abcdef0123456789abcdef';
      backend
        ..answers['create_community_club_invite'] = token
        ..answers['community_club_invites'] = [
          {'token': token, 'expires_at': '2026-11-09T00:00:00Z', 'uses': 0, 'created_by_name': 'Budi S.'},
        ]
        ..answers['community_club_invite_info'] = [
          {'club_id': clubId, 'name': 'Mapala UI', 'member_count': 2, 'leader_name': 'Budi S.', 'valid': true},
        ]
        ..answers['join_community_club'] = clubId;
      await repo.setClubRole(clubId, 'u2', ClubRole.admin);
      expect(backend.params('set_community_club_role'), {'p_club_id': clubId, 'p_user_id': 'u2', 'p_role': 'admin'});
      await repo.setClubRole(clubId, 'u2', ClubRole.member);
      expect(backend.params('set_community_club_role')['p_role'], 'member');
      await repo.pinPost(postId, true);
      expect(backend.params('pin_community_post'), {'p_post_id': postId, 'p_pinned': true});
      await repo.markClubRead(clubId);
      expect(backend.params('mark_community_club_read'), {'p_club_id': clubId});
      expect(await repo.createInvite(clubId), token);
      expect(backend.params('create_community_club_invite'), {'p_club_id': clubId});
      expect((await repo.invites(clubId)).single.createdByName, 'Budi S.');
      await repo.revokeInvite(token);
      expect(backend.params('revoke_community_club_invite'), {'p_token': token});
      expect((await repo.inviteInfo(token))!.valid, isTrue);
      expect(backend.params('community_club_invite_info'), {'p_token': token});
      backend.answers['community_club_invite_info'] = <Object>[];
      expect(await repo.inviteInfo(token), isNull);
      expect(await repo.joinClub(token), clubId);
      expect(backend.params('join_community_club'), {'p_token': token});
    });

    test('workspace: folders and items', () async {
      final track = trackAttachment(name: 'T', distanceM: 10, points: const [(106.9, -6.7), (107.0, -6.8)]);
      backend
        ..answers['community_club_folders'] = [
          {'id': 'f1', 'name': 'Latihan', 'item_count': 1},
        ]
        ..answers['save_community_club_folder'] = 'f2'
        ..answers['community_club_items'] = [
          {
            'id': 'i1',
            'folder_id': 'f1',
            'kind': 'track',
            'name': 'T',
            'summary': {'distance_m': 10},
          },
        ]
        ..answers['community_club_item'] = track.toJson()
        ..answers['add_community_club_item'] = 'i9';
      expect((await repo.clubFolders(clubId)).single.name, 'Latihan');
      expect(await repo.saveClubFolder(clubId, null, ' Survei '), 'f2');
      expect(backend.params('save_community_club_folder'), {'p_club_id': clubId, 'p_id': null, 'p_name': 'Survei'});
      await repo.deleteClubFolder('f2');
      expect(backend.params('delete_community_club_folder'), {'p_id': 'f2'});
      expect((await repo.clubItems(clubId)).single.distanceM, 10);
      expect(backend.params('community_club_items'), {'p_club_id': clubId});
      expect((await repo.clubItemData('i1'))!.toJson(), track.toJson());
      expect(backend.params('community_club_item'), {'p_id': 'i1'});
      backend.answers['community_club_item'] = null;
      expect(await repo.clubItemData('i1'), isNull);
      expect(await repo.addClubItem(clubId, 'f1', track, note: ' '), 'i9');
      expect(backend.params('add_community_club_item'), {
        'p_club_id': clubId,
        'p_folder_id': 'f1',
        'p_data': track.toJson(),
        'p_note': null,
      });
      await repo.updateClubItem('i9', name: 'Jalur', note: 'Utama', folderId: null);
      expect(backend.params('update_community_club_item'), {
        'p_id': 'i9',
        'p_name': 'Jalur',
        'p_note': 'Utama',
        'p_folder_id': null,
      });
      await repo.deleteClubItem('i9');
      expect(backend.params('delete_community_club_item'), {'p_id': 'i9'});
    });

    test('the last feed page is kept per account for reading offline', () async {
      final posts = [CommunityPost.fromRow(feedRow(clubId: clubId, clubName: 'Mapala UI'))];
      await repo.saveFeed(posts, userId: 'u1', now: DateTime.utc(2026, 11, 2));
      final back = await repo.cachedFeed(userId: 'u1');
      expect(back!.posts.single.clubName, 'Mapala UI');
      expect(back.savedAt, DateTime.utc(2026, 11, 2));
      expect(await repo.cachedFeed(userId: 'u2'), isNull, reason: 'club posts are not for another account');
      expect(await repo.cachedFeed(), isNull);
      storage.values[feedCacheKey] = 'not json';
      expect(await repo.cachedFeed(userId: 'u1'), isNull);
    });
  });

  group('outbox', () {
    late MemoryFiles files;
    late CommunityOutbox box;

    setUp(() {
      files = MemoryFiles();
      box = CommunityOutbox(storage: storage, files: files, repository: () => repo);
    });

    test('a report written offline waits with its photos, then goes once online', () async {
      backend.offline = true;
      await box.queue('u1', report(), [photo(1), photo(2)]);
      expect(files.files, hasLength(2));
      final r1 = await box.flush('u1');
      expect((r1.sentPostIds.isEmpty, r1.offline), (true, true));
      expect(await box.pending('u1'), hasLength(1));
      expect(await box.pending('u2'), isEmpty, reason: 'only the account that wrote it');

      backend.offline = false;
      final r2 = await box.flush('u1');
      expect(r2.sentPostIds, [postId]);
      expect(backend.names, ['create_community_post', 'add_community_photo', 'add_community_photo']);
      expect(backend.uploads.keys, ['u1/$postId-0.jpg', 'u1/$postId-1.jpg']);
      expect(await box.pending('u1'), isEmpty);
      expect(files.files, isEmpty, reason: 'photos removed from the phone once sent');
    });

    test('a send that stops after the post goes on with the photos, without posting twice', () async {
      await box.queue('u1', report(), [photo(1), photo(2)]);
      backend.fail['add_community_photo'] = const CommunityException('x', offline: true);
      final r1 = await box.flush('u1');
      expect(r1.offline, isTrue);
      final waiting = (await box.pending('u1')).single;
      expect((waiting.postId, waiting.photosSent), (postId, 0));
      await box.flush('u1');
      expect(backend.names.where((n) => n == 'create_community_post'), hasLength(1));
      expect(backend.names.where((n) => n == 'add_community_photo'), hasLength(3), reason: 'the failed one again');
      expect(await box.pending('u1'), isEmpty);
    });

    test('a report the server refuses keeps its message until sent again or dropped', () async {
      await box.queue('u1', report(), const []);
      backend.fail['create_community_post'] = const CommunityException("You have reached today's limit");
      final r = await box.flush('u1');
      expect((r.sentPostIds.isEmpty, r.offline), (true, false));
      final item = (await box.pending('u1')).single;
      expect(item.error, "You have reached today's limit");
      await box.flush('u1');
      expect(backend.names.where((n) => n == 'create_community_post'), hasLength(1), reason: 'not retried by itself');
      await box.retry(item.clientId);
      expect((await box.flush('u1')).sentPostIds, [postId]);

      await box.queue('u1', report(), [photo()]);
      await box.discard((await box.pending('u1')).single.clientId);
      expect(await box.pending('u1'), isEmpty);
      expect(files.files, isEmpty);
    });

    test('the queued post keeps its club and attachment', () async {
      final post = NewPost(
        kind: PostKind.report,
        body: 'b',
        conditions: const ['safe'],
        happenedOn: '2026-11-01',
        lat: 1,
        lng: 2,
        clubId: clubId,
      );
      backend.offline = true;
      await box.queue('u1', post, const []);
      backend.offline = false;
      await box.flush('u1');
      expect(backend.params('create_community_post')['p_club_id'], clubId);
    });
  });

  group('photos', () {
    test('at most 1600 px, JPEG, without the camera metadata', () {
      final big = img.Image(width: 3200, height: 2400);
      img.fill(big, color: img.ColorRgb8(60, 120, 40));
      big.exif.imageIfd['Make'] = img.IfdValueAscii('PhoneCam');
      big.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(6, 1);
      final original = img.encodeJpg(big, quality: 95);
      expect(img.decodeJpg(original)!.exif.isEmpty, isFalse, reason: 'the test photo has EXIF');

      final out = compressPhoto(original);
      expect((out.width, out.height), (1600, 1200));
      expect(out.bytes.length, lessThanOrEqualTo(maxPhotoBytes));
      final decoded = img.decodeJpg(out.bytes)!;
      expect((decoded.width, decoded.height), (1600, 1200));
      expect(decoded.exif.isEmpty, isTrue);
    });

    test('portrait photos keep their shape; small ones are not enlarged; the rotation is applied', () {
      final tall = img.Image(width: 1000, height: 2000);
      expect((compressPhoto(img.encodeJpg(tall)).width, compressPhoto(img.encodeJpg(tall)).height), (800, 1600));
      final small = img.Image(width: 400, height: 300);
      expect(compressPhoto(img.encodePng(small)).width, 400);
      // Rotated 90° by the camera (EXIF orientation 6): the pixels are turned
      final rotated = img.Image(width: 400, height: 300)..exif.imageIfd.orientation = 6;
      final r = compressPhoto(img.encodeJpg(rotated));
      expect((r.width, r.height), (300, 400));
    });

    test('a club photo is at most 640 px', () {
      final out = compressPhoto(img.encodeJpg(img.Image(width: 2000, height: 1000)), maxSide: clubPhotoSide);
      expect((out.width, out.height), (640, 320));
    });

    test('a file that is not a photo is refused', () {
      expect(() => compressPhoto(Uint8List.fromList([1, 2, 3])), throwsA(isA<PhotoException>()));
    });
  });
}
