import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/community/community_events.dart';

// Club events (20261102000029): states and labels, mapping of the RPC rows, the live sharing
// rules (which fixes are kept, batches, the sharing window) and the trip summary

const _event = 'e1e1e1e1-0000-4000-8000-000000000001';
const _club = '11111111-2222-4333-8444-555555555555';

Map<String, dynamic> eventRow({String state = 'running', String? myStatus = 'going', bool canManage = false}) => {
  'id': _event,
  'club_id': _club,
  'club_name': 'Mapala UI',
  'title': 'Gede–Pangrango traverse',
  'description': 'Bawa jas hujan',
  'starts_at': '2026-11-08T22:00:00Z',
  'ends_at': '2026-11-09T10:00:00Z',
  'state': state,
  'meeting_name': 'Basecamp Cibodas',
  'meeting_lat': -6.74,
  'meeting_lng': 106.99,
  'route_item_id': 'i1',
  'route_name': 'Jalur Cibodas',
  'quota': 12,
  'needs_approval': true,
  'going_count': 5,
  'pending_count': 2,
  'created_by_name': 'Budi S.',
  'my_status': myStatus,
  'my_emergency_name': 'Ibu',
  'my_emergency_phone': '08123',
  'i_am_sharing': false,
  'can_share': true,
  'can_manage': canManage,
};

void main() {
  final now = DateTime.utc(2026, 11, 9, 3);

  test('states and statuses read and say what the web says', () {
    expect([for (final s in EventState.values) s.label], ['Upcoming', 'Running now', 'Ended', 'Cancelled']);
    expect(EventState.parse('running'), EventState.running);
    expect(EventState.parse('nope'), EventState.planned);
    expect(ParticipantStatus.parse('pending')!.label, 'Waiting for approval');
    expect(ParticipantStatus.parse(null), isNull);
  });

  test('an event list row', () {
    final e = EventSummary.fromRow({
      'id': _event,
      'title': 'Traverse',
      'starts_at': '2026-11-08T22:00:00Z',
      'ends_at': '2026-11-09T10:00:00Z',
      'state': 'planned',
      'meeting_name': null,
      'going_count': 5,
      'pending_count': 1,
      'quota': 12,
      'my_status': null,
      'sharing_count': 3,
    });
    expect((e.state, e.goingText, e.myStatus, e.sharingCount), (EventState.planned, '5 / 12 going', null, 3));
    final open = EventSummary.fromRow({'id': 'x', 'title': 'T', 'state': 'ended', 'going_count': 2, 'quota': null});
    expect(open.goingText, '2 going');
  });

  test('one event with my part', () {
    final e = CommunityEvent.fromRow(eventRow());
    expect((e.clubName, e.routeName, e.quota, e.needsApproval), ('Mapala UI', 'Jalur Cibodas', 12, true));
    expect((e.myStatus, e.myEmergencyPhone, e.canShare, e.canManage), (ParticipantStatus.going, '08123', true, false));
    expect((e.hasMeetingPoint, e.hasLiveMap, e.canJoin), (true, true, false));
    expect(e.startsAt, DateTime.utc(2026, 11, 8, 22));
    final notJoined = CommunityEvent.fromRow(eventRow(state: 'planned', myStatus: null));
    expect(notJoined.canJoin, isTrue, reason: 'asks for approval, so a full quota does not block asking');
    final full = CommunityEvent.fromRow({
      ...eventRow(state: 'planned', myStatus: null),
      'needs_approval': false,
      'going_count': 12,
    });
    expect(full.canJoin, isFalse);
    expect(CommunityEvent.fromRow(eventRow(state: 'cancelled', myStatus: null)).canJoin, isFalse);
    expect(CommunityEvent.fromRow({...eventRow(), 'meeting_lat': null, 'meeting_lng': null}).hasMeetingPoint, isFalse);
  });

  test('participants, with the "not seen for over 60 min" warning for those sharing', () {
    Map<String, dynamic> row({bool sharing = true, String? seen = '2026-11-09T02:30:00Z'}) => {
      'user_id': 'u2',
      'name': 'Rina A.',
      'organization': null,
      'status': 'going',
      'joined_at': '2026-11-01T00:00:00Z',
      'is_me': false,
      'emergency_name': 'Ayah',
      'emergency_phone': '0812',
      'checked_count': 3,
      'sharing': sharing,
      'last_seen_at': seen,
    };
    final p = EventParticipant.fromRow(row());
    expect((p.status, p.emergencyPhone, p.checkedCount), (ParticipantStatus.going, '0812', 3));
    expect(p.notSeenFor(now), isFalse, reason: '30 min');
    expect(EventParticipant.fromRow(row(seen: '2026-11-09T01:59:00Z')).notSeenFor(now), isTrue);
    expect(EventParticipant.fromRow(row(seen: null)).notSeenFor(now), isTrue);
    expect(EventParticipant.fromRow(row(sharing: false, seen: null)).notSeenFor(now), isFalse);
  });

  test('checklist ticks count once', () {
    final i = ChecklistItem.fromRow({'id': 'c1', 'label': 'Headlamp', 'checked': false, 'checked_count': 2});
    expect(i.toggled(true).checkedCount, 3);
    expect(i.toggled(true).toggled(false).checkedCount, 2);
    expect(i.toggled(false).checkedCount, 2, reason: 'already off');
  });

  test('live positions fade after 15 minutes; trail points', () {
    final p = LivePosition.fromRow({
      'user_id': 'u2',
      'name': 'Rina A.',
      'lat': -6.77,
      'lng': 106.97,
      'accuracy_m': 8.5,
      'altitude_m': 2400.0,
      'battery': 61,
      'recorded_at': '2026-11-09T02:50:00Z',
      'sharing': true,
      'is_me': false,
    });
    expect((p.battery, p.altitudeM, p.fadedAt(now)), (61, 2400.0, false));
    expect(p.fadedAt(now.add(const Duration(minutes: 6))), isTrue);
    final t = TrailPoint.fromRow({'lat': 1, 'lng': 2, 'altitude_m': null, 'recorded_at': '2026-11-09T02:50:00Z'});
    expect((t.lat, t.lng, t.altitudeM), (1.0, 2.0, null));
  });

  test('a position goes out in the shape report_community_live reads', () {
    final p = LivePoint(
      lat: -6.123456789,
      lng: 106.987654321,
      accuracyM: 12.345,
      altitudeM: 2412.06,
      speedMs: 1.2345,
      battery: 80,
      recordedAt: DateTime.utc(2026, 11, 9, 2, 0, 1),
    );
    expect(p.toJson(), {
      'lat': -6.1234568,
      'lng': 106.9876543,
      'accuracy_m': 12.3,
      'altitude_m': 2412.1,
      'speed_ms': 1.23,
      'battery': 80,
      'recorded_at': '2026-11-09T02:00:01.000Z',
    });
    expect(LivePoint.fromJson(p.toJson()).toJson(), p.toJson());
  });

  test('a fix is kept first, then every 2 minutes or after 50 m', () {
    final t0 = DateTime.utc(2026, 11, 9, 2);
    final last = LivePoint(lat: -6.7, lng: 106.9, recordedAt: t0);
    expect(keepLiveFix(last: null, lat: 0, lng: 0, at: t0), isTrue);
    // 30 s later, ~11 m away: no
    expect(keepLiveFix(last: last, lat: -6.7001, lng: 106.9, at: t0.add(const Duration(seconds: 30))), isFalse);
    // 30 s later, ~56 m away: yes
    expect(keepLiveFix(last: last, lat: -6.7005, lng: 106.9, at: t0.add(const Duration(seconds: 30))), isTrue);
    // 2 minutes later, not moved: yes
    expect(keepLiveFix(last: last, lat: -6.7, lng: 106.9, at: t0.add(liveFixEvery)), isTrue);
    // Older than the last: no
    expect(keepLiveFix(last: last, lat: -6.8, lng: 106.9, at: t0), isFalse);
  });

  test('batches of at most 500, oldest first', () {
    final t0 = DateTime.utc(2026);
    final points = [for (var i = 0; i < 1203; i++) LivePoint(lat: 0, lng: 0, recordedAt: t0.add(Duration(minutes: i)))];
    final batch = nextLiveBatch(points);
    expect(batch.length, liveBatchMax);
    expect(batch.first.recordedAt, t0);
    expect(nextLiveBatch(points.sublist(0, 7)).length, 7);
  });

  test('the sharing window: 2 hours before the start to the end', () {
    final start = DateTime.utc(2026, 11, 8, 22), end = DateTime.utc(2026, 11, 9, 10);
    expect(liveWindowOpen(startsAt: start, endsAt: end, now: DateTime.utc(2026, 11, 8, 19, 59)), isFalse);
    expect(liveWindowOpen(startsAt: start, endsAt: end, now: DateTime.utc(2026, 11, 8, 20)), isTrue);
    expect(liveWindowOpen(startsAt: start, endsAt: end, now: end), isTrue);
    expect(liveWindowOpen(startsAt: start, endsAt: end, now: end.add(const Duration(seconds: 1))), isFalse);
    expect(liveWindowOpen(startsAt: start, endsAt: end, now: now, cancelled: true), isFalse);
  });

  test('my summary: distance, moving time and climb from the shared trail', () {
    final t0 = DateTime.utc(2026, 11, 9, 0);
    // Four points 2 minutes apart, 0.001° of latitude (~111 m) each, climbing 10 m each
    final trail = [
      for (var i = 0; i < 4; i++)
        TrailPoint(
          lat: -6.7 + i * 0.001,
          lng: 106.9,
          altitudeM: 2000.0 + i * 10,
          recordedAt: t0.add(Duration(minutes: 2 * i)),
        ),
    ];
    final s = trailSummary(trail);
    expect(s.distanceM, closeTo(333.6, 0.5));
    expect(s.movingTimeMs, 6 * 60 * 1000);
    expect(s.elevationGainM, 30);
    // A 20-minute gap (a long rest) is not moving time
    final rest = [
      ...trail,
      TrailPoint(lat: -6.696, lng: 106.9, altitudeM: 2030, recordedAt: t0.add(const Duration(minutes: 26))),
    ];
    expect(trailSummary(rest).movingTimeMs, 6 * 60 * 1000);
    expect(trailSummary(const []).distanceM, 0);
  });

  test('the event form', () {
    final start = DateTime(2026, 11, 8, 5), end = DateTime(2026, 11, 9, 14);
    String? err({String title = 'Traverse', DateTime? s, DateTime? e, int? quota, bool editing = false}) =>
        eventInputError(
          title: title,
          startsAt: s ?? start,
          endsAt: e ?? end,
          quota: quota,
          editing: editing,
          now: DateTime(2026, 11, 2),
        );
    expect(err(), isNull);
    expect(err(title: 'A'), 'Give the event a title.');
    expect(err(e: start), 'The end must be after the start.');
    expect(err(e: start.add(const Duration(days: 31))), 'An event can last up to 30 days.');
    expect(err(s: DateTime(2026, 10, 30), e: DateTime(2026, 10, 31)), 'The start cannot be in the past.');
    expect(err(s: DateTime(2026, 10, 30), e: DateTime(2026, 10, 31), editing: true), isNull);
    expect(err(quota: 0), 'The quota is 1 to 500 people.');
    expect(eventInputError(title: 'Traverse', startsAt: null, endsAt: end, now: start), 'Set the start and the end.');
  });

  test('dates as the app shows them', () {
    expect(formatEventRange(DateTime(2026, 11, 8, 5), DateTime(2026, 11, 9, 14, 30)), '8 Nov 05:00 – 9 Nov 14:30');
    expect(formatEventRange(DateTime(2026, 11, 8, 5), DateTime(2026, 11, 8, 17)), '8 Nov 05:00 – 17:00');
    expect(formatUntil(DateTime(2026, 11, 8, 17), DateTime(2026, 11, 8, 9)), '17:00');
    expect(formatUntil(DateTime(2026, 11, 9, 17), DateTime(2026, 11, 8, 9)), '9 Nov 17:00');
  });
}
