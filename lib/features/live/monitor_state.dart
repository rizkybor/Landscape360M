import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/live/monitor_backend.dart';
import '../../domain/live/monitor.dart';
import '../tracks/track_recorder_state.dart' show onlineProvider, trackClockProvider;

// Team Monitor in the app (the web's useTrackerStore + TrackerService's monitor side): a
// monitor account (Enterprise monitor360, or the admin) switches it on from Tools > Monitor,
// joins tracking-room, hears every member sharing from the app, and keeps each one's last
// position and trail. The status of each marker is judged again every 5 s. A recalled
// activity (from the tracking lists) is drawn on the map until it is closed. It stops by
// itself on sign out or when the account may no longer monitor.

final monitorChannelProvider = Provider<MonitorChannel>(
  (ref) => SupabaseMonitorChannel(ref.watch(supabaseClientProvider)),
);

/// Reads a member's photo for the marker (tests serve it from memory)
final monitorPhotoFetchProvider = Provider<PhotoFetch>((ref) => fetchPhotoBytes);

final monitorRepositoryProvider = Provider<MonitorRepository>(
  (ref) => SupabaseMonitorRepository(ref.watch(supabaseClientProvider)),
);

class MonitorState {
  const MonitorState({
    this.on = false,
    this.connection = MonitorConnection.off,
    this.trackers = const {},
    this.selectedId,
    this.session,
    this.sessionVisible = true,
    this.profiles = const {},
    this.tick = 0,
    this.error,
  });

  final bool on;
  final MonitorConnection connection;
  final Map<String, MonitorTracker> trackers; // by tracker id
  final String? selectedId;

  /// A recalled activity drawn on the map
  final List<MonitorPacket>? session;
  final bool sessionVisible;

  /// The account behind each tracker id (null: none found, not allowed, or not set up yet)
  final Map<String, TrackerProfile?> profiles;

  /// Bumped every 5 s so the markers' status is judged again
  final int tick;
  final String? error;

  TrackerProfile? profileOf(String trackerId) => profiles[trackerId.toUpperCase()];

  MonitorTracker? get selected => selectedId == null ? null : trackers[selectedId];

  /// Members, the most recently heard first
  List<MonitorTracker> get members => trackers.values.toList()..sort((a, b) => b.heardAt.compareTo(a.heardAt));

  int online(int nowMs) => trackers.values.where((t) => t.status(nowMs) != MonitorStatus.offline).length;

  MonitorState copyWith({
    bool? on,
    MonitorConnection? connection,
    Map<String, MonitorTracker>? trackers,
    String? Function()? selectedId,
    List<MonitorPacket>? Function()? session,
    bool? sessionVisible,
    Map<String, TrackerProfile?>? profiles,
    int? tick,
    String? Function()? error,
  }) => MonitorState(
    on: on ?? this.on,
    connection: connection ?? this.connection,
    trackers: trackers ?? this.trackers,
    selectedId: selectedId == null ? this.selectedId : selectedId(),
    session: session == null ? this.session : session(),
    sessionVisible: sessionVisible ?? this.sessionVisible,
    profiles: profiles ?? this.profiles,
    tick: tick ?? this.tick,
    error: error == null ? this.error : error(),
  );
}

final monitorProvider = NotifierProvider<MonitorController, MonitorState>(MonitorController.new);

class MonitorController extends Notifier<MonitorState> {
  Timer? _tick;
  MonitorChannel? _channel; // read when monitoring starts, so Tools can watch this without a server
  String? _me;
  final _asked = <String>{}; // tracker ids whose profile was asked for (once per session)
  List<String> _pending = const []; // my own tracker id: my own positions are not shown (the web's echo guard)

  @override
  MonitorState build() {
    ref.onDispose(() {
      _tick?.cancel();
      // The channel joined (if any); ref cannot be used in onDispose
      final channel = _channel;
      if (channel != null) unawaited(channel.leave());
    });
    ref.listen(authUserIdProvider, (prev, next) {
      if (prev?.value != next.value && state.on) unawaited(stop());
    });
    ref.listen(profileProvider, (_, next) {
      final p = next.value;
      if (p != null && !p.canMonitor && state.on) unawaited(stop());
    });
    // Back online: ask everyone to report now
    ref.listen(onlineProvider, (prev, next) {
      if (state.on && next.value == true && prev?.value != true) unawaited(askNow());
    });
    return const MonitorState();
  }

  int get _now => ref.read(trackClockProvider)();

  /// Joins the room; false when the account may not monitor
  Future<bool> start() async {
    final p = ref.read(profileProvider).value;
    if (p == null || !p.canMonitor) return false;
    if (state.on) return true;
    _me = p.email.isEmpty ? null : p.email.split('@').first.toUpperCase();
    state = state.copyWith(on: true, connection: MonitorConnection.connecting, error: () => null);
    _tick?.cancel();
    _tick = Timer.periodic(monitorTickEvery, (_) {
      if (ref.mounted && state.on) state = state.copyWith(tick: state.tick + 1);
    });
    try {
      _channel ??= ref.read(monitorChannelProvider);
      await _channel!.join(onPacket: _heard, onStatus: _status);
    } on Object catch (e) {
      if (ref.mounted) state = state.copyWith(connection: MonitorConnection.error, error: () => '$e');
    }
    return true;
  }

  Future<void> stop() async {
    _tick?.cancel();
    _tick = null;
    await _channel?.leave();
    _asked.clear();
    _pending = const [];
    if (ref.mounted) {
      state = MonitorState(session: state.session, sessionVisible: state.sessionVisible);
    }
  }

  void _status(MonitorConnection c) {
    if (!ref.mounted || !state.on) return;
    final joined = c == MonitorConnection.connected && state.connection != MonitorConnection.connected;
    state = state.copyWith(
      connection: c,
      error: () => c == MonitorConnection.error ? 'Could not join the tracking room' : null,
    );
    // In the room: ask everyone sharing to report now (the web does the same)
    if (joined) unawaited(askNow());
  }

  void _heard(Map<String, dynamic> json) {
    if (!ref.mounted || !state.on) return;
    final p = MonitorPacket.fromJson(json);
    if (p == null || p.trackerId == _me) return;
    heard(p);
  }

  /// A position of a member (also from tests and the simulation)
  void heard(MonitorPacket p) {
    final now = _now;
    final current = state.trackers[p.trackerId];
    final next = current == null
        ? MonitorTracker(latest: p, trail: [(p.lng, p.lat)], heardAt: now)
        : current.update(p, now);
    state = state.copyWith(trackers: {...state.trackers, p.trackerId: next});
    if (current == null) _askProfile(p.trackerId);
  }

  /// The account behind a tracker heard for the first time: asked once, in one call for all
  /// those heard in the same moment
  void _askProfile(String trackerId) {
    final id = trackerId.toUpperCase();
    if (!_asked.add(id)) return;
    final first = _pending.isEmpty;
    _pending = [..._pending, id];
    if (first) scheduleMicrotask(() => unawaited(_loadProfiles()));
  }

  Future<void> _loadProfiles() async {
    final ids = _pending;
    _pending = const [];
    if (ids.isEmpty) return;
    final found = <String, TrackerProfile?>{for (final id in ids) id: null};
    try {
      final repo = ref.read(monitorRepositoryProvider);
      for (var i = 0; i < ids.length; i += 200) {
        final part = ids.sublist(i, i + 200 > ids.length ? ids.length : i + 200);
        for (final p in await repo.trackerProfiles(part)) {
          found[p.trackerId] = p;
        }
      }
    } on Object {
      // Not set up yet, not a monitor, or offline: the tracker ids are shown
    }
    if (ref.mounted) state = state.copyWith(profiles: {...state.profiles, ...found});
  }

  /// Taps a marker (again, or null, to close its card)
  void select(String? id) => state = state.copyWith(selectedId: () => id == null || id == state.selectedId ? null : id);

  Future<void> askNow() async => _channel?.askNow();

  /// A recalled activity on the map (the web's viewingSession)
  void showSession(List<MonitorPacket> points) => state = state.copyWith(session: () => points, sessionVisible: true);

  void toggleSessionVisible() => state = state.copyWith(sessionVisible: !state.sessionVisible);

  void closeSession() => state = state.copyWith(session: () => null);
}

/// Terrain height under the selected member (the map answers it; null while unknown)
class MonitorElevation extends Notifier<double?> {
  @override
  double? build() => null;

  void set(double? v) => state = v;
}

final monitorElevationProvider = NotifierProvider<MonitorElevation, double?>(MonitorElevation.new);
