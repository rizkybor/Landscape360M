import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/tracks/recorded_track.dart';
import '../../domain/tracks/track_recorder_geo.dart';

// Cloud copy of recorded tracks (src/services/trackRecorderSync.ts on the web): table
// recorded_tracks, one row per track with its points in one column, so uploading the whole
// track again is safe after a lost connection. Sharing goes through the server functions
// share_recorded_track / list_recorded_track_shares / list_tracks_shared_with_me, so the
// list of accounts never reaches the phone. RLS checks the plan and the owner again.

class TrackCloudException implements Exception {
  const TrackCloudException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The cloud calls the Track Recorder needs; tests use a fake
abstract interface class TrackCloud {
  Future<void> upload(RecordedTrack track, List<TrackPoint> points);
  Future<List<RecordedTrack>> fetchTracks(String userId);
  Future<List<TrackPoint>> fetchPoints(String trackId);
  Future<void> rename(String trackId, String name);
  Future<void> delete(String trackId);
  Future<TrackShare> share(String trackId, String email);
  Future<List<TrackShare>> listShares(String trackId);
  Future<void> revokeShare(String trackId, String recipientId);
  Future<List<SharedTrack>> fetchSharedWithMe();
}

const _metadataColumns =
    'id, user_id, name, mode, status, started_at, ended_at, elapsed_ms, distance_m, moving_time_ms, '
    'elevation_gain_m, elevation_loss_m, max_alt_m, min_alt_m, point_count, updated_at';

String _iso(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();
int _ms(Object? iso) => DateTime.parse('$iso').millisecondsSinceEpoch;

Map<String, dynamic> trackToRow(RecordedTrack t) => {
  'id': t.id,
  'user_id': t.userId,
  'name': t.name,
  'mode': t.mode.name,
  'status': t.status.name,
  'started_at': _iso(t.startedAt),
  'ended_at': t.endedAt == null ? null : _iso(t.endedAt!),
  'elapsed_ms': t.elapsedMs,
  'distance_m': t.stats.distanceM,
  'moving_time_ms': t.stats.movingTimeMs,
  'elevation_gain_m': t.stats.elevationGainM,
  'elevation_loss_m': t.stats.elevationLossM,
  'max_alt_m': t.stats.maxAltM,
  'min_alt_m': t.stats.minAltM,
  'point_count': t.stats.pointCount,
  'updated_at': _iso(t.updatedAt),
};

RecordedTrack trackFromRow(Map<String, dynamic> r) {
  final updated = _ms(r['updated_at']);
  return RecordedTrack(
    id: '${r['id']}',
    userId: '${r['user_id']}',
    name: '${r['name']}',
    mode: r['mode'] == 'online' ? TrackMode.online : TrackMode.offline,
    status: TrackStatus.values.firstWhere((s) => s.name == r['status'], orElse: () => TrackStatus.completed),
    startedAt: _ms(r['started_at']),
    endedAt: r['ended_at'] == null ? null : _ms(r['ended_at']),
    elapsedMs: (r['elapsed_ms'] as num? ?? 0).toInt(),
    stats: TrackStats(
      distanceM: (r['distance_m'] as num? ?? 0).toDouble(),
      movingTimeMs: (r['moving_time_ms'] as num? ?? 0).toInt(),
      elevationGainM: (r['elevation_gain_m'] as num? ?? 0).toDouble(),
      elevationLossM: (r['elevation_loss_m'] as num? ?? 0).toDouble(),
      maxAltM: (r['max_alt_m'] as num?)?.toDouble(),
      minAltM: (r['min_alt_m'] as num?)?.toDouble(),
      pointCount: (r['point_count'] as num? ?? 0).toInt(),
    ),
    syncStatus: TrackSyncStatus.remote,
    syncedAt: updated,
    updatedAt: updated,
  );
}

TrackShare _share(Map<String, dynamic> r) =>
    TrackShare(userId: '${r['shared_with']}', email: '${r['email']}', sharedAt: _ms(r['created_at']));

class SupabaseTrackCloud implements TrackCloud {
  SupabaseTrackCloud(this.client);

  final SupabaseClient client;

  /// Server errors as short messages; a full cloud storage gets a friendly one
  Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on PostgrestException catch (e) {
      // enforce_storage_quota_tracks raises with HINT 'storage_quota' (20261024000004)
      if (e.hint == 'storage_quota') {
        throw const TrackCloudException('Your cloud storage is full. The track stays on this phone.');
      }
      throw TrackCloudException(e.message);
    }
  }

  @override
  Future<void> upload(RecordedTrack track, List<TrackPoint> points) => _call(
    () => client.from('recorded_tracks').upsert({
      ...trackToRow(track),
      'points': [for (final p in points) toCompactPoint(p)],
    }, onConflict: 'id'),
  );

  @override
  Future<List<RecordedTrack>> fetchTracks(String userId) => _call(() async {
    final rows = await client
        .from('recorded_tracks')
        .select(_metadataColumns)
        .eq('user_id', userId)
        .order('started_at', ascending: false);
    return rows.map(trackFromRow).toList();
  });

  @override
  Future<List<TrackPoint>> fetchPoints(String trackId) => _call(() async {
    final row = await client.from('recorded_tracks').select('points').eq('id', trackId).maybeSingle();
    return [for (final c in (row?['points'] as List? ?? const [])) fromCompactPoint(c as List)];
  });

  // Name only (rename_recorded_track), so Pro accounts can rename without changing the points
  @override
  Future<void> rename(String trackId, String name) =>
      _call(() => client.rpc<void>('rename_recorded_track', params: {'p_track_id': trackId, 'p_name': name}));

  @override
  Future<void> delete(String trackId) => _call(() => client.from('recorded_tracks').delete().eq('id', trackId));

  @override
  Future<TrackShare> share(String trackId, String email) => _call(() async {
    final rows = await client.rpc<List<dynamic>>(
      'share_recorded_track',
      params: {'p_track_id': trackId, 'p_email': email},
    );
    if (rows.isEmpty) throw const TrackCloudException('Share failed');
    return _share(Map<String, dynamic>.from(rows.first as Map));
  });

  @override
  Future<List<TrackShare>> listShares(String trackId) => _call(() async {
    final rows = await client.rpc<List<dynamic>>('list_recorded_track_shares', params: {'p_track_id': trackId});
    return [for (final r in rows) _share(Map<String, dynamic>.from(r as Map))];
  });

  @override
  Future<void> revokeShare(String trackId, String recipientId) =>
      _call(() => client.from('recorded_track_shares').delete().eq('track_id', trackId).eq('shared_with', recipientId));

  @override
  Future<List<SharedTrack>> fetchSharedWithMe() => _call(() async {
    final rows = await client.rpc<List<dynamic>>('list_tracks_shared_with_me');
    return [
      for (final r in rows.cast<Map<dynamic, dynamic>>())
        SharedTrack(
          track: trackFromRow(Map<String, dynamic>.from(r)),
          ownerEmail: r['owner_email'] as String?,
          sharedAt: _ms(r['shared_at']),
        ),
    ];
  });
}
