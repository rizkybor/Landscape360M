import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/live/live_channel.dart';
import '../../data/tracks/gps_source.dart';
import '../../domain/live/live_packet.dart';
import '../sos/sos_state.dart' show isNetworkError, sosDeviceProvider;
import '../tracks/track_recorder_state.dart' show gpsSourceProvider, onlineProvider, trackClockProvider;

// GPS Tracking (Team Monitor's other side, TrackerService.ts on the web): a member on Pro or
// Enterprise shares their position with the monitors while it is on, also with the screen
// off (the same background GPS as the Track Recorder). A position goes out at most every
// 3 s, at once when a monitor asks, and again when the signal comes back. It stops by
// itself on sign out or when the account may no longer share.

final liveChannelProvider = Provider<LiveChannel>((ref) => SupabaseLiveChannel(ref.watch(supabaseClientProvider)));

/// Waiting time after the server refused, before trying again
final liveRetryAfterRefusalProvider = Provider<Duration>((ref) => const Duration(seconds: 30));

enum LiveStatus { off, starting, live, waiting, refused }

class LiveTrackingState {
  const LiveTrackingState({this.status = LiveStatus.off, this.sentAt, this.gpsError, this.error});

  final LiveStatus status;
  final int? sentAt; // last position the server took
  final String? gpsError;
  final String? error;

  bool get on => status != LiveStatus.off;
}

final liveTrackingProvider = NotifierProvider<LiveTrackingController, LiveTrackingState>(LiveTrackingController.new);

class LiveTrackingController extends Notifier<LiveTrackingState> {
  StreamSubscription<GpsFix>? _gps;
  LiveChannel? _channel; // while sharing
  LivePacket? _latest;
  int _lastSend = 0;
  int _refusedAt = 0;
  bool _sending = false;
  int? _battery;
  int _batteryAt = 0;

  @override
  LiveTrackingState build() {
    ref.onDispose(_release);
    ref.listen(profileProvider, (_, next) {
      if (!state.on || next.isLoading) return;
      if (next.value?.canBroadcast != true) unawaited(stop());
    });
    ref.listen(onlineProvider, (prev, next) {
      if (next.value == true && prev?.value != true && state.on) unawaited(_sendLatest(force: true));
    });
    return const LiveTrackingState();
  }

  int _now() => ref.read(trackClockProvider)();

  /// Starts sharing; false when the account may not share or the GPS is off
  Future<bool> start() async {
    if (state.on) return true;
    final profile = ref.read(profileProvider).value;
    if (profile == null || !profile.canBroadcast) return false;
    final gps = ref.read(gpsSourceProvider);
    var access = await gps.access();
    if (access == GpsAccess.denied) access = await gps.request();
    if (access != GpsAccess.allowed) {
      state = LiveTrackingState(
        gpsError: access == GpsAccess.servicesOff ? 'Location Services are off' : 'Location permission is off',
      );
      return false;
    }
    final trackerId = liveTrackerId(email: profile.email, userId: profile.userId);
    state = const LiveTrackingState(status: LiveStatus.starting);
    _lastSend = 0;
    _refusedAt = 0;
    final channel = ref.read(liveChannelProvider);
    _channel = channel;
    channel.listen(() => unawaited(_sendLatest(force: true)));
    _gps = gps.watch().listen(
      (f) {
        _latest = LivePacket(
          trackerId: trackerId,
          lat: f.lat,
          lng: f.lng,
          alt: f.alt,
          speed: f.speed,
          battery: _battery,
          time: f.timestamp,
        );
        if (state.gpsError != null) state = LiveTrackingState(status: state.status, sentAt: state.sentAt);
        unawaited(_sendLatest());
      },
      onError: (Object e) => state = LiveTrackingState(
        status: state.status,
        sentAt: state.sentAt,
        error: state.error,
        gpsError: e is GpsDeniedException ? 'Location permission is off' : 'Searching for GPS…',
      ),
    );
    return true;
  }

  Future<void> _sendLatest({bool force = false}) async {
    final packet = _latest;
    final channel = _channel;
    if (packet == null || channel == null || _sending || !state.on) return;
    final now = _now();
    if (!force && now - _lastSend < liveSendEvery.inMilliseconds) return;
    if (state.status == LiveStatus.refused &&
        now - _refusedAt < ref.read(liveRetryAfterRefusalProvider).inMilliseconds) {
      return;
    }
    _sending = true;
    _lastSend = now;
    try {
      await _refreshBattery(now);
      final withBattery = LivePacket(
        trackerId: packet.trackerId,
        lat: packet.lat,
        lng: packet.lng,
        alt: packet.alt,
        speed: packet.speed,
        battery: _battery,
        time: packet.time,
      );
      await channel.send(withBattery.toJson());
      if (state.on) state = LiveTrackingState(status: LiveStatus.live, sentAt: _now(), gpsError: state.gpsError);
    } on LiveNotAllowedException catch (e) {
      _refusedAt = _now();
      if (state.on) {
        state = LiveTrackingState(
          status: LiveStatus.refused,
          sentAt: state.sentAt,
          gpsError: state.gpsError,
          error: 'The server did not accept the position ($e). Live tracking may not be set up on the server yet.',
        );
      }
    } on Object catch (e) {
      final offline = ref.read(onlineProvider).value == false || isNetworkError(e);
      if (state.on) {
        state = LiveTrackingState(
          status: LiveStatus.waiting,
          sentAt: state.sentAt,
          gpsError: state.gpsError,
          error: offline ? null : '$e',
        );
      }
    } finally {
      _sending = false;
    }
  }

  // The battery level once a minute
  Future<void> _refreshBattery(int now) async {
    if (_battery != null && now - _batteryAt < 60000) return;
    _batteryAt = now;
    _battery = await ref.read(sosDeviceProvider).battery() ?? _battery;
  }

  Future<void> stop() async {
    _release();
    state = const LiveTrackingState();
  }

  void _release() {
    unawaited(_gps?.cancel());
    _gps = null;
    _latest = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) unawaited(channel.close());
  }
}
