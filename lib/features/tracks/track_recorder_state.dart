import 'dart:async';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/tracks/gps_source.dart';
import '../../data/tracks/track_cloud.dart';
import '../../data/tracks/track_local_store.dart';
import '../../domain/survey/survey_model.dart' show newUuid;
import '../../domain/tracks/recorded_track.dart';
import '../../domain/tracks/track_recorder_geo.dart';

// The Track Recorder (useTrackRecorderStore.ts + TrackRecorderService.ts on the web): every
// accepted GPS fix is stored on the phone first, online-mode tracks upload every 60 s while
// recording, when finished and when the signal returns. Recording needs Enterprise or admin
// (RLS checks it again); every signed-in account sees its own tracks and shared ones.

final trackLocalStoreProvider = Provider<TrackLocalStore>((ref) => SqliteTrackStore());

final trackCloudProvider = Provider<TrackCloud>((ref) => SupabaseTrackCloud(ref.watch(supabaseClientProvider)));

final gpsSourceProvider = Provider<GpsSource>((ref) => GeolocatorGpsSource());

final trackClockProvider = Provider<int Function()>(
  (ref) =>
      () => DateTime.now().millisecondsSinceEpoch,
);

/// How often an online-mode recording uploads (60 s, like the web)
final trackSyncIntervalProvider = Provider<Duration>((ref) => trackAutoSyncInterval);

/// Whether the phone has a network (navigator.onLine on the web)
final onlineProvider = StreamProvider<bool>((ref) async* {
  final c = Connectivity();
  bool on(List<ConnectivityResult> r) => r.any((x) => x != ConnectivityResult.none);
  try {
    yield on(await c.checkConnectivity());
  } on Object {
    yield true;
  }
  yield* c.onConnectivityChanged.map(on);
});

class TrackView {
  const TrackView(this.track, this.points);
  final RecordedTrack track;
  final List<TrackPoint> points;
}

class TrackRecorderState {
  const TrackRecorderState({
    this.userId,
    this.panelOpen = false,
    this.active,
    this.activePoints = const [],
    this.currentFix,
    this.gpsStatus = GpsStatus.idle,
    this.tracks = const [],
    this.loadingTracks = false,
    this.viewing,
    this.shared = const [],
    this.loadingShared = false,
    this.error,
  });

  final String? userId;
  final bool panelOpen;
  final RecordedTrack? active; // the recording (recording or paused)
  final List<TrackPoint> activePoints;
  final GpsFix? currentFix;
  final GpsStatus gpsStatus;
  final List<RecordedTrack> tracks; // mine: on the phone and in the cloud
  final bool loadingTracks;
  final TrackView? viewing; // a saved track shown on the map
  final List<SharedTrack> shared; // shared with me
  final bool loadingShared;
  final String? error;

  bool get recording => active?.status == TrackStatus.recording;

  TrackRecorderState copyWith({
    bool? panelOpen,
    RecordedTrack? Function()? active,
    List<TrackPoint>? activePoints,
    GpsFix? Function()? currentFix,
    GpsStatus? gpsStatus,
    List<RecordedTrack>? tracks,
    bool? loadingTracks,
    TrackView? Function()? viewing,
    List<SharedTrack>? shared,
    bool? loadingShared,
    String? Function()? error,
  }) => TrackRecorderState(
    userId: userId,
    panelOpen: panelOpen ?? this.panelOpen,
    active: active == null ? this.active : active(),
    activePoints: activePoints ?? this.activePoints,
    currentFix: currentFix == null ? this.currentFix : currentFix(),
    gpsStatus: gpsStatus ?? this.gpsStatus,
    tracks: tracks ?? this.tracks,
    loadingTracks: loadingTracks ?? this.loadingTracks,
    viewing: viewing == null ? this.viewing : viewing(),
    shared: shared ?? this.shared,
    loadingShared: loadingShared ?? this.loadingShared,
    error: error == null ? this.error : error(),
  );
}

final trackRecorderProvider = NotifierProvider<TrackRecorderController, TrackRecorderState>(
  TrackRecorderController.new,
);

class TrackRecorderController extends Notifier<TrackRecorderState> {
  StatsAccumulator _acc = const StatsAccumulator();
  int _segment = 0;
  Future<void> _writes = Future.value();
  StreamSubscription<GpsFix>? _gps;
  Timer? _autoSync;

  @override
  TrackRecorderState build() {
    ref.onDispose(_stopRecordingWork);
    ref.listen(authUserIdProvider, (_, next) {
      if (!next.hasValue) return;
      final id = next.value;
      // After build, so the first state is in place
      // After build (the first state is in place), and not once the provider is gone
      unawaited(
        Future(() {
          if (!ref.mounted) return;
          id == null ? reset() : unawaited(init(id));
        }),
      );
    }, fireImmediately: true);
    // Losing recording access (plan change) pauses the recording; nothing is deleted
    ref.listen(profileProvider, (_, next) {
      final p = next.value;
      if (p != null && !p.canRecordTracks && state.recording) unawaited(pause());
    });
    // Back online: refresh shared tracks and retry uploads of online-mode tracks
    ref.listen(onlineProvider, (prev, next) {
      if (next.value == true && prev?.value == false) unawaited(_backOnline());
    });
    return const TrackRecorderState();
  }

  TrackLocalStore get _local => ref.read(trackLocalStoreProvider);
  TrackCloud get _cloud => ref.read(trackCloudProvider);
  int _now() => ref.read(trackClockProvider)();
  bool get _online => ref.read(onlineProvider).value ?? true;
  bool get canRecord => ref.read(profileProvider).value?.canRecordTracks ?? false;

  /// Phone writes in order, even when fixes arrive quickly
  Future<T> _enqueue<T>(Future<T> Function() task) {
    final next = _writes.then((_) => task());
    _writes = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  void setPanelOpen(bool open) => state = state.copyWith(panelOpen: open);
  void clearError() => state = state.copyWith(error: () => null);

  Future<void> init(String userId) async {
    if (state.userId == userId) return;
    _stopRecordingWork();
    _acc = const StatsAccumulator();
    _segment = 0;
    state = TrackRecorderState(userId: userId);

    // A recording interrupted by the app closing comes back paused
    try {
      final unfinished = await _local.findUnfinishedTrack(userId);
      if (unfinished != null && state.userId == userId) {
        final points = await _local.getPoints(unfinished.id);
        _acc = accumulatePoints(points);
        final last = points.isEmpty ? null : points.last;
        final interruptedRun =
            unfinished.status == TrackStatus.recording && unfinished.lastResumedAt != null && last != null
            ? math.max(0, last.timestamp - unfinished.lastResumedAt!)
            : 0;
        final recovered = unfinished.copyWith(
          stats: _acc.stats,
          status: TrackStatus.paused,
          elapsedMs: unfinished.elapsedMs + interruptedRun,
          lastResumedAt: () => null,
          updatedAt: _now(),
        );
        _segment = last?.segment ?? 0;
        state = state.copyWith(active: () => recovered, activePoints: points, panelOpen: true);
        await _enqueue(() => _local.saveTrack(recovered));
      }
    } on Object catch (e) {
      state = state.copyWith(error: () => 'Could not read tracks on this phone: $e');
    }
    await Future.wait([loadTracks(), loadShared()]);
  }

  void reset() {
    _stopRecordingWork();
    _acc = const StatsAccumulator();
    _segment = 0;
    state = const TrackRecorderState();
  }

  /// The track goes into the state at once (and into the list); the phone write follows
  Future<void> _persist(RecordedTrack track) {
    final tracks = [track, ...state.tracks.where((t) => t.id != track.id)]
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    state = state.copyWith(active: state.active?.id == track.id ? () => track : null, tracks: tracks);
    return _enqueue(() => _local.saveTrack(track));
  }

  Future<void> start(String name, TrackMode mode) async {
    final userId = state.userId;
    if (userId == null || state.active != null) return;
    final now = _now();
    final track = RecordedTrack(
      id: newUuid(),
      userId: userId,
      name: name.trim().isEmpty ? defaultTrackName(DateTime.fromMillisecondsSinceEpoch(now)) : _cut(name.trim()),
      mode: mode,
      status: TrackStatus.recording,
      startedAt: now,
      lastResumedAt: now,
      syncStatus: mode == TrackMode.online ? TrackSyncStatus.pending : TrackSyncStatus.local,
      updatedAt: now,
    );
    _acc = const StatsAccumulator();
    _segment = 0;
    state = state.copyWith(active: () => track, activePoints: const [], viewing: () => null, error: () => null);
    final saved = _persist(track);
    _applyRecording();
    await saved;
  }

  Future<void> pause() async {
    final t = state.active;
    if (t == null || t.status != TrackStatus.recording) return;
    final now = _now();
    final saved = _persist(
      t.copyWith(
        status: TrackStatus.paused,
        elapsedMs: t.elapsedMs + (t.lastResumedAt == null ? 0 : now - t.lastResumedAt!),
        lastResumedAt: () => null,
        updatedAt: now,
      ),
    );
    _applyRecording();
    await saved;
  }

  Future<void> resume() async {
    final t = state.active;
    if (t == null || t.status != TrackStatus.paused) return;
    final now = _now();
    // A new segment, so the line and the distance do not bridge the pause
    if (state.activePoints.isNotEmpty) _segment++;
    final saved = _persist(t.copyWith(status: TrackStatus.recording, lastResumedAt: () => now, updatedAt: now));
    _applyRecording();
    await saved;
  }

  Future<void> stop() async {
    final t = state.active;
    if (t == null) return;
    final now = _now();
    final completed = t.copyWith(
      status: TrackStatus.completed,
      endedAt: () => now,
      elapsedMs: t.elapsedAt(now),
      lastResumedAt: () => null,
      updatedAt: now,
    );
    final saved = _persist(completed);
    state = state.copyWith(
      active: () => null,
      activePoints: const [],
      currentFix: () => null,
      gpsStatus: GpsStatus.idle,
    );
    _applyRecording();
    await saved;
    if (completed.mode == TrackMode.online) await sync(completed.id);
  }

  Future<void> discard() async {
    final t = state.active;
    if (t == null) return;
    state = state.copyWith(
      active: () => null,
      activePoints: const [],
      currentFix: () => null,
      gpsStatus: GpsStatus.idle,
      tracks: state.tracks.where((x) => x.id != t.id).toList(),
    );
    _applyRecording();
    await _enqueue(() => _local.deleteTrack(t.id));
    // An online recording may already have a partial cloud copy
    if (t.syncedAt != null) {
      try {
        await _cloud.delete(t.id);
      } on Object catch (e) {
        state = state.copyWith(
          error: () => 'Track discarded on this phone, but the cloud copy could not be removed: $e',
        );
      }
    }
  }

  void recordFix(GpsFix fix) {
    state = state.copyWith(currentFix: () => fix, gpsStatus: GpsStatus.ok);
    final t = state.active;
    if (t == null || t.status != TrackStatus.recording) return;

    final point = TrackPoint(
      lat: fix.lat,
      lng: fix.lng,
      alt: fix.alt,
      accuracy: fix.accuracy,
      speed: fix.speed,
      timestamp: fix.timestamp,
      segment: _segment,
    );
    if (shouldRejectPoint(_acc.lastPoint, point) != null) return;

    _acc = accumulatePoint(_acc, point);
    final seq = _acc.stats.pointCount - 1;
    final updated = t.copyWith(
      stats: _acc.stats,
      syncStatus: t.mode == TrackMode.online ? TrackSyncStatus.pending : t.syncStatus,
      updatedAt: point.timestamp,
    );
    state = state.copyWith(active: () => updated, activePoints: [...state.activePoints, point]);
    unawaited(
      _enqueue(() async {
        await _local.addPoint(updated.id, seq, point);
        // The latest state; skipped when the track was finished or discarded meanwhile
        final latest = state.active;
        if (latest?.id == updated.id) await _local.saveTrack(latest!);
      }).catchError((Object e) {
        state = state.copyWith(error: () => 'Could not save a GPS point on this phone: $e');
      }),
    );
  }

  Future<RecordedTrack?> _find(String id) async {
    if (state.active?.id == id) return state.active;
    try {
      final local = await _local.getTrack(id);
      if (local != null) return local;
    } on Object {
      // Fall back to the lists
    }
    for (final t in state.tracks) {
      if (t.id == id) return t;
    }
    for (final s in state.shared) {
      if (s.track.id == id) return s.track;
    }
    return null;
  }

  bool _own(RecordedTrack t) => t.userId == state.userId;

  Future<List<TrackPoint>> _points(RecordedTrack t) async {
    if (state.active?.id == t.id) return state.activePoints;
    return t.syncStatus == TrackSyncStatus.remote ? _cloud.fetchPoints(t.id) : _local.getPoints(t.id);
  }

  Future<void> sync(String id) async {
    final t = await _find(id);
    if (t == null || !_own(t) || t.syncStatus == TrackSyncStatus.remote) return;
    if (!_online) {
      await _persist(
        t.copyWith(syncStatus: t.syncStatus == TrackSyncStatus.local ? TrackSyncStatus.local : TrackSyncStatus.pending),
      );
      return;
    }
    final snapshotUpdatedAt = t.updatedAt;
    try {
      await _writes;
      final points = await _local.getPoints(t.id);
      await _cloud.upload(t, points);
      final latest = await _find(id) ?? t;
      // Points recorded during the upload still need another one
      final stillDirty = latest.updatedAt > snapshotUpdatedAt;
      await _persist(
        latest.copyWith(
          syncStatus: stillDirty ? TrackSyncStatus.pending : TrackSyncStatus.synced,
          syncError: () => null,
          syncedAt: () => _now(),
        ),
      );
    } on Object catch (e) {
      final latest = await _find(id) ?? t;
      await _persist(latest.copyWith(syncStatus: TrackSyncStatus.error, syncError: () => '$e'));
    }
  }

  /// Online-mode tracks waiting for an upload (offline-mode ones only go when asked)
  Future<void> syncPending() async {
    final pending = state.tracks.where(
      (t) =>
          t.id != state.active?.id &&
          t.mode == TrackMode.online &&
          (t.syncStatus == TrackSyncStatus.pending || t.syncStatus == TrackSyncStatus.error),
    );
    for (final t in pending.toList()) {
      await sync(t.id);
    }
  }

  Future<void> loadTracks() async {
    final userId = state.userId;
    if (userId == null) return;
    state = state.copyWith(loadingTracks: true);
    try {
      var merged = await _local.listTracks(userId);
      if (_online) {
        try {
          final remote = await _cloud.fetchTracks(userId);
          final localIds = {for (final t in merged) t.id};
          merged = [...merged, ...remote.where((t) => !localIds.contains(t.id))];
        } on Object catch (e) {
          state = state.copyWith(error: () => 'Could not load cloud tracks: $e');
        }
      }
      if (state.userId != userId) return;
      merged.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      state = state.copyWith(tracks: merged);
    } on Object catch (e) {
      state = state.copyWith(error: () => 'Could not read tracks on this phone: $e');
    } finally {
      if (state.userId == userId) state = state.copyWith(loadingTracks: false);
    }
  }

  Future<TrackView?> view(String id) async {
    final t = await _find(id);
    if (t == null) return null;
    try {
      final v = TrackView(t, await _points(t));
      state = state.copyWith(viewing: () => v);
      return v;
    } on Object catch (e) {
      state = state.copyWith(error: () => 'Could not load track: $e');
      return null;
    }
  }

  void closeView() => state = state.copyWith(viewing: () => null);

  Future<void> rename(String id, String name) async {
    final trimmed = _cut(name.trim());
    final t = await _find(id);
    if (t == null || !_own(t) || trimmed.isEmpty || trimmed == t.name) return;
    try {
      if (t.inCloud) await _cloud.rename(id, trimmed);
    } on Object catch (e) {
      state = state.copyWith(error: () => 'Could not rename the cloud copy: $e');
      return;
    }
    final renamed = t.copyWith(name: trimmed);
    if (t.syncStatus == TrackSyncStatus.remote) {
      state = state.copyWith(tracks: [for (final x in state.tracks) x.id == id ? renamed : x]);
    } else {
      await _persist(renamed);
    }
    final v = state.viewing;
    if (v != null && v.track.id == id) state = state.copyWith(viewing: () => TrackView(renamed, v.points));
  }

  Future<void> delete(String id) async {
    final t = await _find(id);
    if (t == null || !_own(t) || state.active?.id == id) return;
    // The cloud copy first, so a failed request never leaves an orphan behind
    if (t.inCloud) {
      try {
        await _cloud.delete(id);
      } on Object catch (e) {
        state = state.copyWith(error: () => 'Could not delete the cloud copy (are you online?): $e');
        return;
      }
    }
    if (t.syncStatus != TrackSyncStatus.remote) await _enqueue(() => _local.deleteTrack(id));
    state = state.copyWith(
      tracks: state.tracks.where((x) => x.id != id).toList(),
      viewing: state.viewing?.track.id == id ? () => null : null,
    );
  }

  /// (file name, GPX text)
  Future<(String, String)> exportGpx(String id) async {
    final t = await _find(id);
    if (t == null) throw StateError('Track not found');
    final points = await _points(t);
    return (gpxFileName(t.name), buildGpx(name: t.name, startedAt: t.startedAt, points: points));
  }

  Future<void> loadShared() async {
    final userId = state.userId;
    if (userId == null || !_online) return;
    state = state.copyWith(loadingShared: true);
    try {
      final shared = await _cloud.fetchSharedWithMe();
      if (state.userId == userId) state = state.copyWith(shared: shared);
    } on Object catch (e) {
      state = state.copyWith(error: () => 'Could not load shared tracks: $e');
    } finally {
      if (state.userId == userId) state = state.copyWith(loadingShared: false);
    }
  }

  /// A recipient takes a shared track off their own list
  Future<void> leaveShared(String id) async {
    final userId = state.userId;
    if (userId == null) return;
    try {
      await _cloud.revokeShare(id, userId);
      state = state.copyWith(
        shared: state.shared.where((s) => s.track.id != id).toList(),
        viewing: state.viewing?.track.id == id ? () => null : null,
      );
    } on Object catch (e) {
      state = state.copyWith(error: () => 'Could not remove the shared track: $e');
    }
  }

  Future<TrackShare> share(String id, String email) async {
    final t = await _find(id);
    if (t == null || !_own(t)) throw const TrackCloudException('You can only share your own tracks');
    if (!_online) throw const TrackCloudException('Connect to the internet to share a track');
    // Recipients read the cloud copy, so it must be there and current
    if (t.syncStatus != TrackSyncStatus.synced && t.syncStatus != TrackSyncStatus.remote) {
      await sync(id);
      final synced = await _find(id);
      if (synced?.syncedAt == null) {
        throw TrackCloudException(
          synced?.syncError != null ? 'Upload failed: ${synced!.syncError}' : 'Upload the track before sharing',
        );
      }
    }
    return _cloud.share(id, email.trim());
  }

  Future<List<TrackShare>> listShares(String id) => _cloud.listShares(id);

  Future<void> revokeShare(String id, String recipientId) => _cloud.revokeShare(id, recipientId);

  Future<void> _backOnline() async {
    if (state.userId == null) return;
    await loadShared();
    if (!canRecord) return;
    await syncPending();
    final a = state.active;
    if (a != null && a.mode == TrackMode.online) await sync(a.id);
  }

  // --- GPS and auto upload while recording (TrackRecorderService.ts) ---

  void _applyRecording() {
    final a = state.active;
    if (a == null || a.status != TrackStatus.recording) {
      _stopRecordingWork();
      return;
    }
    if (_gps == null) {
      state = state.copyWith(gpsStatus: GpsStatus.searching);
      _gps = ref.read(gpsSourceProvider).watch().listen(recordFix, onError: _onGpsError);
    }
    if (a.mode == TrackMode.online) {
      _autoSync ??= Timer.periodic(ref.read(trackSyncIntervalProvider), (_) {
        final now = state.active;
        if (_online && now != null && now.syncStatus != TrackSyncStatus.synced) unawaited(sync(now.id));
      });
    }
  }

  void _onGpsError(Object e) {
    if (e is GpsDeniedException) {
      state = state.copyWith(gpsStatus: GpsStatus.denied);
      unawaited(pause());
    } else if (e is GpsUnavailableException) {
      state = state.copyWith(gpsStatus: GpsStatus.unavailable);
    } else {
      // Timeout and the like: the phone is still looking for a fix
      state = state.copyWith(gpsStatus: GpsStatus.searching);
    }
  }

  void _stopRecordingWork() {
    unawaited(_gps?.cancel());
    _gps = null;
    _autoSync?.cancel();
    _autoSync = null;
  }

  static String _cut(String s) => s.length > 120 ? s.substring(0, 120) : s;
}
