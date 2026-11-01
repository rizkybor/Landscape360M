import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/community/community.dart';
import 'package:landscape360/domain/community/community_attachments.dart';
import 'package:landscape360/domain/share/share_location.dart';

// Community rules shared with the web (src/lib/community.ts) and the database
// (20261102000024_community.sql, 20261102000025_community_clubs.sql)

const _id = '6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b';
const _club = '11111111-2222-4333-8444-555555555555';

Map<String, dynamic> feedRow({
  String id = _id,
  String kind = 'report',
  String happenedOn = '2026-11-01',
  String createdAt = '2026-11-01T08:00:00.123456+00:00',
  List<String> conditions = const ['water_dry'],
  String? clubId,
  String? clubName,
}) => {
  'id': id,
  'kind': kind,
  'title': 'Kandang Badak',
  'body': 'Sumber air kering',
  'truncated': false,
  'conditions': conditions,
  'happened_on': happenedOn,
  'lat': -6.77,
  'lng': 106.97,
  'place_name': 'Cimacan, Cipanas',
  'attachment_kind': null,
  'photos': [
    {'path': 'u/p-0.jpg', 'width': 1600, 'height': 1200},
  ],
  'helpful_count': 3,
  'comment_count': 1,
  'created_at': createdAt,
  'edited_at': null,
  'author_name': 'Budi S.',
  'author_organization': 'Mapala UI',
  'is_mine': true,
  'i_found_helpful': false,
  'club_id': clubId,
  'club_name': clubName,
};

CommunityPost post({
  PostKind kind = PostKind.report,
  String happenedOn = '2026-11-01',
  DateTime? createdAt,
  bool isMine = true,
}) => CommunityPost(
  id: _id,
  kind: kind,
  body: 'x',
  happenedOn: happenedOn,
  lat: 0,
  lng: 0,
  createdAt: createdAt ?? DateTime(2026, 11, 1, 8),
  isMine: isMine,
);

void main() {
  final now = DateTime(2026, 11, 2, 10);

  group('catalogues', () {
    test('conditions and reasons match the web and the database', () {
      expect(trailConditions.map((c) => c.id), [
        'safe',
        'muddy',
        'landslide',
        'fallen_tree',
        'water_ok',
        'water_dry',
        'closed',
        'bad_weather',
        'wildlife',
        'other',
      ]);
      expect(conditionOf('water_dry').label, 'Water source dry');
      expect(conditionOf('safe').label, 'Trail OK');
      expect(conditionOf('nope').id, 'other');
      expect(reportReasons.map((r) => r.$1), ['misleading', 'spam', 'inappropriate', 'privacy', 'other']);
      expect(reportReasonLabel('misleading'), 'Misleading or dangerous');
      expect(bodyLimit, {PostKind.report: 500, PostKind.story: 5000});
      expect((maxConditions, titleLimit, reportFreshDays, nearMeMeters), (4, 80, 30, 300.0));
    });

    test('links and photo paths', () {
      expect(postUrl(_id), 'https://landscape360.jcdigital.co.id/community/$_id');
      expect(photoPath('u1', _id, 2), 'u1/$_id-2.jpg');
      expect(
        photoUrl('https://x.supabase.co/', 'u1/p-0.jpg'),
        'https://x.supabase.co/storage/v1/object/public/community-photos/u1/p-0.jpg',
      );
      expect(isPostId(_id), isTrue);
      expect(isPostId('not-a-uuid'), isFalse);
    });
  });

  group('rules', () {
    String? err({
      PostKind kind = PostKind.report,
      String body = 'Licin setelah hujan',
      String title = '',
      List<String> conditions = const ['muddy'],
      String happenedOn = '2026-11-02',
      double? lat = -6.7,
      double? lng = 106.9,
    }) => postInputError(
      kind: kind,
      body: body,
      title: title,
      conditions: conditions,
      happenedOn: happenedOn,
      lat: lat,
      lng: lng,
      now: now,
    );

    test('a post needs text, conditions for a report, a place and a date', () {
      expect(err(), isNull);
      expect(err(body: '   '), 'Write something first.');
      expect(err(body: 'a' * 501), 'A trail report is at most 500 characters.');
      expect(err(kind: PostKind.story, body: 'a' * 501, conditions: const []), isNull);
      expect(err(kind: PostKind.story, body: 'a' * 5001), 'A story is at most 5000 characters.');
      expect(err(title: 'a' * 81), 'The title is at most 80 characters.');
      expect(err(conditions: const []), 'Choose at least one trail condition.');
      expect(err(conditions: const ['safe', 'muddy', 'closed', 'other', 'wildlife']), 'Choose at most 4 conditions.');
      expect(err(conditions: const ['lava']), 'Unknown trail condition.');
      expect(err(lat: null), 'Set where it is on the map.');
      expect(err(happenedOn: ''), 'Choose the date.');
      expect(err(happenedOn: '2026-11-03'), 'The date cannot be in the future.');
      expect(err(happenedOn: '2025-10-31'), 'The date must be within the last year.');
      expect(err(happenedOn: '2025-11-01'), isNull, reason: '366 days, like the server');
    });

    test('characters are counted like the database (emoji count once)', () {
      expect(err(body: '🥾' * 500), isNull);
      expect(err(body: '🥾' * 501), isNotNull);
    });

    test('trail reports older than 30 days are old; stories never', () {
      expect(isOldReport(post(happenedOn: '2026-10-04'), now), isFalse);
      expect(isOldReport(post(happenedOn: '2026-10-02'), now), isTrue);
      expect(isOldReport(post(kind: PostKind.story, happenedOn: '2025-12-01'), now), isFalse);
    });

    test('the author edits for 24 hours', () {
      expect(canEdit(post(createdAt: now.subtract(const Duration(hours: 23))), now), isTrue);
      expect(canEdit(post(createdAt: now.subtract(const Duration(hours: 24))), now), isFalse);
      expect(canEdit(post(isMine: false), now), isFalse);
    });

    test('the map keeps the last 30 days and leaves old reports out', () {
      final fresh = post();
      final oldReport = post(happenedOn: '2026-09-01');
      final oldPost = post(kind: PostKind.story, createdAt: DateTime(2026, 9, 1));
      expect(postsForMap([fresh, oldReport, oldPost], now), [fresh]);
    });

    test('place name from the nearest village', () {
      expect(villagePlaceName('Cimacan', 'Cipanas'), 'Cimacan, Cipanas');
      expect(villagePlaceName('Cipanas', 'Cipanas'), 'Cipanas');
      expect(villagePlaceName('Sukamaju ', ''), 'Sukamaju');
    });

    test('time ago and dates', () {
      expect(timeAgo(now.subtract(const Duration(seconds: 20)), now), 'just now');
      expect(timeAgo(now.subtract(const Duration(minutes: 5)), now), '5 min ago');
      expect(timeAgo(now.subtract(const Duration(hours: 3)), now), '3 h ago');
      expect(timeAgo(now.subtract(const Duration(days: 1)), now), '1 day ago');
      expect(timeAgo(DateTime(2026, 10, 1), now), '1 Oct 2026');
      expect(dateOnly(DateTime(2026, 3, 7)), '2026-03-07');
      expect(parseDateOnly('2026-03-07'), DateTime(2026, 3, 7));
      expect(parseDateOnly('x'), isNull);
    });
  });

  group('mapping', () {
    test('a feed row', () {
      final p = CommunityPost.fromRow(feedRow());
      expect((p.id, p.kind, p.title, p.placeName), (_id, PostKind.report, 'Kandang Badak', 'Cimacan, Cipanas'));
      expect((p.helpfulCount, p.commentCount, p.isMine, p.iFoundHelpful), (3, 1, true, false));
      expect(p.photos.single.path, 'u/p-0.jpg');
      expect(p.byline, 'Budi S. · Mapala UI');
      expect(p.createdAt.microsecondsSinceEpoch % 1000000, 123456, reason: 'paging needs microseconds');
      expect((p.clubId, p.membersOnly), (null, false));
      expect(mainCondition(p)?.id, 'water_dry');
    });

    test('a club post is members only', () {
      final p = CommunityPost.fromRow(feedRow(clubId: _club, clubName: 'Mapala UI'));
      expect((p.clubId, p.clubName, p.membersOnly), (_club, 'Mapala UI', true));
    });

    test('a full post with its attachment and status; the cached copy reads back the same', () {
      final row = {
        ...feedRow(),
        'attachment': {
          'kind': 'track',
          'name': 'Gede via Cibodas',
          'distance_m': 8123,
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [106.98, -6.74],
              [106.99, -6.75],
            ],
          },
        },
        'status': 'hidden',
        'edited_at': '2026-11-01T09:00:00Z',
      }..remove('attachment_kind');
      final p = CommunityPost.fromRow(row);
      expect(p.attachment, isA<TrackAttachment>());
      expect(p.attachmentKind, 'track');
      expect(p.status, PostStatus.hidden);
      expect(p.editedAt, DateTime.utc(2026, 11, 1, 9));
      final back = CommunityPost.fromRow(p.toRow());
      expect(back.toRow(), p.toRow());
    });

    test('a new post goes as create_community_post arguments', () {
      final params = NewPost(
        kind: PostKind.report,
        title: '  ',
        body: ' Kering ',
        conditions: const ['water_dry'],
        happenedOn: '2026-11-01',
        lat: -6.77,
        lng: 106.97,
        placeName: 'Cimacan',
        attachment: classicAttachment(name: 'Latihan', token: '0123456789abcdef0123456789abcdef'),
        clubId: _club,
      ).toRpcParams();
      expect(params, {
        'p_kind': 'report',
        'p_title': null,
        'p_body': 'Kering',
        'p_conditions': ['water_dry'],
        'p_happened_on': '2026-11-01',
        'p_lat': -6.77,
        'p_lng': 106.97,
        'p_place_name': 'Cimacan',
        'p_attachment': {'kind': 'classic', 'name': 'Latihan', 'token': '0123456789abcdef0123456789abcdef'},
        'p_club_id': _club,
      });
      final json = NewPost.fromJson(
        NewPost(kind: PostKind.story, body: 'b', happenedOn: '2026-11-01', lat: 1, lng: 2, clubId: _club).toJson(),
      );
      expect((json.kind, json.clubId, json.lat), (PostKind.story, _club, 1.0));
    });

    test('feed arguments: box, kinds and conditions in catalogue order, paging and club', () {
      final p = feedParams(
        bounds: (106.0, -7.0, 107.0, -6.0),
        kinds: {PostKind.story, PostKind.report},
        conditions: {'water_dry', 'safe'},
        before: DateTime.utc(2026, 11, 1, 8, 0, 0, 123, 456),
        clubId: _club,
      );
      expect(p, {
        'p_west': 106.0,
        'p_south': -7.0,
        'p_east': 107.0,
        'p_north': -6.0,
        'p_kinds': ['report', 'story'],
        'p_conditions': ['safe', 'water_dry'],
        'p_since': null,
        'p_before': '2026-11-01T08:00:00.123456Z',
        'p_limit': 20,
        'p_club': _club,
      });
      expect(feedParams()['p_kinds'], isNull);
      expect(feedParams()['p_club'], isNull);
    });

    test('limits per plan as my_community_limits returns them, with clubs', () {
      final free = CommunityLimits.fromRow({
        'reports_left': 5,
        'stories_left': 1,
        'photos': 1,
        'attachments': false,
        'banned': false,
        'clubs_left': 0,
        'can_create_clubs': false,
      });
      expect(free.summary, '5 trail reports and 1 story left today');
      expect((free.photos, free.attachments, free.canCreateClubNow), (1, false, false));
      expect(free.leftFor(PostKind.story), 1);
      final enterprise = CommunityLimits.fromRow({
        'reports_left': 49,
        'stories_left': 20,
        'photos': 4,
        'attachments': true,
        'banned': false,
        'clubs_left': 5,
        'can_create_clubs': true,
      });
      expect((enterprise.clubsLeft, enterprise.canCreateClubNow), (5, true));
      final full = CommunityLimits.fromRow({
        'reports_left': 0,
        'stories_left': 0,
        'photos': 4,
        'attachments': true,
        'banned': true,
        'clubs_left': 0,
        'can_create_clubs': true,
      });
      expect((full.banned, full.canCreateClubNow), (true, false));
      final admin = CommunityLimits.fromRow({
        'reports_left': null,
        'stories_left': null,
        'photos': 4,
        'attachments': true,
        'banned': false,
        'clubs_left': null,
        'can_create_clubs': true,
      });
      expect((admin.reportsLeft, admin.clubsLeft, admin.canCreateClubNow), (null, null, true));
      expect(admin.summary, 'No daily limit');
      // Before the clubs migration the columns are missing: no clubs offered
      final old = CommunityLimits.fromRow({'reports_left': 5, 'stories_left': 1, 'photos': 1});
      expect(old.canCreateClubNow, isFalse);
    });

    test('clubs and members', () {
      final c = CommunityClub.fromRow({
        'id': _club,
        'name': 'Mapala UI',
        'description': null,
        'role': 'owner',
        'member_count': 12,
        'owner_name': 'Budi S.',
        'created_at': '2026-11-01T00:00:00Z',
      });
      expect((c.isOwner, c.memberCount, c.name), (true, 12, 'Mapala UI'));
      expect((c.region, c.contact, c.photoPath, c.updatedAt), (null, null, null, null), reason: 'before 26');
      final profile = CommunityClub.fromRow({
        'id': _club,
        'name': 'mapala UI',
        'role': 'member',
        'member_count': 3,
        'owner_name': 'Budi S.',
        'created_at': '2026-11-01T00:00:00Z',
        'region': 'Depok, Jawa Barat',
        'contact': '@mapalaui',
        'photo_path': 'u1/club-$_club-1762070400000.jpg',
        'updated_at': '2026-11-02T00:00:00Z',
      });
      expect((profile.region, profile.contact, profile.isOwner), ('Depok, Jawa Barat', '@mapalaui', false));
      expect(profile.photoPath, 'u1/club-$_club-1762070400000.jpg');
      expect(profile.updatedAt, DateTime.utc(2026, 11, 2));
      expect(profile.initial, 'M');
      expect(clubPhotoPath('u1', _club, 42), 'u1/club-$_club-42.jpg');
      expect(clubInputError(name: 'Mapala', region: 'a' * 81), 'The home base is at most 80 characters.');
      expect(clubInputError(name: 'Mapala', contact: 'a' * 201), 'The contact is at most 200 characters.');
      final m = ClubMember.fromRow({
        'user_id': 'u2',
        'name': 'Rina A.',
        'organization': null,
        'email': 'rina@example.com',
        'role': 'member',
        'added_at': '2026-11-01T00:00:00Z',
        'is_me': false,
      });
      expect((m.role, m.email, m.isMe), (ClubRole.member, 'rina@example.com', false));
      expect(clubInputError(name: 'A'), 'Give the club a name.');
      expect(clubInputError(name: 'a' * 61), 'A club name is at most 60 characters.');
      expect(clubInputError(name: 'Mapala', description: 'a' * 501), isNotNull);
      expect(clubInputError(name: 'Mapala'), isNull);
      expect(memberEmailError('rina@example.com'), isNull);
      expect(memberEmailError('rina'), isNotNull);
      expect((everyoneLabel, membersOnlyLabel), ('Everyone', 'Members only'));
    });

    test('report queue rows', () {
      final q = ReportQueueItem.fromRow({
        'target_kind': 'comment',
        'target_id': 'c1',
        'post_id': _id,
        'status': 'hidden',
        'excerpt': 'spam spam',
        'author_id': 'u9',
        'author_name': 'X',
        'reports': 3,
        'reasons': ['spam'],
        'notes': ['iklan'],
        'last_reported_at': '2026-11-02T00:00:00Z',
        'author_banned': true,
      });
      expect((q.targetKind, q.status, q.reports, q.authorBanned), ('comment', PostStatus.hidden, 3, true));
    });
  });

  test('contactHref makes links like the web', () {
    expect(contactHref('@mapala.ui'), 'https://instagram.com/mapala.ui');
    expect(contactHref(' https://mapala.ui.ac.id/kontak '), 'https://mapala.ui.ac.id/kontak');
    expect(contactHref('HTTP://x.id'), 'HTTP://x.id');
    expect(contactHref('mapala.ui.ac.id'), 'https://mapala.ui.ac.id');
    expect(contactHref('linktr.ee/mapala'), 'https://linktr.ee/mapala');
    expect(contactHref('0812-3456-7890'), 'https://wa.me/6281234567890');
    expect(contactHref('+62 812 3456 7890'), 'https://wa.me/6281234567890');
    expect(contactHref('62812345678'), 'https://wa.me/62812345678');
    expect(contactHref('021 1234567'), isNull, reason: 'a landline is not on WhatsApp');
    expect(contactHref('Pak Budi, pos jaga'), isNull);
    expect(contactHref('@'), isNull);
    expect(contactHref(''), isNull);
  });

  group('club workspace, roles, invites and pins', () {
    test('roles: Leader, Admin, Member; managers', () {
      expect([for (final r in ClubRole.values) r.label], ['Leader', 'Admin', 'Member']);
      expect(ClubRole.parse('admin'), ClubRole.admin);
      expect(ClubRole.parse('x'), ClubRole.member);
      expect([for (final r in ClubRole.values) r.manages], [true, true, false]);
    });

    test('my clubs with new posts and who manages', () {
      final c = CommunityClub.fromRow({
        'id': _club,
        'name': 'Mapala UI',
        'role': 'admin',
        'member_count': 9,
        'owner_name': 'Budi S.',
        'created_at': '2026-11-01T00:00:00Z',
        'new_posts': 4,
        'can_manage': true,
      });
      expect((c.role, c.newPosts, c.canManage, c.isOwner), (ClubRole.admin, 4, true, false));
      final before = CommunityClub.fromRow({'id': _club, 'name': 'X', 'role': 'member', 'created_at': null});
      expect((before.newPosts, before.canManage), (0, false));
    });

    test('pinned posts and my role in their club', () {
      final p = CommunityPost.fromRow({
        ...feedRow(clubId: _club, clubName: 'M'),
        'pinned': true,
        'my_club_role': 'admin',
      });
      expect((p.pinned, p.myClubRole, p.canPin), (true, ClubRole.admin, true));
      final member = CommunityPost.fromRow({...feedRow(clubId: _club), 'my_club_role': 'member'});
      expect(member.canPin, false);
      final public = CommunityPost.fromRow({...feedRow(), 'my_club_role': 'owner'});
      expect((public.pinned, public.canPin), (false, false), reason: 'only club posts are pinned');
      expect(CommunityPost.fromRow(p.toRow()).toRow(), p.toRow());
      expect(p.copyWith(pinned: false).pinned, false);
    });

    test('invite links', () {
      const token = '0123456789abcdef0123456789abcdef';
      expect(joinUrl(token), 'https://landscape360.jcdigital.co.id/?join=$token');
      expect(isInviteToken(token), true);
      expect(isInviteToken('abc'), false);
      final i = ClubInvite.fromRow({
        'token': token,
        'expires_at': '2026-11-09T00:00:00Z',
        'uses': 3,
        'created_by_name': 'Budi S.',
        'created_at': '2026-11-02T00:00:00Z',
      });
      expect((i.uses, i.createdByName, i.url), (3, 'Budi S.', joinUrl(token)));
      expect(i.expiresAt, DateTime.utc(2026, 11, 9));
      final info = ClubInviteInfo.fromRow({
        'club_id': _club,
        'name': 'Mapala UI',
        'description': null,
        'region': 'Depok',
        'photo_path': null,
        'member_count': 12,
        'leader_name': 'Budi S.',
        'valid': true,
        'is_member': false,
      });
      expect((info.valid, info.isMember, info.memberCount, info.club.ownerName), (true, false, 12, 'Budi S.'));
      final link = IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/?join=$token'));
      expect((link! as JoinLink).token, token);
      expect(IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/?join=nope')), isNull);
    });

    test('workspace folders and items', () {
      final f = ClubFolder.fromRow({'id': 'f1', 'name': 'Latihan', 'item_count': 3});
      expect((f.id, f.name, f.itemCount), ('f1', 'Latihan', 3));
      final track = ClubItem.fromRow({
        'id': 'i1',
        'folder_id': 'f1',
        'kind': 'track',
        'name': 'Gede via Cibodas',
        'note': 'Jalur utama',
        'summary': {'distance_m': 8123},
        'added_by_name': 'Rina A.',
        'is_mine': false,
        'created_at': '2026-11-02T00:00:00Z',
      });
      expect((track.kind, track.distanceM, track.folderId, track.isMine), ('track', 8123.0, 'f1', false));
      final area = ClubItem.fromRow({
        'id': 'i2',
        'folder_id': null,
        'kind': 'area',
        'name': 'Blok A',
        'summary': {'color': '#2563eb'},
        'created_at': '2026-11-02T00:00:00Z',
      });
      expect((area.color, area.folderId, area.distanceM), ('#2563eb', null, null));
      final classic = ClubItem.fromRow({
        'id': 'i3',
        'kind': 'classic',
        'name': 'F',
        'summary': {'token': '0123456789abcdef0123456789abcdef'},
        'created_at': null,
      });
      expect(classic.token, '0123456789abcdef0123456789abcdef');
    });

    test('workspace tracks keep up to 5000 points', () {
      final points = [for (var i = 0; i < 9000; i++) (i.toDouble(), 0.0)];
      final t = trackAttachment(name: 'T', distanceM: 1, points: points, maxPoints: workspaceTrackPoints);
      expect(t.line.length, 5000);
      expect((t.line.first, t.line.last), (points.first, points.last));
    });
  });

  group('attachments', () {
    test('snapshots in the shared JSON shape', () {
      expect(placeAttachment(name: 'Pos 3', category: 'camp', lat: -6.1234567, lng: 106.7654321).toJson(), {
        'kind': 'place',
        'name': 'Pos 3',
        'category': 'camp',
        'geometry': {
          'type': 'Point',
          'coordinates': [106.765432, -6.123457],
        },
      });
      final area = areaAttachment(name: 'Blok A', color: '#2563eb', ring: const [(1, 1), (2, 1), (2, 2)]);
      expect(area.toJson(), {
        'kind': 'area',
        'name': 'Blok A',
        'color': '#2563eb',
        'geometry': {
          'type': 'Polygon',
          'coordinates': [
            [
              [1.0, 1.0],
              [2.0, 1.0],
              [2.0, 2.0],
              [1.0, 1.0],
            ],
          ],
        },
      });
      final track = trackAttachment(name: 'T', distanceM: 1234.6, points: const [(1, 1), (2, 2)]).toJson();
      expect(track['distance_m'], 1235);
      expect((track['geometry'] as Map)['type'], 'LineString');
      expect(classicAttachment(name: 'F', token: 'short'), isNull);
      expect(classicAttachment(name: 'F', token: '0123456789abcdef0123456789abcdef')!.coords, isEmpty);
    });

    test('a long track is thinned evenly to 1500 points, first and last kept', () {
      final points = [for (var i = 0; i < 10000; i++) (i.toDouble(), 0.0)];
      final thin = trackAttachment(name: 'T', distanceM: 1, points: points).line;
      expect(thin.length, maxTrackPoints);
      expect(thin.first, points.first);
      expect(thin.last, points.last);
      // Same picks as Math.round(i * step) on the web
      expect(thin[1].$1, (9999 / 1499).roundToDouble());
      expect(thinLine(points.sublist(0, 10)), points.sublist(0, 10));
    });

    test('read back from a post, with the centre for its location', () {
      for (final a in [
        placeAttachment(name: 'P', category: 'water', lat: -6, lng: 106),
        areaAttachment(name: 'A', color: '#d49b22', ring: const [(106, -6), (107, -6), (107, -7)]),
        trackAttachment(name: 'T', distanceM: 10, points: const [(106, -6), (107, -7)]),
        classicAttachment(name: 'C', token: '0123456789abcdef0123456789abcdef')!,
      ]) {
        expect(Attachment.fromJson(a.toJson())!.toJson(), a.toJson());
      }
      expect(trackAttachment(name: 'T', distanceM: 1, points: const [(106, -6), (107, -7)]).center, (106.5, -6.5));
      expect(Attachment.fromJson({'kind': 'video'}), isNull);
      expect(Attachment.fromJson({'kind': 'place', 'geometry': 'bad'}), isNull);
    });
  });

  group('links', () {
    test('/community/<id> and ?post= open the post', () {
      final a = IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/community/$_id'));
      expect((a! as CommunityLink).postId, _id);
      final b = IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/community/${_id.toUpperCase()}/'));
      expect((b! as CommunityLink).postId, _id);
      final c = IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/?post=$_id'));
      expect((c! as CommunityLink).postId, _id);
      expect(IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/community/nope')), isNull);
      expect(IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/community/$_id/x')), isNull);
      expect(IncomingLink.parse(Uri.parse('https://evil.example/community/$_id')), isNull);
    });
  });
}
