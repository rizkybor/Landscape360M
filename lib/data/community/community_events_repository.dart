import 'dart:async';
import 'dart:convert';

import '../../domain/community/community_events.dart';
import '../../domain/sos/sos_outbox.dart' show OutboxStorage;
import 'community_repository.dart';

// Club events over the functions of 20261102000029_community_club_events.sql (the same backend
// as the rest of Community), and the phone's side of live sharing: the event being shared and
// the positions not yet sent, kept in storage so they survive no signal and app restarts.

List<Map<String, dynamic>> _rows(Object? data) => [
  for (final r in (data is List ? data : const <Object?>[]))
    if (r is Map) Map<String, dynamic>.from(r),
];

String? _opt(String v) => v.trim().isEmpty ? null : v.trim();

/// What the event form saves (save_community_event)
class EventInput {
  const EventInput({
    required this.title,
    this.description = '',
    required this.startsAt,
    required this.endsAt,
    this.meetingName = '',
    this.meetingLat,
    this.meetingLng,
    this.routeItemId,
    this.quota,
    this.needsApproval = false,
  });

  final String title;
  final String description;
  final DateTime startsAt;
  final DateTime endsAt;
  final String meetingName;
  final double? meetingLat;
  final double? meetingLng;
  final String? routeItemId;
  final int? quota;
  final bool needsApproval;
}

class CommunityEventsRepository {
  CommunityEventsRepository(this.backend);

  final CommunityBackend backend;

  /// The club's running and upcoming events (soonest first), or with [past] the ended and cancelled
  Future<List<EventSummary>> events(String clubId, {bool past = false}) async =>
      _rows(await backend.rpc('community_events', {'p_club_id': clubId, 'p_past': past}))
          .map(EventSummary.fromRow)
          .toList();

  /// Null when it is gone or not mine to see
  Future<CommunityEvent?> event(String id) async {
    final rows = _rows(await backend.rpc('community_event', {'p_id': id}));
    return rows.isEmpty ? null : CommunityEvent.fromRow(rows.first);
  }

  /// Creates ([id] null) or changes an event; returns its id
  Future<String> save(String clubId, String? id, EventInput e) async =>
      '${await backend.rpc('save_community_event', {'p_club_id': clubId, 'p_id': id, 'p_title': e.title.trim(), 'p_description': _opt(e.description), 'p_starts_at': e.startsAt.toUtc().toIso8601String(), 'p_ends_at': e.endsAt.toUtc().toIso8601String(), 'p_meeting_name': _opt(e.meetingName), 'p_meeting_lat': e.meetingLat, 'p_meeting_lng': e.meetingLng, 'p_route_item_id': e.routeItemId, 'p_quota': e.quota, 'p_needs_approval': e.needsApproval})}';

  Future<void> cancel(String id) => backend.rpc('cancel_community_event', {'p_id': id});

  Future<void> delete(String id) => backend.rpc('delete_community_event', {'p_id': id});

  /// Joins (or updates my emergency contact); returns going or pending
  Future<ParticipantStatus> join(String id, {String emergencyName = '', String emergencyPhone = ''}) async =>
      ParticipantStatus.parse(
        await backend.rpc('join_community_event', {
          'p_id': id,
          'p_emergency_name': _opt(emergencyName),
          'p_emergency_phone': _opt(emergencyPhone),
        }),
      ) ??
      ParticipantStatus.pending;

  Future<void> leave(String id) => backend.rpc('leave_community_event', {'p_id': id});

  /// An organiser lets someone in ([going]) or declines them
  Future<void> decide(String id, String userId, {required bool going}) => backend.rpc(
    'decide_community_event_participant',
    {'p_id': id, 'p_user_id': userId, 'p_status': going ? 'going' : 'declined'},
  );

  Future<List<EventParticipant>> participants(String id) async =>
      _rows(await backend.rpc('community_event_participants', {'p_id': id})).map(EventParticipant.fromRow).toList();

  Future<List<ChecklistItem>> checklist(String id) async =>
      _rows(await backend.rpc('community_event_checklist', {'p_id': id})).map(ChecklistItem.fromRow).toList();

  Future<String> addChecklistItem(String id, String label) async =>
      '${await backend.rpc('add_community_event_checklist_item', {'p_id': id, 'p_label': label.trim()})}';

  Future<void> deleteChecklistItem(String itemId) =>
      backend.rpc('delete_community_event_checklist_item', {'p_item_id': itemId});

  /// Ticks or unticks my item; returns whether it is ticked now
  Future<bool> toggleCheck(String itemId) async =>
      await backend.rpc('toggle_community_event_check', {'p_item_id': itemId}) == true;

  // --- Live

  Future<void> startLive(String id) => backend.rpc('start_community_live', {'p_id': id});

  Future<void> stopLive(String id) => backend.rpc('stop_community_live', {'p_id': id});

  /// Sends positions (at most 500); false when sharing must stop (stopped, declined,
  /// cancelled or ended)
  Future<bool> reportLive(String id, List<LivePoint> points) async =>
      await backend.rpc('report_community_live', {
        'p_id': id,
        'p_points': [for (final p in points) p.toJson()],
      }) ==
      true;

  Future<List<LivePosition>> liveLatest(String id) async =>
      _rows(await backend.rpc('community_live_latest', {'p_id': id})).map(LivePosition.fromRow).toList();

  Future<List<TrailPoint>> liveTrail(String id, String userId) async =>
      _rows(await backend.rpc('community_live_trail', {'p_id': id, 'p_user_id': userId}))
          .map(TrailPoint.fromRow)
          .toList();
}

// --- The phone's side of live sharing -------------------------------------------------------------

const liveSessionKey = 'l360-community-live';

/// The event I share my position for, as kept on the phone
class LiveSession {
  const LiveSession({
    required this.eventId,
    required this.userId,
    required this.title,
    required this.clubName,
    required this.endsAt,
    this.pending = const [],
    this.stopped = false,
  });

  factory LiveSession.fromJson(Map<String, dynamic> j) => LiveSession(
    eventId: '${j['eventId']}',
    userId: '${j['userId']}',
    title: '${j['title'] ?? ''}',
    clubName: '${j['clubName'] ?? ''}',
    endsAt: DateTime.tryParse('${j['endsAt']}') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    pending: [
      for (final p in (j['pending'] as List? ?? const []))
        if (p is Map) LivePoint.fromJson(Map<String, dynamic>.from(p)),
    ],
    stopped: j['stopped'] == true,
  );

  final String eventId;
  final String userId;
  final String title;
  final String clubName;
  final DateTime endsAt;
  final List<LivePoint> pending; // positions not yet sent, oldest first

  /// Sharing has stopped; only the last positions are left to send
  final bool stopped;

  LiveSession withPending(List<LivePoint> p) => LiveSession(
    eventId: eventId,
    userId: userId,
    title: title,
    clubName: clubName,
    endsAt: endsAt,
    pending: p,
    stopped: stopped,
  );

  LiveSession get asStopped => LiveSession(
    eventId: eventId,
    userId: userId,
    title: title,
    clubName: clubName,
    endsAt: endsAt,
    pending: pending,
    stopped: true,
  );

  Map<String, dynamic> toJson() => {
    'eventId': eventId,
    'userId': userId,
    'title': title,
    'clubName': clubName,
    'endsAt': endsAt.toUtc().toIso8601String(),
    'pending': [for (final p in pending) p.toJson()],
    'stopped': stopped,
  };
}

/// Positions to send, kept in storage: added as they are taken, removed once the server has
/// them. When sharing has stopped, the last ones still go out (a session with no GPS).
class LiveBuffer {
  LiveBuffer(this.storage);

  final OutboxStorage storage;

  /// Most kept on the phone (about 2 days at one per 2 minutes, more when moving)
  static const maxPending = 5000;

  Future<LiveSession?> read() async {
    try {
      final raw = await storage.read(liveSessionKey);
      if (raw == null || raw.isEmpty) return null;
      return LiveSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  Future<void> write(LiveSession? s) async {
    try {
      await storage.write(liveSessionKey, s == null ? '' : jsonEncode(s.toJson()));
    } on Object {
      // Not kept: positions still go out while the app runs
    }
  }

  /// Adds a position to the session's queue (the oldest go when the phone holds too many)
  Future<LiveSession?> add(LivePoint p) async {
    final s = await read();
    if (s == null) return null;
    final pending = [...s.pending, p];
    final next = s.withPending(pending.length > maxPending ? pending.sublist(pending.length - maxPending) : pending);
    await write(next);
    return next;
  }

  /// Sends what waits, batch by batch; returns false when the server says to stop sharing.
  /// Throws when a batch cannot be sent (the rest stays for later).
  Future<bool> flush(Future<bool> Function(String eventId, List<LivePoint> batch) send) async {
    var s = await read();
    if (s == null) return true;
    var keep = true;
    while (s != null && s.pending.isNotEmpty) {
      final batch = nextLiveBatch(s.pending);
      keep = await send(s.eventId, batch) && keep;
      // Positions added while this batch was out stay in line
      final now = await read();
      if (now == null || now.eventId != s.eventId) return keep;
      s = now.withPending(now.pending.skip(batch.length).toList());
      await write(s);
    }
    return keep;
  }
}
