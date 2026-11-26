import 'dart:async';

import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/live/monitor.dart';

// Team Monitor's side of live tracking (docs/backend/live-tracking): a monitor joins the
// private channel 'tracking-room' to hear every member's position (the server lets only
// is_monitor() accounts in), asks everyone to report now on 'tracking-heartbeat', and reads
// the activities and logs of tracker_logs (RLS: monitors read every row).

enum MonitorConnection { off, connecting, connected, error }

/// Bytes of a photo at a public address (null when it cannot be read)
typedef PhotoFetch = Future<Uint8List?> Function(String url);

Future<Uint8List?> fetchPhotoBytes(String url) async {
  try {
    final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
    return r.statusCode == 200 ? r.bodyBytes : null;
  } on Object {
    return null;
  }
}

abstract interface class MonitorChannel {
  /// Joins the room: [onPacket] for every position heard, [onStatus] as the connection changes
  Future<void> join({
    required void Function(Map<String, dynamic> packet) onPacket,
    required void Function(MonitorConnection status) onStatus,
  });

  /// Asks everyone sharing (in the app) to send their position now
  Future<void> askNow();

  Future<void> leave();
}

class SupabaseMonitorChannel implements MonitorChannel {
  SupabaseMonitorChannel(this.client);

  final SupabaseClient client;
  RealtimeChannel? _room;

  static const _private = RealtimeChannelConfig(private: true, self: false);

  @override
  Future<void> join({
    required void Function(Map<String, dynamic> packet) onPacket,
    required void Function(MonitorConnection status) onStatus,
  }) async {
    if (_room != null) return;
    onStatus(MonitorConnection.connecting);
    final session = client.auth.currentSession;
    if (session != null) await client.realtime.setAuth(session.accessToken);
    final room = _room = client.channel('tracking-room', opts: _private)
      ..onBroadcast(event: 'location-update', callback: (payload) => onPacket(Map<String, dynamic>.from(payload)));
    room.subscribe((status, error) {
      switch (status) {
        case RealtimeSubscribeStatus.subscribed:
          onStatus(MonitorConnection.connected);
          // Presence, as the web does; errors here do not matter
          unawaited(() async {
            try {
              await room.track({
                'user_id': client.auth.currentUser?.id,
                'role': 'monitor360',
                'online_at': DateTime.now().toUtc().toIso8601String(),
              });
            } on Object {
              // Presence is a courtesy; positions arrive without it
            }
          }());
        case RealtimeSubscribeStatus.channelError:
        case RealtimeSubscribeStatus.timedOut:
          onStatus(MonitorConnection.error);
        case RealtimeSubscribeStatus.closed:
          onStatus(MonitorConnection.off);
      }
    });
  }

  @override
  Future<void> askNow() async {
    try {
      await client
          .channel('tracking-heartbeat', opts: _private)
          .httpSend(event: 'heartbeat-request', payload: const {}, timeout: const Duration(seconds: 10));
    } on Object {
      // Nobody is asked this time; positions still come every 3 s
    }
  }

  @override
  Future<void> leave() async {
    final room = _room;
    _room = null;
    if (room != null) await client.removeChannel(room);
  }
}

/// A member with logs lately (the filter of the tracking lists)
typedef MonitorMember = ({String userId, String name});

abstract interface class MonitorRepository {
  /// Activities (sessions), newest first; [userId] narrows to one member
  Future<List<ActivitySummary>> activities({String? userId, int limit = 20, int offset = 0});

  /// The points of one activity, oldest first
  Future<List<MonitorPacket>> activityPoints(ActivitySummary a);

  /// Single logged points, newest first
  Future<List<TrackerLog>> logs({String? userId, int limit = 20, int offset = 0});

  /// Members seen in the latest logs
  Future<List<MonitorMember>> members();

  Future<void> deleteLog(String id);

  /// The accounts behind these tracker ids (200 at most per call)
  Future<List<TrackerProfile>> trackerProfiles(List<String> trackerIds);
}

class SupabaseMonitorRepository implements MonitorRepository {
  SupabaseMonitorRepository(this.client);

  final SupabaseClient client;

  List<Map<String, dynamic>> _rows(Object? data) => [
    for (final r in (data is List ? data : const <Object?>[]))
      if (r is Map) Map<String, dynamic>.from(r),
  ];

  /// id → email of these accounts (monitors may read every profile)
  Future<Map<String, String>> _emails(Iterable<String> ids) async {
    final list = ids.toSet().toList();
    if (list.isEmpty) return const {};
    final rows = _rows(await client.from('profiles').select('id, email').inFilter('id', list));
    return {for (final r in rows) '${r['id']}': '${r['email'] ?? ''}'};
  }

  @override
  Future<List<ActivitySummary>> activities({String? userId, int limit = 20, int offset = 0}) async {
    final rows = _rows(
      await client.rpc(
        'get_tracker_activity_sessions',
        params: {'p_user_id': userId, 'p_limit': limit, 'p_offset': offset},
      ),
    );
    final emails = await _emails(rows.map((r) => '${r['user_id']}'));
    return [for (final r in rows) ActivitySummary.fromRow(r, email: emails['${r['user_id']}'])];
  }

  @override
  Future<List<MonitorPacket>> activityPoints(ActivitySummary a) async {
    final rows = _rows(
      await client
          .from('tracker_logs')
          .select('lat, lng, elevation, speed, battery, timestamp, user_id')
          .eq('session_id', a.sessionId)
          .eq('user_id', a.userId)
          .order('timestamp', ascending: true),
    );
    return [for (final r in rows) MonitorPacket.fromLog(r, trackerId: a.memberName.toUpperCase())];
  }

  @override
  Future<List<TrackerLog>> logs({String? userId, int limit = 20, int offset = 0}) async {
    var q = client.from('tracker_logs').select('id, user_id, lat, lng, elevation, speed, timestamp');
    if (userId != null) q = q.eq('user_id', userId);
    final rows = _rows(await q.order('timestamp', ascending: false).range(offset, offset + limit - 1));
    final emails = await _emails(rows.map((r) => '${r['user_id']}'));
    return [for (final r in rows) TrackerLog.fromRow(r, email: emails['${r['user_id']}'])];
  }

  @override
  Future<List<MonitorMember>> members() async {
    final rows = _rows(
      await client.from('tracker_logs').select('user_id').order('timestamp', ascending: false).limit(100),
    );
    final ids = <String>{for (final r in rows) '${r['user_id']}'}.toList();
    final emails = await _emails(ids);
    return [for (final id in ids) (userId: id, name: memberNameOf(emails[id], id))];
  }

  @override
  Future<void> deleteLog(String id) => client.from('tracker_logs').delete().eq('id', id);

  @override
  Future<List<TrackerProfile>> trackerProfiles(List<String> trackerIds) async {
    if (trackerIds.isEmpty) return const [];
    final rows = _rows(await client.rpc('monitor_tracker_profiles', params: {'p_trackers': trackerIds}));
    return rows.map(TrackerProfile.fromRow).toList();
  }
}
