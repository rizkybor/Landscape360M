import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/community/community_events_repository.dart';
import '../../data/community/community_repository.dart' show CommunityException;
import '../../data/tracks/gps_source.dart';
import '../../domain/community/community_events.dart';
import '../sos/sos_state.dart' show sosDeviceProvider;
import '../tracks/track_recorder_state.dart' show gpsSourceProvider, onlineProvider;
import 'community_state.dart';

// Live position sharing for a club event (opt-in, from this app only): while it is on, the phone
// keeps a position every 2 minutes or 50 m moved (the GPS of GPS Tracking, in the background
// with its notification on Android and the location mode on iOS, at a lighter setting), keeps
// them on the phone and sends them in batches every 2 minutes or as soon as the signal is back.
// It stops by itself when the server says so (stopped, declined, cancelled), when the event
// ends, or when the user stops it; one event at a time. Also the live map of an event: everyone's
// last position and one person's trail, reloaded every 30 seconds while it is open.

final communityEventsRepositoryProvider = Provider<CommunityEventsRepository>(
  (ref) => CommunityEventsRepository(ref.watch(communityBackendProvider)),
);

final liveBufferProvider = Provider<LiveBuffer>(
  (ref) => LiveBuffer(PrefsOutboxStorage(ref.watch(communityPrefsProvider))),
);

/// Battery in percent, or null (tests replace it)
final communityBatteryProvider = Provider<Future<int?> Function()>((ref) => ref.watch(sosDeviceProvider).battery);

class LiveShareState {
  const LiveShareState({
    this.eventId,
    this.title = '',
    this.clubName = '',
    this.endsAt,
    this.pending = 0,
    this.sentAt,
    this.gpsError,
    this.error,
    this.endedMessage,
  });

  final String? eventId; // the event I share for (null: not sharing)
  final String title;
  final String clubName;
  final DateTime? endsAt;
  final int pending; // positions on the phone not sent yet
  final DateTime? sentAt; // last batch the server took
  final String? gpsError;
  final String? error;

  /// Why sharing stopped by itself (shown once)
  final String? endedMessage;

  bool get on => eventId != null;

  LiveShareState copyWith({int? pending, DateTime? sentAt, String? Function()? gpsError, String? Function()? error}) =>
      LiveShareState(
        eventId: eventId,
        title: title,
        clubName: clubName,
        endsAt: endsAt,
        pending: pending ?? this.pending,
        sentAt: sentAt ?? this.sentAt,
        gpsError: gpsError == null ? this.gpsError : gpsError(),
        error: error == null ? this.error : error(),
      );
}

final communityLiveProvider = NotifierProvider<CommunityLiveController, LiveShareState>(CommunityLiveController.new);

class CommunityLiveController extends Notifier<LiveShareState> {
  StreamSubscription<GpsFix>? _gps;
  Timer? _batchTimer;
  Timer? _beatTimer;
  Timer? _endTimer;
  GpsFix? _lastFix;
  LivePoint? _lastKept;
  int? _battery;
  DateTime? _batteryAt;
  bool _flushing = false;
  String? _userId;

  @override
  LiveShareState build() {
    ref.onDispose(_release);
    ref.listen(authUserIdProvider, (_, next) {
      if (!next.hasValue) return;
      final id = next.value;
      unawaited(
        Future(() async {
          if (!ref.mounted) return;
          if (id != _userId) {
            _release();
            state = const LiveShareState();
          }
          _userId = id;
          if (id != null) await _restore(id);
        }),
      );
    }, fireImmediately: true);
    // The signal is back: send what waits
    ref.listen(onlineProvider, (prev, next) {
      if (next.value == true && prev?.value != true) unawaited(flush());
    });
    return const LiveShareState();
  }

  DateTime _now() => ref.read(communityClockProvider)();
  CommunityEventsRepository get _repo => ref.read(communityEventsRepositoryProvider);
  LiveBuffer get _buffer => ref.read(liveBufferProvider);

  /// After a restart: carries on sharing until the event ends, or sends the last positions
  Future<void> _restore(String userId) async {
    final s = await _buffer.read();
    if (s == null || s.userId != userId || !ref.mounted) return;
    if (!s.stopped && s.endsAt.isAfter(_now())) {
      _run(s);
    } else {
      // Stopped or ended while the app was closed: what is left still goes out
      await _buffer.write(s.asStopped);
      await flush();
    }
  }

  /// Turns sharing on for [e] (the server checks the window and that I am going); stops any
  /// other event first. Returns a problem to show, or null.
  Future<String?> start(CommunityEvent e) async {
    final userId = _userId ?? ref.read(authUserIdProvider).value;
    if (userId == null) return 'Sign in first';
    if (state.eventId == e.id) return null;
    if (state.on) await stop();
    final gps = ref.read(gpsSourceProvider);
    var access = await gps.access();
    if (access == GpsAccess.denied) access = await gps.request();
    if (access != GpsAccess.allowed) {
      return access == GpsAccess.servicesOff
          ? 'Turn on Location Services to share your position.'
          : 'Allow location for Landscape 360 to share your position.';
    }
    try {
      await _repo.startLive(e.id);
    } on CommunityException catch (err) {
      return err.message;
    }
    final session = LiveSession(eventId: e.id, userId: userId, title: e.title, clubName: e.clubName, endsAt: e.endsAt);
    await _buffer.write(session);
    _run(session);
    return null;
  }

  void _run(LiveSession s) {
    _release();
    _lastKept = s.pending.isEmpty ? null : s.pending.last;
    state = LiveShareState(
      eventId: s.eventId,
      title: s.title,
      clubName: s.clubName,
      endsAt: s.endsAt,
      pending: s.pending.length,
    );
    _gps = ref
        .read(gpsSourceProvider)
        .watchSparse()
        .listen(
          (f) => unawaited(_onFix(f)),
          onError: (Object e) => state = state.copyWith(
            gpsError: () => e is GpsDeniedException ? 'Location permission is off' : 'Searching for GPS…',
          ),
        );
    _batchTimer = Timer.periodic(liveBatchEvery, (_) => unawaited(flush()));
    _beatTimer = Timer.periodic(liveFixEvery, (_) => unawaited(_beat()));
    final left = s.endsAt.difference(_now());
    _endTimer = Timer(
      left.isNegative ? Duration.zero : left,
      () => unawaited(_end('The event has ended. Sharing stopped.')),
    );
    unawaited(flush());
  }

  Future<int?> _readBattery() async {
    final now = _now();
    if (_batteryAt != null && now.difference(_batteryAt!) < const Duration(minutes: 1)) return _battery;
    _batteryAt = now;
    try {
      _battery = await ref.read(communityBatteryProvider)() ?? _battery;
    } on Object {
      // The phone does not say
    }
    return _battery;
  }

  Future<void> _onFix(GpsFix f) async {
    if (!state.on) return;
    _lastFix = f;
    if (state.gpsError != null) state = state.copyWith(gpsError: () => null);
    final at = DateTime.fromMillisecondsSinceEpoch(f.timestamp, isUtc: true);
    if (!keepLiveFix(last: _lastKept, lat: f.lat, lng: f.lng, at: at)) return;
    await _keep(f, at);
  }

  /// Standing still (no new fix past the distance filter): the last position again every 2
  /// minutes, so the club sees the phone is still there
  Future<void> _beat() async {
    final f = _lastFix;
    final last = _lastKept;
    if (!state.on || f == null) return;
    final now = _now();
    if (last != null && now.difference(last.recordedAt) < liveFixEvery) return;
    await _keep(f, now.toUtc());
  }

  Future<void> _keep(GpsFix f, DateTime at) async {
    final p = LivePoint(
      lat: f.lat,
      lng: f.lng,
      accuracyM: f.accuracy,
      altitudeM: f.alt,
      speedMs: f.speed,
      battery: await _readBattery(),
      recordedAt: at,
    );
    _lastKept = p;
    final s = await _buffer.add(p);
    if (ref.mounted && state.on && s != null) state = state.copyWith(pending: s.pending.length);
  }

  /// Sends the positions on the phone; stops sharing when the server says so
  Future<void> flush() async {
    if (_flushing) return;
    if (ref.read(onlineProvider).value == false) return;
    _flushing = true;
    try {
      final keep = await _buffer.flush(_repo.reportLive);
      if (!ref.mounted) return;
      final left = (await _buffer.read())?.pending.length ?? 0;
      if (state.on) state = state.copyWith(pending: left, sentAt: _now(), error: () => null);
      if (!keep && state.on) {
        await _end('Sharing stopped: the organisers stopped it, the event was cancelled or has ended.');
      } else if (!state.on && left == 0 && ((await _buffer.read())?.stopped ?? false)) {
        // A stopped session with nothing left to send is done
        await _buffer.write(null);
      }
    } on CommunityException catch (e) {
      if (ref.mounted && state.on) state = state.copyWith(error: () => e.offline ? null : e.message);
    } on Object catch (e) {
      if (ref.mounted && state.on) state = state.copyWith(error: () => '$e');
    } finally {
      _flushing = false;
    }
  }

  /// Stopped by the server or the clock: no more positions; what is left still goes out
  Future<void> _end(String message) async {
    _release();
    final s = await _buffer.read();
    state = LiveShareState(endedMessage: message);
    if (s == null) return;
    if (s.pending.isEmpty) {
      await _buffer.write(null);
    } else {
      // The last positions were taken while sharing was on: they still count
      await _buffer.write(s.asStopped);
      unawaited(_sendRest());
    }
  }

  Future<void> _sendRest() async {
    try {
      await _buffer.flush(_repo.reportLive);
      await _buffer.write(null);
    } on Object {
      // Kept on the phone, sent at the next start of the app
    }
  }

  /// The user stops sharing: the positions taken so far are sent, then the server is told
  Future<void> stop() async {
    final eventId = state.eventId;
    _release();
    state = const LiveShareState();
    if (eventId == null) return;
    final kept = await _buffer.read();
    if (kept != null) await _buffer.write(kept.asStopped);
    try {
      await _buffer.flush(_repo.reportLive);
    } on Object {
      // No signal: those positions stay on the phone
    }
    try {
      await _repo.stopLive(eventId);
    } on Object {
      // The server also stops it at the end of the event
    }
    final s = await _buffer.read();
    if (s != null && s.pending.isEmpty) await _buffer.write(null);
  }

  void clearMessage() {
    if (state.endedMessage != null) state = const LiveShareState();
  }

  void _release() {
    unawaited(_gps?.cancel());
    _gps = null;
    for (final t in [_batchTimer, _beatTimer, _endTimer]) {
      t?.cancel();
    }
    _batchTimer = _beatTimer = _endTimer = null;
    _lastFix = null;
  }
}

// --- The live map of an event ------------------------------------------------------------------

class LiveViewState {
  const LiveViewState({
    required this.eventId,
    required this.title,
    this.positions = const [],
    this.trailUserId,
    this.trail = const [],
    this.error,
  });

  final String eventId;
  final String title;
  final List<LivePosition> positions;
  final String? trailUserId; // whose trail is drawn
  final List<TrailPoint> trail;
  final String? error;

  LiveViewState copyWith({
    List<LivePosition>? positions,
    String? Function()? trailUserId,
    List<TrailPoint>? trail,
    String? Function()? error,
  }) => LiveViewState(
    eventId: eventId,
    title: title,
    positions: positions ?? this.positions,
    trailUserId: trailUserId == null ? this.trailUserId : trailUserId(),
    trail: trail ?? this.trail,
    error: error == null ? this.error : error(),
  );
}

final communityLiveViewProvider = NotifierProvider<CommunityLiveView, LiveViewState?>(CommunityLiveView.new);

/// The event shown on the map with everyone's last position (null: none)
class CommunityLiveView extends Notifier<LiveViewState?> {
  Timer? _timer;

  @override
  LiveViewState? build() {
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  CommunityEventsRepository get _repo => ref.read(communityEventsRepositoryProvider);

  Future<void> open(String eventId, String title) async {
    _timer?.cancel();
    state = LiveViewState(eventId: eventId, title: title);
    _timer = Timer.periodic(liveRefreshEvery, (_) => unawaited(refresh()));
    await refresh();
  }

  void close() {
    _timer?.cancel();
    _timer = null;
    state = null;
  }

  Future<void> refresh() async {
    final s = state;
    if (s == null) return;
    try {
      final positions = await _repo.liveLatest(s.eventId);
      final who = s.trailUserId;
      final trail = who == null ? s.trail : await _repo.liveTrail(s.eventId, who);
      if (state?.eventId != s.eventId) return;
      state = state!.copyWith(positions: positions, trail: trail, error: () => null);
    } on Object catch (e) {
      if (state?.eventId == s.eventId) state = state!.copyWith(error: () => '$e');
    }
  }

  /// Draws one person's trail (again to hide it)
  Future<void> showTrail(String? userId) async {
    final s = state;
    if (s == null) return;
    if (userId == null || userId == s.trailUserId) {
      state = s.copyWith(trailUserId: () => null, trail: const []);
      return;
    }
    state = s.copyWith(trailUserId: () => userId, trail: const []);
    try {
      final trail = await _repo.liveTrail(s.eventId, userId);
      if (state?.trailUserId == userId) state = state!.copyWith(trail: trail);
    } on Object catch (e) {
      if (state?.eventId == s.eventId) state = state!.copyWith(error: () => '$e');
    }
  }
}
