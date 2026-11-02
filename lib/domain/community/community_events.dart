import '../tracks/track_recorder_geo.dart';

// Club expeditions and field events (20261102000029_community_club_events.sql): an event with a
// time, meeting point, planned route from the workspace, quota and approval; participants with
// an emergency contact only the organisers see; a gear checklist; and live position sharing,
// opt-in per event, from the mobile app only, seen by the club's members. Sharing is open from
// 2 hours before the start until the end, and the server keeps positions 30 days after it.

DateTime _time(Object? v) => DateTime.tryParse('${v ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

DateTime? _timeOrNull(Object? v) => v == null ? null : DateTime.tryParse('$v');

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

int? _intOrNull(Object? v) => v == null ? null : _int(v);

double? _double(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');

/// planned · running · ended · cancelled (community_event_state)
enum EventState {
  planned('Upcoming'),
  running('Running now'),
  ended('Ended'),
  cancelled('Cancelled');

  const EventState(this.label);

  final String label;

  static EventState parse(Object? v) => values.firstWhere((s) => s.name == v, orElse: () => planned);
}

/// Where I stand with an event (null: not joined)
enum ParticipantStatus {
  pending('Waiting for approval'),
  going('Going'),
  declined('Declined');

  const ParticipantStatus(this.label);

  final String label;

  static ParticipantStatus? parse(Object? v) => values.where((s) => s.name == v).firstOrNull;
}

const eventTitleMin = 2;
const eventTitleMax = 80;
const eventDescriptionMax = 2000;
const eventMeetingNameMax = 120;
const eventQuotaMax = 500;
const eventMaxDays = 30;
const checklistLabelMax = 80;
const emergencyNameMax = 80;
const emergencyPhoneMax = 30;

/// Sharing opens this long before the start (getting to the meeting point)
const liveOpensBefore = Duration(hours: 2);

/// A position at least this often while sharing, and when moved this far
const liveFixEvery = Duration(minutes: 2);
const liveMinMoveM = 50.0;

/// Batches go out this often (and at once when the signal is back), at most [liveBatchMax] each
const liveBatchEvery = Duration(minutes: 2);
const liveBatchMax = 500;

/// Someone sharing who has not been seen for this long gets a warning (organisers)
const liveStaleAfter = Duration(minutes: 60);

/// A dot on the live map fades when its position is older than this
const liveFadeAfter = Duration(minutes: 15);

/// The live map reloads this often while it or the event page is open
const liveRefreshEvery = Duration(seconds: 30);

/// Whether [now] is inside the sharing window of an event
bool liveWindowOpen({
  required DateTime startsAt,
  required DateTime endsAt,
  required DateTime now,
  bool cancelled = false,
}) => !cancelled && !now.isBefore(startsAt.subtract(liveOpensBefore)) && !now.isAfter(endsAt);

/// A row of community_events (the club's list)
class EventSummary {
  const EventSummary({
    required this.id,
    required this.title,
    required this.startsAt,
    required this.endsAt,
    required this.state,
    this.meetingName,
    this.goingCount = 0,
    this.pendingCount = 0,
    this.quota,
    this.myStatus,
    this.sharingCount = 0,
  });

  factory EventSummary.fromRow(Map<String, dynamic> r) => EventSummary(
    id: '${r['id']}',
    title: '${r['title'] ?? ''}',
    startsAt: _time(r['starts_at']),
    endsAt: _time(r['ends_at']),
    state: EventState.parse(r['state']),
    meetingName: r['meeting_name'] as String?,
    goingCount: _int(r['going_count']),
    pendingCount: _int(r['pending_count']),
    quota: _intOrNull(r['quota']),
    myStatus: ParticipantStatus.parse(r['my_status']),
    sharingCount: _int(r['sharing_count']),
  );

  final String id;
  final String title;
  final DateTime startsAt;
  final DateTime endsAt;
  final EventState state;
  final String? meetingName;
  final int goingCount;
  final int pendingCount;
  final int? quota;
  final ParticipantStatus? myStatus;
  final int sharingCount;

  /// "5 going" or "5 / 12 going"
  String get goingText => quota == null ? '$goingCount going' : '$goingCount / $quota going';
}

/// One event in full (community_event), with my participation
class CommunityEvent {
  const CommunityEvent({
    required this.id,
    required this.clubId,
    this.clubName = '',
    required this.title,
    this.description,
    required this.startsAt,
    required this.endsAt,
    required this.state,
    this.meetingName,
    this.meetingLat,
    this.meetingLng,
    this.routeItemId,
    this.routeName,
    this.quota,
    this.needsApproval = false,
    this.goingCount = 0,
    this.pendingCount = 0,
    this.createdByName = '',
    this.myStatus,
    this.myEmergencyName,
    this.myEmergencyPhone,
    this.iAmSharing = false,
    this.canShare = false,
    this.canManage = false,
  });

  factory CommunityEvent.fromRow(Map<String, dynamic> r) => CommunityEvent(
    id: '${r['id']}',
    clubId: '${r['club_id']}',
    clubName: '${r['club_name'] ?? ''}',
    title: '${r['title'] ?? ''}',
    description: r['description'] as String?,
    startsAt: _time(r['starts_at']),
    endsAt: _time(r['ends_at']),
    state: EventState.parse(r['state']),
    meetingName: r['meeting_name'] as String?,
    meetingLat: _double(r['meeting_lat']),
    meetingLng: _double(r['meeting_lng']),
    routeItemId: r['route_item_id'] as String?,
    routeName: r['route_name'] as String?,
    quota: _intOrNull(r['quota']),
    needsApproval: r['needs_approval'] == true,
    goingCount: _int(r['going_count']),
    pendingCount: _int(r['pending_count']),
    createdByName: '${r['created_by_name'] ?? ''}',
    myStatus: ParticipantStatus.parse(r['my_status']),
    myEmergencyName: r['my_emergency_name'] as String?,
    myEmergencyPhone: r['my_emergency_phone'] as String?,
    iAmSharing: r['i_am_sharing'] == true,
    canShare: r['can_share'] == true,
    canManage: r['can_manage'] == true,
  );

  final String id;
  final String clubId;
  final String clubName;
  final String title;
  final String? description;
  final DateTime startsAt;
  final DateTime endsAt;
  final EventState state;
  final String? meetingName;
  final double? meetingLat;
  final double? meetingLng;
  final String? routeItemId; // a workspace track or area
  final String? routeName;
  final int? quota;
  final bool needsApproval;
  final int goingCount;
  final int pendingCount;
  final String createdByName;
  final ParticipantStatus? myStatus;
  final String? myEmergencyName;
  final String? myEmergencyPhone;
  final bool iAmSharing;
  final bool canShare; // going and inside the sharing window
  final bool canManage;

  bool get hasMeetingPoint => meetingLat != null && meetingLng != null;

  /// Joining is open until the end, unless cancelled or full
  bool get canJoin =>
      myStatus == null &&
      state != EventState.cancelled &&
      state != EventState.ended &&
      (quota == null || needsApproval || goingCount < quota!);

  /// The live map is worth opening once the event has started
  bool get hasLiveMap => state == EventState.running || state == EventState.ended;

  String get goingText => quota == null ? '$goingCount going' : '$goingCount / $quota going';
}

/// A participant (community_event_participants); emergency contacts only for organisers
class EventParticipant {
  const EventParticipant({
    required this.userId,
    required this.name,
    this.organization,
    required this.status,
    required this.joinedAt,
    this.isMe = false,
    this.emergencyName,
    this.emergencyPhone,
    this.checkedCount = 0,
    this.sharing = false,
    this.lastSeenAt,
  });

  factory EventParticipant.fromRow(Map<String, dynamic> r) => EventParticipant(
    userId: '${r['user_id']}',
    name: '${r['name'] ?? ''}',
    organization: r['organization'] as String?,
    status: ParticipantStatus.parse(r['status']) ?? ParticipantStatus.pending,
    joinedAt: _time(r['joined_at']),
    isMe: r['is_me'] == true,
    emergencyName: r['emergency_name'] as String?,
    emergencyPhone: r['emergency_phone'] as String?,
    checkedCount: _int(r['checked_count']),
    sharing: r['sharing'] == true,
    lastSeenAt: _timeOrNull(r['last_seen_at']),
  );

  final String userId;
  final String name;
  final String? organization;
  final ParticipantStatus status;
  final DateTime joinedAt;
  final bool isMe;
  final String? emergencyName;
  final String? emergencyPhone;
  final int checkedCount;
  final bool sharing;
  final DateTime? lastSeenAt;

  /// Sharing but no position for over an hour: worth checking on (organisers)
  bool notSeenFor(DateTime now) => sharing && (lastSeenAt == null || now.difference(lastSeenAt!) > liveStaleAfter);
}

/// A checklist item with my tick and how many ticked it
class ChecklistItem {
  const ChecklistItem({required this.id, required this.label, this.checked = false, this.checkedCount = 0});

  factory ChecklistItem.fromRow(Map<String, dynamic> r) => ChecklistItem(
    id: '${r['id']}',
    label: '${r['label'] ?? ''}',
    checked: r['checked'] == true,
    checkedCount: _int(r['checked_count']),
  );

  final String id;
  final String label;
  final bool checked;
  final int checkedCount;

  ChecklistItem toggled(bool on) => ChecklistItem(
    id: id,
    label: label,
    checked: on,
    checkedCount: checkedCount + (on == checked ? 0 : (on ? 1 : -1)),
  );
}

/// The last position of someone who shared (community_live_latest)
class LivePosition {
  const LivePosition({
    required this.userId,
    required this.name,
    required this.lat,
    required this.lng,
    this.accuracyM,
    this.altitudeM,
    this.battery,
    required this.recordedAt,
    this.sharing = false,
    this.isMe = false,
  });

  factory LivePosition.fromRow(Map<String, dynamic> r) => LivePosition(
    userId: '${r['user_id']}',
    name: '${r['name'] ?? ''}',
    lat: _double(r['lat']) ?? 0,
    lng: _double(r['lng']) ?? 0,
    accuracyM: _double(r['accuracy_m']),
    altitudeM: _double(r['altitude_m']),
    battery: _intOrNull(r['battery']),
    recordedAt: _time(r['recorded_at']),
    sharing: r['sharing'] == true,
    isMe: r['is_me'] == true,
  );

  final String userId;
  final String name;
  final double lat;
  final double lng;
  final double? accuracyM;
  final double? altitudeM;
  final int? battery;
  final DateTime recordedAt;
  final bool sharing;
  final bool isMe;

  /// Not seen for over 15 minutes: drawn faded
  bool fadedAt(DateTime now) => now.difference(recordedAt) > liveFadeAfter;
}

/// A point of someone's trail (community_live_trail), oldest first
class TrailPoint {
  const TrailPoint({required this.lat, required this.lng, this.altitudeM, required this.recordedAt});

  factory TrailPoint.fromRow(Map<String, dynamic> r) => TrailPoint(
    lat: _double(r['lat']) ?? 0,
    lng: _double(r['lng']) ?? 0,
    altitudeM: _double(r['altitude_m']),
    recordedAt: _time(r['recorded_at']),
  );

  final double lat;
  final double lng;
  final double? altitudeM;
  final DateTime recordedAt;
}

/// A position the phone sends (report_community_live), kept on the phone until the server has it
class LivePoint {
  const LivePoint({
    required this.lat,
    required this.lng,
    this.accuracyM,
    this.altitudeM,
    this.speedMs,
    this.battery,
    required this.recordedAt,
  });

  factory LivePoint.fromJson(Map<String, dynamic> j) => LivePoint(
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
    accuracyM: _double(j['accuracy_m']),
    altitudeM: _double(j['altitude_m']),
    speedMs: _double(j['speed_ms']),
    battery: _intOrNull(j['battery']),
    recordedAt: _time(j['recorded_at']),
  );

  final double lat;
  final double lng;
  final double? accuracyM;
  final double? altitudeM;
  final double? speedMs;
  final int? battery;
  final DateTime recordedAt;

  double _r(double v, int places) => double.parse(v.toStringAsFixed(places));

  /// The shape the server reads (coordinates to ~1 cm, the rest rounded)
  Map<String, dynamic> toJson() => {
    'lat': _r(lat, 7),
    'lng': _r(lng, 7),
    'accuracy_m': accuracyM == null ? null : _r(accuracyM!, 1),
    'altitude_m': altitudeM == null ? null : _r(altitudeM!, 1),
    'speed_ms': speedMs == null ? null : _r(speedMs!, 2),
    'battery': battery,
    'recorded_at': recordedAt.toUtc().toIso8601String(),
  };
}

/// Whether a new fix is kept while sharing: the first, then one at least every 2 minutes or
/// after moving 50 m (fewer points, less battery and data)
bool keepLiveFix({required LivePoint? last, required double lat, required double lng, required DateTime at}) {
  if (last == null) return true;
  if (!at.isAfter(last.recordedAt)) return false;
  if (at.difference(last.recordedAt) >= liveFixEvery) return true;
  return haversineDistance((lat: last.lat, lng: last.lng), (lat: lat, lng: lng)) >= liveMinMoveM;
}

/// The next batch to send: the oldest points first, at most [liveBatchMax]
List<LivePoint> nextLiveBatch(List<LivePoint> pending) =>
    pending.length <= liveBatchMax ? pending : pending.sublist(0, liveBatchMax);

/// Live trails have a fix every few minutes: gaps up to 10 minutes still count as moving
const liveTrailConfig = TrackRecorderConfig(maxMovingGapMs: 10 * 60 * 1000);

/// Distance, moving time and climb of a shared trail (my summary after the event)
TrackStats trailSummary(List<TrailPoint> trail) => accumulatePoints([
  for (final p in trail)
    TrackPoint(
      lat: p.lat,
      lng: p.lng,
      alt: p.altitudeM,
      accuracy: 0,
      speed: null,
      timestamp: p.recordedAt.millisecondsSinceEpoch,
      segment: 0,
    ),
], liveTrailConfig).stats;

/// First problem with the event form, or null
String? eventInputError({
  required String title,
  String description = '',
  required DateTime? startsAt,
  required DateTime? endsAt,
  int? quota,
  bool editing = false,
  required DateTime now,
}) {
  final t = title.trim().runes.length;
  if (t < eventTitleMin) return 'Give the event a title.';
  if (t > eventTitleMax) return 'The title is at most $eventTitleMax characters.';
  if (description.trim().runes.length > eventDescriptionMax) {
    return 'The description is at most $eventDescriptionMax characters.';
  }
  if (startsAt == null || endsAt == null) return 'Set the start and the end.';
  if (!endsAt.isAfter(startsAt)) return 'The end must be after the start.';
  if (endsAt.difference(startsAt) > const Duration(days: eventMaxDays)) return 'An event can last up to 30 days.';
  if (!editing && startsAt.isBefore(now.subtract(const Duration(days: 1)))) return 'The start cannot be in the past.';
  if (quota != null && (quota < 1 || quota > eventQuotaMax)) return 'The quota is 1 to $eventQuotaMax people.';
  return null;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String _day(DateTime d) => '${d.day} ${_months[d.month - 1]}';

/// "Sat 8 Nov, 05:00" style pieces in local time: "8 Nov 05:00 – 9 Nov 14:00", or
/// "8 Nov 05:00 – 14:00" on one day
String formatEventRange(DateTime startsAt, DateTime endsAt) {
  final s = startsAt.toLocal(), e = endsAt.toLocal();
  final sameDay = s.year == e.year && s.month == e.month && s.day == e.day;
  return sameDay ? '${_day(s)} ${_hm(s)} – ${_hm(e)}' : '${_day(s)} ${_hm(s)} – ${_day(e)} ${_hm(e)}';
}

/// "14:00" today, else "9 Nov 14:00" (local time), for "until …"
String formatUntil(DateTime when, DateTime now) {
  final w = when.toLocal(), n = now.toLocal();
  return w.year == n.year && w.month == n.month && w.day == n.day ? _hm(w) : '${_day(w)} ${_hm(w)}';
}
