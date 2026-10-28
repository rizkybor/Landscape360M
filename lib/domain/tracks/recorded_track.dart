import 'track_recorder_geo.dart';

// Port of the Track Recorder types (src/types/trackRecorder.ts): a recorded track, the
// tracks shared with me and the people I shared mine with.

/// online: kept on the phone and uploaded while recording and when finished.
/// offline: kept on the phone only; can be uploaded by hand later.
enum TrackMode { online, offline }

/// local: only on this phone. pending: changes still to upload. synced: the cloud copy is
/// current. error: the last upload failed (retried for online tracks). remote: only in the
/// cloud (recorded on another device).
enum TrackSyncStatus { local, pending, synced, error, remote }

enum GpsStatus { idle, searching, ok, denied, unavailable, error }

/// Online-mode tracks upload this often while recording
const trackAutoSyncInterval = Duration(seconds: 60);

T _enum<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.firstWhere((v) => v.name == name, orElse: () => fallback);

class RecordedTrack {
  const RecordedTrack({
    required this.id,
    required this.userId,
    required this.name,
    required this.mode,
    required this.status,
    required this.startedAt,
    this.endedAt,
    this.elapsedMs = 0,
    this.lastResumedAt,
    this.stats = const TrackStats(),
    required this.syncStatus,
    this.syncError,
    this.syncedAt,
    required this.updatedAt,
  });

  factory RecordedTrack.fromJson(Map<String, dynamic> j) => RecordedTrack(
    id: j['id'] as String,
    userId: j['userId'] as String,
    name: j['name'] as String,
    mode: _enum(TrackMode.values, j['mode'], TrackMode.offline),
    status: _enum(TrackStatus.values, j['status'], TrackStatus.completed),
    startedAt: (j['startedAt'] as num).toInt(),
    endedAt: (j['endedAt'] as num?)?.toInt(),
    elapsedMs: (j['elapsedMs'] as num? ?? 0).toInt(),
    lastResumedAt: (j['lastResumedAt'] as num?)?.toInt(),
    stats: TrackStats(
      distanceM: (j['distanceM'] as num? ?? 0).toDouble(),
      movingTimeMs: (j['movingTimeMs'] as num? ?? 0).toInt(),
      elevationGainM: (j['elevationGainM'] as num? ?? 0).toDouble(),
      elevationLossM: (j['elevationLossM'] as num? ?? 0).toDouble(),
      maxAltM: (j['maxAltM'] as num?)?.toDouble(),
      minAltM: (j['minAltM'] as num?)?.toDouble(),
      pointCount: (j['pointCount'] as num? ?? 0).toInt(),
    ),
    syncStatus: _enum(TrackSyncStatus.values, j['syncStatus'], TrackSyncStatus.local),
    syncError: j['syncError'] as String?,
    syncedAt: (j['syncedAt'] as num?)?.toInt(),
    updatedAt: (j['updatedAt'] as num).toInt(),
  );

  final String id;
  final String userId;
  final String name;
  final TrackMode mode;
  final TrackStatus status;
  final int startedAt; // epoch ms
  final int? endedAt;
  final int elapsedMs; // recording time before the current run
  final int? lastResumedAt; // start of the current run while recording
  final TrackStats stats;
  final TrackSyncStatus syncStatus;
  final String? syncError;
  final int? syncedAt;
  final int updatedAt;

  /// Whether a copy reached the cloud (renaming and deleting must go there too)
  bool get inCloud => syncStatus == TrackSyncStatus.remote || syncedAt != null;

  int elapsedAt(int now) => getElapsedMs(elapsedMs: elapsedMs, lastResumedAt: lastResumedAt, status: status, now: now);

  /// Average speed while moving, km/h
  double get avgSpeedKmh => stats.movingTimeMs > 0 ? stats.distanceM / (stats.movingTimeMs / 1000) * 3.6 : 0;

  RecordedTrack copyWith({
    String? name,
    TrackStatus? status,
    int? Function()? endedAt,
    int? elapsedMs,
    int? Function()? lastResumedAt,
    TrackStats? stats,
    TrackSyncStatus? syncStatus,
    String? Function()? syncError,
    int? Function()? syncedAt,
    int? updatedAt,
  }) => RecordedTrack(
    id: id,
    userId: userId,
    name: name ?? this.name,
    mode: mode,
    status: status ?? this.status,
    startedAt: startedAt,
    endedAt: endedAt == null ? this.endedAt : endedAt(),
    elapsedMs: elapsedMs ?? this.elapsedMs,
    lastResumedAt: lastResumedAt == null ? this.lastResumedAt : lastResumedAt(),
    stats: stats ?? this.stats,
    syncStatus: syncStatus ?? this.syncStatus,
    syncError: syncError == null ? this.syncError : syncError(),
    syncedAt: syncedAt == null ? this.syncedAt : syncedAt(),
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'userId': userId,
    'name': name,
    'mode': mode.name,
    'status': status.name,
    'startedAt': startedAt,
    'endedAt': endedAt,
    'elapsedMs': elapsedMs,
    'lastResumedAt': lastResumedAt,
    'distanceM': stats.distanceM,
    'movingTimeMs': stats.movingTimeMs,
    'elevationGainM': stats.elevationGainM,
    'elevationLossM': stats.elevationLossM,
    'maxAltM': stats.maxAltM,
    'minAltM': stats.minAltM,
    'pointCount': stats.pointCount,
    'syncStatus': syncStatus.name,
    'syncError': syncError,
    'syncedAt': syncedAt,
    'updatedAt': updatedAt,
  };
}

/// A track another account shared with me (view only)
class SharedTrack {
  const SharedTrack({required this.track, required this.ownerEmail, required this.sharedAt});

  final RecordedTrack track;
  final String? ownerEmail;
  final int sharedAt;
}

/// Someone I shared one of my tracks with
class TrackShare {
  const TrackShare({required this.userId, required this.email, required this.sharedAt});

  final String userId;
  final String email;
  final int sharedAt;
}

/// The cloud stores points as [lng, lat, alt, timestamp_ms, accuracy_m, segment]
List<Object?> toCompactPoint(TrackPoint p) => [p.lng, p.lat, p.alt, p.timestamp, p.accuracy, p.segment];

TrackPoint fromCompactPoint(List<dynamic> c) => TrackPoint(
  lng: (c[0] as num).toDouble(),
  lat: (c[1] as num).toDouble(),
  alt: (c[2] as num?)?.toDouble(),
  timestamp: (c[3] as num).toInt(),
  accuracy: (c[4] as num).toDouble(),
  segment: (c[5] as num).toInt(),
  speed: null,
);

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _two(int n) => n.toString().padLeft(2, '0');

/// "Track 28 Oct 2026 14:05" in the phone's time zone
String defaultTrackName(DateTime t) =>
    'Track ${_two(t.day)} ${_months[t.month - 1]} ${t.year} ${_two(t.hour)}:${_two(t.minute)}';

/// "28 Oct 2026 14:05" in the phone's time zone
String formatTrackDate(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${_two(t.day)} ${_months[t.month - 1]} ${t.year} ${_two(t.hour)}:${_two(t.minute)}';
}

/// GPX file name from the track name (exportGpx on the web)
String gpxFileName(String name) {
  final safe = name.replaceAll(RegExp(r'[^\w\- ]+'), '').trim().replaceAll(RegExp(r'\s+'), '_');
  return '${safe.isEmpty ? 'track' : safe}.gpx';
}
