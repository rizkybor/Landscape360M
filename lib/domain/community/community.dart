import 'community_attachments.dart';

// Port of src/lib/community.ts (COMMUNITY_PRD.md): trail reports and trip stories pinned to
// the map. The catalogues, limits and rules are the same as the web's; every one of them is
// enforced again by the database (20261102000024_community.sql), so these only decide what
// the app shows and what it lets the user send.

enum PostKind {
  report('Trail report'),
  story('Story');

  const PostKind(this.label);

  final String label;

  static PostKind parse(Object? v) => v == 'story' ? story : report;
}

class TrailCondition {
  const TrailCondition(this.id, this.label, this.color);

  final String id;
  final String label;
  final String color; // #rrggbb, same as the web
}

const trailConditions = [
  TrailCondition('safe', 'Trail OK', '#365b25'),
  TrailCondition('muddy', 'Slippery / muddy', '#8a5a2b'),
  TrailCondition('landslide', 'Landslide', '#b4302a'),
  TrailCondition('fallen_tree', 'Fallen tree', '#7a4e0e'),
  TrailCondition('water_ok', 'Water available', '#2563eb'),
  TrailCondition('water_dry', 'Water source dry', '#e46c24'),
  TrailCondition('closed', 'Trail closed', '#7a201c'),
  TrailCondition('bad_weather', 'Bad weather', '#4b5563'),
  TrailCondition('wildlife', 'Wildlife', '#7c3aed'),
  TrailCondition('other', 'Other', '#7a7561'),
];

/// The condition with this id; unknown ids read as "Other"
TrailCondition conditionOf(String id) =>
    trailConditions.firstWhere((c) => c.id == id, orElse: () => trailConditions.last);

const maxConditions = 4;

/// Why something is reported (report_community)
const reportReasons = [
  ('misleading', 'Misleading or dangerous'),
  ('spam', 'Spam'),
  ('inappropriate', 'Inappropriate'),
  ('privacy', 'Privacy'),
  ('other', 'Other'),
];

String reportReasonLabel(String id) => reportReasons.firstWhere((r) => r.$1 == id, orElse: () => (id, id)).$2;

const bodyLimit = {PostKind.report: 500, PostKind.story: 5000};
const titleLimit = 80;
const commentLimit = 1000;
const reportNoteLimit = 500;
const placeNameLimit = 120;

/// Trail reports older than this are "old" and left off the map by default
const reportFreshDays = 30;

/// A post placed this close to where you are now shares your position: warn first
const nearMeMeters = 300.0;

/// Posts per feed page
const feedPageSize = 20;

/// The most posts the map layer asks for at once
const layerLimit = 300;

const photoBucket = 'community-photos';

/// Site link of a post, opened by the app when installed (and by the web otherwise)
String postUrl(String id, [String base = 'https://landscape360.jcdigital.co.id']) => '$base/community/$id';

/// Public address of a photo in the bucket
String photoUrl(String supabaseUrl, String path) =>
    '${supabaseUrl.replaceFirst(RegExp(r'/+$'), '')}/storage/v1/object/public/$photoBucket/$path';

/// Storage path of the n-th photo of a post: `<user id>/<post id>-<n>.jpg`
String photoPath(String userId, String postId, int n) => '$userId/$postId-$n.jpg';

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

bool isPostId(String? id) => id != null && _uuid.hasMatch(id);

// --- Dates -------------------------------------------------------------------------------------

/// yyyy-mm-dd of the day (a Postgres DATE)
String dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The day of a yyyy-mm-dd date, at local midnight; null when it is not one
DateTime? parseDateOnly(String? s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s ?? '');
  if (m == null) return null;
  return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "2 Nov 2026"
String formatDay(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

/// "just now", "5 min ago", "3 h ago", "2 days ago", then the date
String timeAgo(DateTime when, DateTime now) {
  final d = now.difference(when);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 7) return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  return formatDay(when.toLocal());
}

// --- Models ------------------------------------------------------------------------------------

class CommunityPhoto {
  const CommunityPhoto({required this.path, required this.width, required this.height});

  factory CommunityPhoto.fromJson(Map<String, dynamic> j) => CommunityPhoto(
    path: '${j['path']}',
    width: (j['width'] as num? ?? 0).toInt(),
    height: (j['height'] as num? ?? 0).toInt(),
  );

  final String path;
  final int width;
  final int height;

  Map<String, dynamic> toJson() => {'path': path, 'width': width, 'height': height};
}

enum PostStatus {
  visible,
  hidden,
  removed;

  static PostStatus parse(Object? v) => values.firstWhere((s) => s.name == v, orElse: () => visible);
}

DateTime _time(Object? v) => DateTime.tryParse('${v ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

/// A post: a feed row (community_feed: stories cut at 280 characters, the attachment's kind
/// only) or the full post (community_post: the attachment and the status)
class CommunityPost {
  const CommunityPost({
    required this.id,
    required this.kind,
    this.title,
    required this.body,
    this.truncated = false,
    this.conditions = const [],
    required this.happenedOn,
    required this.lat,
    required this.lng,
    this.placeName,
    this.attachmentKind,
    this.attachment,
    this.photos = const [],
    this.helpfulCount = 0,
    this.commentCount = 0,
    required this.createdAt,
    this.editedAt,
    this.status = PostStatus.visible,
    this.authorName = 'Landscape 360 user',
    this.authorOrganization,
    this.isMine = false,
    this.iFoundHelpful = false,
    this.clubId,
    this.clubName,
    this.pinned = false,
    this.myClubRole,
  });

  /// A row of community_feed or community_post (also the cached copy of a feed page)
  factory CommunityPost.fromRow(Map<String, dynamic> r) {
    final attachment = r['attachment'] is Map
        ? Attachment.fromJson(Map<String, dynamic>.from(r['attachment'] as Map))
        : null;
    return CommunityPost(
      id: '${r['id']}',
      kind: PostKind.parse(r['kind']),
      title: r['title'] as String?,
      body: '${r['body'] ?? ''}',
      truncated: r['truncated'] == true,
      conditions: [for (final c in (r['conditions'] as List? ?? const [])) '$c'],
      happenedOn: '${r['happened_on'] ?? ''}',
      lat: (r['lat'] as num? ?? 0).toDouble(),
      lng: (r['lng'] as num? ?? 0).toDouble(),
      placeName: r['place_name'] as String?,
      attachmentKind: (r['attachment_kind'] as String?) ?? attachment?.kind,
      attachment: attachment,
      photos: [
        for (final p in (r['photos'] as List? ?? const []))
          if (p is Map) CommunityPhoto.fromJson(Map<String, dynamic>.from(p)),
      ],
      helpfulCount: _int(r['helpful_count']),
      commentCount: _int(r['comment_count']),
      createdAt: _time(r['created_at']),
      editedAt: r['edited_at'] == null ? null : _time(r['edited_at']),
      status: PostStatus.parse(r['status']),
      authorName: (r['author_name'] as String?) ?? 'Landscape 360 user',
      authorOrganization: r['author_organization'] as String?,
      isMine: r['is_mine'] == true,
      iFoundHelpful: r['i_found_helpful'] == true,
      clubId: r['club_id'] as String?,
      clubName: r['club_name'] as String?,
      pinned: r['pinned'] == true,
      myClubRole: r['my_club_role'] == null ? null : ClubRole.parse(r['my_club_role']),
    );
  }

  final String id;
  final PostKind kind;
  final String? title;
  final String body;
  final bool truncated; // a story cut short in the feed
  final List<String> conditions;
  final String happenedOn; // yyyy-mm-dd
  final double lat;
  final double lng;
  final String? placeName;
  final String? attachmentKind; // place | area | track | classic
  final Attachment? attachment; // only on the full post
  final List<CommunityPhoto> photos;
  final int helpfulCount;
  final int commentCount;
  final DateTime createdAt;
  final DateTime? editedAt;
  final PostStatus status;
  final String authorName;
  final String? authorOrganization;
  final bool isMine;
  final bool iFoundHelpful;
  final String? clubId; // null: everyone; else members of this club only
  final String? clubName;
  final bool pinned; // a club announcement, first in the club's feed
  final ClubRole? myClubRole; // my role in the post's club (full post only)

  /// A club leader or admin may pin it
  bool get canPin => clubId != null && (myClubRole?.manages ?? false);

  /// Seen by the club's members only: no public link
  bool get membersOnly => clubId != null;

  DateTime? get happenedDay => parseDateOnly(happenedOn);

  /// Same columns as the RPCs, so a cached feed page reads back with [CommunityPost.fromRow]
  Map<String, dynamic> toRow() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    'body': body,
    'truncated': truncated,
    'conditions': conditions,
    'happened_on': happenedOn,
    'lat': lat,
    'lng': lng,
    'place_name': placeName,
    'attachment_kind': attachmentKind,
    'attachment': attachment?.toJson(),
    'photos': [for (final p in photos) p.toJson()],
    'helpful_count': helpfulCount,
    'comment_count': commentCount,
    'created_at': createdAt.toUtc().toIso8601String(),
    'edited_at': editedAt?.toUtc().toIso8601String(),
    'status': status.name,
    'author_name': authorName,
    'author_organization': authorOrganization,
    'is_mine': isMine,
    'i_found_helpful': iFoundHelpful,
    'club_id': clubId,
    'club_name': clubName,
    'pinned': pinned,
    'my_club_role': myClubRole?.name,
  };

  CommunityPost copyWith({
    String? Function()? title,
    String? body,
    List<String>? conditions,
    String? Function()? placeName,
    int? helpfulCount,
    int? commentCount,
    bool? iFoundHelpful,
    DateTime? editedAt,
    bool? pinned,
  }) => CommunityPost(
    id: id,
    kind: kind,
    title: title == null ? this.title : title(),
    body: body ?? this.body,
    truncated: body == null && truncated,
    conditions: conditions ?? this.conditions,
    happenedOn: happenedOn,
    lat: lat,
    lng: lng,
    placeName: placeName == null ? this.placeName : placeName(),
    attachmentKind: attachmentKind,
    attachment: attachment,
    photos: photos,
    helpfulCount: helpfulCount ?? this.helpfulCount,
    commentCount: commentCount ?? this.commentCount,
    createdAt: createdAt,
    editedAt: editedAt ?? this.editedAt,
    status: status,
    authorName: authorName,
    authorOrganization: authorOrganization,
    isMine: isMine,
    iFoundHelpful: iFoundHelpful ?? this.iFoundHelpful,
    clubId: clubId,
    clubName: clubName,
    pinned: pinned ?? this.pinned,
    myClubRole: myClubRole,
  );

  /// "Budi S. · Mapala UI"
  String get byline => [authorName, ?authorOrganization].join(' · ');
}

class CommunityComment {
  const CommunityComment({
    required this.id,
    required this.body,
    required this.createdAt,
    this.authorName = 'Landscape 360 user',
    this.authorOrganization,
    this.isMine = false,
  });

  factory CommunityComment.fromRow(Map<String, dynamic> r) => CommunityComment(
    id: '${r['id']}',
    body: '${r['body'] ?? ''}',
    createdAt: _time(r['created_at']),
    authorName: (r['author_name'] as String?) ?? 'Landscape 360 user',
    authorOrganization: r['author_organization'] as String?,
    isMine: r['is_mine'] == true,
  );

  final String id;
  final String body;
  final DateTime createdAt;
  final String authorName;
  final String? authorOrganization;
  final bool isMine;
}

/// What the signed-in account may do today (my_community_limits)
class CommunityLimits {
  const CommunityLimits({
    required this.reportsLeft,
    required this.storiesLeft,
    required this.photos,
    required this.attachments,
    required this.banned,
    this.clubsLeft = 0,
    this.canCreateClubs = false,
  });

  factory CommunityLimits.fromRow(Map<String, dynamic> r) => CommunityLimits(
    reportsLeft: r['reports_left'] == null ? null : _int(r['reports_left']),
    storiesLeft: r['stories_left'] == null ? null : _int(r['stories_left']),
    photos: _int(r['photos']),
    attachments: r['attachments'] == true,
    banned: r['banned'] == true,
    clubsLeft: r['clubs_left'] == null ? null : _int(r['clubs_left']),
    canCreateClubs: r['can_create_clubs'] == true,
  );

  final int? reportsLeft; // null: no limit (admin)
  final int? storiesLeft;
  final int photos; // per post
  final bool attachments;
  final bool banned;
  final int? clubsLeft; // clubs this account may still create (null: no limit)
  final bool canCreateClubs; // Enterprise and the admin

  /// Creating a club is offered now: allowed and not at the limit
  bool get canCreateClubNow => canCreateClubs && (clubsLeft == null || clubsLeft! > 0);

  int? leftFor(PostKind k) => k == PostKind.report ? reportsLeft : storiesLeft;

  /// "4 trail reports and 1 story left today" / "No limit today"
  String get summary {
    if (reportsLeft == null && storiesLeft == null) return 'No daily limit';
    String n(int? v, String one, String many) => v == null ? 'unlimited $many' : '$v ${v == 1 ? one : many}';
    return '${n(reportsLeft, 'trail report', 'trail reports')} and ${n(storiesLeft, 'story', 'stories')} left today';
  }
}

/// A reported post or comment waiting for the admin (community_report_queue)
class ReportQueueItem {
  const ReportQueueItem({
    required this.targetKind,
    required this.targetId,
    required this.postId,
    required this.status,
    required this.excerpt,
    required this.authorId,
    required this.authorName,
    required this.reports,
    required this.reasons,
    required this.notes,
    required this.lastReportedAt,
    required this.authorBanned,
  });

  factory ReportQueueItem.fromRow(Map<String, dynamic> r) => ReportQueueItem(
    targetKind: r['target_kind'] == 'comment' ? 'comment' : 'post',
    targetId: '${r['target_id']}',
    postId: '${r['post_id']}',
    status: PostStatus.parse(r['status']),
    excerpt: '${r['excerpt'] ?? ''}',
    authorId: '${r['author_id']}',
    authorName: '${r['author_name'] ?? ''}',
    reports: _int(r['reports']),
    reasons: [for (final x in (r['reasons'] as List? ?? const [])) '$x'],
    notes: [for (final x in (r['notes'] as List? ?? const [])) '$x'],
    lastReportedAt: _time(r['last_reported_at']),
    authorBanned: r['author_banned'] == true,
  );

  final String targetKind; // post | comment
  final String targetId;
  final String postId;
  final PostStatus status;
  final String excerpt;
  final String authorId;
  final String authorName;
  final int reports;
  final List<String> reasons;
  final List<String> notes;
  final DateTime lastReportedAt;
  final bool authorBanned;
}

/// What the compose form sends (create_community_post)
class NewPost {
  const NewPost({
    required this.kind,
    this.title = '',
    required this.body,
    this.conditions = const [],
    required this.happenedOn,
    required this.lat,
    required this.lng,
    this.placeName = '',
    this.attachment,
    this.clubId,
  });

  factory NewPost.fromJson(Map<String, dynamic> j) => NewPost(
    kind: PostKind.parse(j['kind']),
    title: '${j['title'] ?? ''}',
    body: '${j['body'] ?? ''}',
    conditions: [for (final c in (j['conditions'] as List? ?? const [])) '$c'],
    happenedOn: '${j['happenedOn']}',
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
    placeName: '${j['placeName'] ?? ''}',
    attachment: j['attachment'] is Map ? Attachment.fromJson(Map<String, dynamic>.from(j['attachment'] as Map)) : null,
    clubId: j['clubId'] as String?,
  );

  final PostKind kind;
  final String title;
  final String body;
  final List<String> conditions;
  final String happenedOn; // yyyy-mm-dd
  final double lat;
  final double lng;
  final String placeName;
  final Attachment? attachment;
  final String? clubId; // null: everyone

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'title': title,
    'body': body,
    'conditions': conditions,
    'happenedOn': happenedOn,
    'lat': lat,
    'lng': lng,
    'placeName': placeName,
    'attachment': attachment?.toJson(),
    'clubId': clubId,
  };

  /// Arguments of create_community_post
  Map<String, dynamic> toRpcParams() => {
    'p_kind': kind.name,
    'p_title': title.trim().isEmpty ? null : title.trim(),
    'p_body': body.trim(),
    'p_conditions': conditions,
    'p_happened_on': happenedOn,
    'p_lat': lat,
    'p_lng': lng,
    'p_place_name': placeName.trim().isEmpty ? null : placeName.trim(),
    'p_attachment': attachment?.toJson(),
    'p_club_id': clubId,
  };
}

// --- Rules -------------------------------------------------------------------------------------

/// A trail report that happened more than 30 days ago
bool isOldReport(CommunityPost post, DateTime now) {
  if (post.kind != PostKind.report) return false;
  final day = post.happenedDay;
  return day != null && now.difference(day) > const Duration(days: reportFreshDays);
}

/// The author may edit for 24 hours
bool canEdit(CommunityPost post, DateTime now) =>
    post.isMine && now.difference(post.createdAt) < const Duration(hours: 24);

/// Text length as the database counts it (characters, not UTF-16 units)
int textLength(String s) => s.trim().runes.length;

/// First problem with a post before it is sent (the server checks again), or null
String? postInputError({
  required PostKind kind,
  required String body,
  String title = '',
  required List<String> conditions,
  required String happenedOn,
  required double? lat,
  required double? lng,
  required DateTime now,
}) {
  final length = textLength(body);
  if (length == 0) return 'Write something first.';
  if (length > bodyLimit[kind]!) {
    return 'A ${kind == PostKind.report ? 'trail report' : 'story'} is at most ${bodyLimit[kind]} characters.';
  }
  if (textLength(title) > titleLimit) return 'The title is at most $titleLimit characters.';
  if (kind == PostKind.report && conditions.isEmpty) return 'Choose at least one trail condition.';
  if (conditions.length > maxConditions) return 'Choose at most $maxConditions conditions.';
  if (conditions.any((c) => !trailConditions.any((t) => t.id == c))) return 'Unknown trail condition.';
  if (lat == null || lng == null || !lat.isFinite || !lng.isFinite || lat.abs() > 90 || lng.abs() > 180) {
    return 'Set where it is on the map.';
  }
  final day = parseDateOnly(happenedOn);
  if (day == null) return 'Choose the date.';
  final today = DateTime(now.year, now.month, now.day);
  if (day.isAfter(today)) return 'The date cannot be in the future.';
  if (today.difference(day).inDays > 366) return 'The date must be within the last year.';
  return null;
}

/// The condition that sets a post's colour and icon on the map (null: a story without one)
TrailCondition? mainCondition(CommunityPost post) =>
    post.conditions.isEmpty ? null : conditionOf(post.conditions.first);

/// Posts for the map layer: the last 30 days, without old trail reports
List<CommunityPost> postsForMap(Iterable<CommunityPost> posts, DateTime now) => [
  for (final p in posts)
    if (!isOldReport(p, now) && now.difference(p.createdAt) <= const Duration(days: reportFreshDays)) p,
];

/// "Desa, Kecamatan" for the place name
String villagePlaceName(String desa, String kecamatan) =>
    kecamatan.trim().isEmpty || kecamatan.trim() == desa.trim() ? desa.trim() : '${desa.trim()}, ${kecamatan.trim()}';

// --- Feed --------------------------------------------------------------------------------------

/// (west, south, east, north)
typedef Bounds = (double, double, double, double);

enum FeedScope { nearMap, all }

class FeedFilter {
  const FeedFilter({this.scope = FeedScope.nearMap, this.kinds = const {}, this.conditions = const {}, this.clubId});

  final FeedScope scope; // near the map first, like the web
  final Set<PostKind> kinds; // empty: both
  final Set<String> conditions; // empty: any
  final String? clubId; // null: "Everyone" (public posts and my clubs'); else that club only

  FeedFilter copyWith({FeedScope? scope, Set<PostKind>? kinds, Set<String>? conditions, String? Function()? clubId}) =>
      FeedFilter(
        scope: scope ?? this.scope,
        kinds: kinds ?? this.kinds,
        conditions: conditions ?? this.conditions,
        clubId: clubId == null ? this.clubId : clubId(),
      );

  bool get isDefault => scope == FeedScope.nearMap && kinds.isEmpty && conditions.isEmpty && clubId == null;

  @override
  bool operator ==(Object other) =>
      other is FeedFilter &&
      other.scope == scope &&
      other.clubId == clubId &&
      other.kinds.length == kinds.length &&
      other.kinds.containsAll(kinds) &&
      other.conditions.length == conditions.length &&
      other.conditions.containsAll(conditions);

  @override
  int get hashCode => Object.hash(scope, clubId, Object.hashAllUnordered(kinds), Object.hashAllUnordered(conditions));
}

/// Arguments of community_feed
Map<String, dynamic> feedParams({
  Bounds? bounds,
  Set<PostKind> kinds = const {},
  Set<String> conditions = const {},
  DateTime? since,
  DateTime? before,
  int limit = feedPageSize,
  String? clubId,
}) => {
  'p_west': bounds?.$1,
  'p_south': bounds?.$2,
  'p_east': bounds?.$3,
  'p_north': bounds?.$4,
  'p_kinds': kinds.isEmpty
      ? null
      : [
          for (final k in PostKind.values)
            if (kinds.contains(k)) k.name,
        ],
  'p_conditions': conditions.isEmpty
      ? null
      : [
          for (final c in trailConditions)
            if (conditions.contains(c.id)) c.id,
        ],
  'p_since': since?.toUtc().toIso8601String(),
  'p_before': before?.toUtc().toIso8601String(),
  'p_limit': limit,
  'p_club': clubId,
};

// --- Clubs -------------------------------------------------------------------------------------
// Enterprise accounts (and the admin) create clubs and add members by email; any signed-in
// account can be a member. A club's posts are seen by its members only
// (20261102000025_community_clubs.sql).

const clubNameMin = 2;
const clubNameMax = 60;
const clubDescriptionMax = 500;
const clubMembersMax = 200;
const clubRegionMax = 80;
const clubContactMax = 200;

/// Longest side of a club photo (CLUB_PHOTO_SIDE on the web)
const clubPhotoSide = 640;

/// Storage path of a club photo: `<user id>/club-<club id>-<millis>.jpg` (a new name each time)
String clubPhotoPath(String userId, String clubId, int millis) => '$userId/club-$clubId-$millis.jpg';

/// A contact the leader typed, as a link when it looks like one (contactHref on the web):
/// a URL as it is, an @handle on Instagram, an Indonesian mobile number on WhatsApp, a domain
/// over https; otherwise null (shown as text)
String? contactHref(String contact) {
  final c = contact.trim();
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(c)) return c;
  if (RegExp(r'^@[\w.]{1,30}$').hasMatch(c)) return 'https://instagram.com/${c.substring(1)}';
  if (RegExp(r'^(\+?62|0)[\s-]?8[\d\s-]{7,14}$').hasMatch(c)) {
    return 'https://wa.me/${c.replaceAll(RegExp(r'[\s-]'), '').replaceFirst(RegExp('^0'), '62').replaceFirst(RegExp(r'^\+'), '')}';
  }
  if (RegExp(r'^[\w-]+(\.[\w-]+)+(/\S*)?$').hasMatch(c)) return 'https://$c';
  return null;
}

/// Who sees a post, for the compose form and the badge
const everyoneLabel = 'Everyone';
const membersOnlyLabel = 'Members only';

enum ClubRole {
  owner('Leader'),
  admin('Admin'),
  member('Member');

  const ClubRole(this.label);

  /// As shown (ROLE_LABEL on the web): the owner is the "Leader"
  final String label;

  static ClubRole parse(Object? v) => values.firstWhere((r) => r.name == v, orElse: () => member);

  /// The leader and admins manage members, invite links, folders and pins
  bool get manages => this != member;
}

/// A club I belong to (my_community_clubs)
class CommunityClub {
  const CommunityClub({
    required this.id,
    required this.name,
    this.description,
    required this.role,
    this.memberCount = 1,
    this.ownerName = '',
    required this.createdAt,
    this.region,
    this.contact,
    this.photoPath,
    this.updatedAt,
    this.newPosts = 0,
    this.canManage = false,
  });

  factory CommunityClub.fromRow(Map<String, dynamic> r) => CommunityClub(
    id: '${r['id']}',
    name: '${r['name'] ?? ''}',
    description: r['description'] as String?,
    role: ClubRole.parse(r['role']),
    memberCount: _int(r['member_count']),
    ownerName: '${r['owner_name'] ?? ''}',
    createdAt: _time(r['created_at']),
    region: r['region'] as String?,
    contact: r['contact'] as String?,
    photoPath: r['photo_path'] as String?,
    updatedAt: r['updated_at'] == null ? null : _time(r['updated_at']),
    newPosts: _int(r['new_posts']),
    canManage: r['can_manage'] == true,
  );

  final String id;
  final String name;
  final String? description;
  final String? region; // home base
  final String? contact; // as typed: @handle, site or phone (see [contactHref])
  final String? photoPath; // in the photos bucket
  final DateTime? updatedAt;
  final int newPosts; // since I last looked at the club's feed
  final bool canManage; // leader or admin, while the leader may still own clubs
  final ClubRole role; // mine
  final int memberCount;
  final String ownerName;
  final DateTime createdAt;

  bool get isOwner => role == ClubRole.owner;

  /// The letter on the avatar without a photo
  String get initial => name.trim().isEmpty ? '?' : String.fromCharCode(name.trim().runes.first).toUpperCase();
}

/// A member of a club (community_club_members); the email only for the owner
class ClubMember {
  const ClubMember({
    required this.userId,
    required this.name,
    this.organization,
    this.email,
    required this.role,
    required this.addedAt,
    this.isMe = false,
  });

  factory ClubMember.fromRow(Map<String, dynamic> r) => ClubMember(
    userId: '${r['user_id']}',
    name: '${r['name'] ?? ''}',
    organization: r['organization'] as String?,
    email: r['email'] as String?,
    role: ClubRole.parse(r['role']),
    addedAt: _time(r['added_at']),
    isMe: r['is_me'] == true,
  );

  final String userId;
  final String name;
  final String? organization;
  final String? email;
  final ClubRole role;
  final DateTime addedAt;
  final bool isMe;
}

/// First problem with the club form, or null
String? clubInputError({required String name, String description = '', String region = '', String contact = ''}) {
  final n = textLength(name);
  if (n < clubNameMin) return 'Give the club a name.';
  if (n > clubNameMax) return 'A club name is at most $clubNameMax characters.';
  if (textLength(description) > clubDescriptionMax) return 'The description is at most $clubDescriptionMax characters.';
  if (textLength(region) > clubRegionMax) return 'The home base is at most $clubRegionMax characters.';
  if (textLength(contact) > clubContactMax) return 'The contact is at most $clubContactMax characters.';
  return null;
}

final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// First problem with an email to add, or null
String? memberEmailError(String email) =>
    _email.hasMatch(email.trim()) ? null : 'Enter the email of a Landscape 360 account.';

// --- Club invite links (20261102000027) --------------------------------------------------------

final _inviteToken = RegExp(r'^[0-9a-f]{32}$');

/// Whether [token] looks like an invite token (32 hex)
bool isInviteToken(String? token) => token != null && _inviteToken.hasMatch(token);

/// Link that lets a signed-in account join the club: `/?join=<token>` (7 days)
String joinUrl(String token, [String base = 'https://landscape360.jcdigital.co.id']) => '$base/?join=$token';

/// An active invite link (community_club_invites)
class ClubInvite {
  const ClubInvite({required this.token, required this.expiresAt, this.uses = 0, this.createdByName = ''});

  factory ClubInvite.fromRow(Map<String, dynamic> r) => ClubInvite(
    token: '${r['token']}',
    expiresAt: _time(r['expires_at']),
    uses: _int(r['uses']),
    createdByName: '${r['created_by_name'] ?? ''}',
  );

  final String token;
  final DateTime expiresAt;
  final int uses;
  final String createdByName;

  String get url => joinUrl(token);
}

/// What an invite link shows before joining (community_club_invite_info; no sign-in needed)
class ClubInviteInfo {
  const ClubInviteInfo({
    required this.clubId,
    required this.name,
    this.description,
    this.region,
    this.photoPath,
    this.memberCount = 0,
    this.leaderName = '',
    this.valid = false,
    this.isMember = false,
  });

  factory ClubInviteInfo.fromRow(Map<String, dynamic> r) => ClubInviteInfo(
    clubId: '${r['club_id']}',
    name: '${r['name'] ?? ''}',
    description: r['description'] as String?,
    region: r['region'] as String?,
    photoPath: r['photo_path'] as String?,
    memberCount: _int(r['member_count']),
    leaderName: '${r['leader_name'] ?? ''}',
    valid: r['valid'] == true,
    isMember: r['is_member'] == true,
  );

  final String clubId;
  final String name;
  final String? description;
  final String? region;
  final String? photoPath;
  final int memberCount;
  final String leaderName;
  final bool valid; // not expired or stopped
  final bool isMember;

  /// The club as the avatar and card show it
  CommunityClub get club => CommunityClub(
    id: clubId,
    name: name,
    description: description,
    role: ClubRole.member,
    memberCount: memberCount,
    ownerName: leaderName,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    region: region,
    photoPath: photoPath,
  );
}

// --- Club workspace -----------------------------------------------------------------------------
// Copies of members' map data (the same JSON as a post attachment), in folders. Any member adds;
// whoever added an item, or a manager, changes it; managers keep the folders.

/// Tracks keep more points in the workspace than on a post (WORKSPACE_TRACK_POINTS)
const workspaceTrackPoints = 5000;
const clubFolderNameMax = 60;
const clubItemNameMax = 120;
const clubItemNoteMax = 500;

class ClubFolder {
  const ClubFolder({required this.id, required this.name, this.itemCount = 0});

  factory ClubFolder.fromRow(Map<String, dynamic> r) =>
      ClubFolder(id: '${r['id']}', name: '${r['name'] ?? ''}', itemCount: _int(r['item_count']));

  final String id;
  final String name;
  final int itemCount;
}

/// An item in the list (community_club_items); its geometry comes with community_club_item
class ClubItem {
  const ClubItem({
    required this.id,
    this.folderId,
    required this.kind,
    required this.name,
    this.note,
    this.distanceM,
    this.category,
    this.color,
    this.token,
    this.addedByName = '',
    this.isMine = false,
    required this.createdAt,
  });

  factory ClubItem.fromRow(Map<String, dynamic> r) {
    final sum = r['summary'] is Map ? Map<String, dynamic>.from(r['summary'] as Map) : const <String, dynamic>{};
    return ClubItem(
      id: '${r['id']}',
      folderId: r['folder_id'] as String?,
      kind: '${r['kind']}',
      name: '${r['name'] ?? ''}',
      note: r['note'] as String?,
      distanceM: (sum['distance_m'] as num?)?.toDouble(),
      category: sum['category'] as String?,
      color: sum['color'] as String?,
      token: sum['token'] as String?,
      addedByName: '${r['added_by_name'] ?? ''}',
      isMine: r['is_mine'] == true,
      createdAt: _time(r['created_at']),
    );
  }

  final String id;
  final String? folderId; // null: not in a folder
  final String kind; // track | area | place | classic
  final String name;
  final String? note;
  final double? distanceM;
  final String? category;
  final String? color;
  final String? token;
  final String addedByName;
  final bool isMine;
  final DateTime createdAt;
}
