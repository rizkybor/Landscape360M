import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers.dart';
import '../../data/sos/sos_backend.dart';
import '../../data/sos/sos_device.dart';
import '../../data/tracks/gps_source.dart';
import '../../domain/sos/sos.dart';
import '../../domain/sos/sos_outbox.dart';
import '../../domain/survey/survey_model.dart' show newUuid;
import '../tracks/track_recorder_state.dart' show gpsSourceProvider, onlineProvider, trackClockProvider;

// The S.O.S screen's work (SosScreen.tsx on the web), kept outside the screen so it goes on
// with the screen off or another app in front: a 5 s countdown, then the GPS, a report to
// the admin at the start, every 30 s and with each message, kept in an outbox on the phone
// until the server has it and sent again as soon as the signal is back. "I'm safe" sends
// the resolved status the same way.

const sosCountdownSeconds = 5;
const sosReportEvery = Duration(seconds: 30);

final sosBackendProvider = Provider<SosBackend>((ref) => SupabaseSosBackend(ref.watch(supabaseClientProvider)));

final sosDeviceProvider = Provider<SosDevice>((ref) => PhoneSosDevice());

final sosPrefsProvider = Provider<SharedPreferencesAsync>((ref) => SharedPreferencesAsync());

final sosReportIntervalProvider = Provider<Duration>((ref) => sosReportEvery);

/// One step of the countdown (a second; shorter in tests)
final sosCountdownTickProvider = Provider<Duration>((ref) => const Duration(seconds: 1));

class _PrefsStorage implements OutboxStorage {
  _PrefsStorage(this.prefs);
  final SharedPreferencesAsync prefs;

  @override
  Future<String?> read(String key) => prefs.getString(key);

  @override
  Future<void> write(String key, String value) => prefs.setString(key, value);
}

final sosOutboxProvider = Provider<SosOutbox>(
  (ref) => SosOutbox(storage: _PrefsStorage(ref.watch(sosPrefsProvider)), send: ref.watch(sosBackendProvider).report),
);

enum SosPhase { closed, countdown, active }

enum SosDelivery { idle, sending, sent, waiting, error }

class SosState {
  const SosState({
    this.phase = SosPhase.closed,
    this.countdown = sosCountdownSeconds,
    this.startedAt,
    this.fix,
    this.gpsError,
    this.battery,
    this.delivery = SosDelivery.idle,
    this.sentAt,
    this.deliveryError,
    this.sentMessage = '',
    this.siren = false,
    this.light = false,
  });

  final SosPhase phase;
  final int countdown;
  final int? startedAt; // ms, when the countdown ended
  final SosFix? fix;
  final String? gpsError;
  final int? battery;
  final SosDelivery delivery;
  final int? sentAt; // last report the server took
  final String? deliveryError;
  final String sentMessage;
  final bool siren;
  final bool light;

  SosState copyWith({
    SosPhase? phase,
    int? countdown,
    int? startedAt,
    SosFix? fix,
    String? Function()? gpsError,
    int? battery,
    SosDelivery? delivery,
    int? sentAt,
    String? Function()? deliveryError,
    String? sentMessage,
    bool? siren,
    bool? light,
  }) => SosState(
    phase: phase ?? this.phase,
    countdown: countdown ?? this.countdown,
    startedAt: startedAt ?? this.startedAt,
    fix: fix ?? this.fix,
    gpsError: gpsError == null ? this.gpsError : gpsError(),
    battery: battery ?? this.battery,
    delivery: delivery ?? this.delivery,
    sentAt: sentAt ?? this.sentAt,
    deliveryError: deliveryError == null ? this.deliveryError : deliveryError(),
    sentMessage: sentMessage ?? this.sentMessage,
    siren: siren ?? this.siren,
    light: light ?? this.light,
  );
}

final sosProvider = NotifierProvider<SosController, SosState>(SosController.new);

/// Errors that mean "no connection": the report waits in the outbox
bool isNetworkError(Object e) =>
    e is TimeoutException ||
    RegExp('socket|network|host lookup|connection|fetch|offline', caseSensitive: false).hasMatch('$e');

class SosController extends Notifier<SosState> {
  String _clientId = newUuid();
  Timer? _countdown;
  Timer? _reports;
  StreamSubscription<GpsFix>? _gps;

  @override
  SosState build() {
    ref.onDispose(_stopAll);
    // Reports not sent yet ("I'm safe" without signal, the app closed during S.O.S) go out
    // when the app opens or the connection comes back, even with the screen closed
    ref.listen(onlineProvider, (prev, next) {
      if (next.value != true || prev?.value == true) return;
      unawaited(flushPending());
      if (state.phase == SosPhase.active) unawaited(report());
    });
    ref.listen(authUserIdProvider, (_, next) {
      if (next.value != null) unawaited(Future(() => ref.mounted ? flushPending() : null));
    }, fireImmediately: true);
    return const SosState();
  }

  SosOutbox get _outbox => ref.read(sosOutboxProvider);
  SosDevice get _device => ref.read(sosDeviceProvider);
  int _now() => ref.read(trackClockProvider)();
  bool get _online => ref.read(onlineProvider).value ?? true;

  Future<void> flushPending() async {
    try {
      if ((await _outbox.pending()).isNotEmpty) await _outbox.flush();
    } on Object {
      // Still no connection: tried again later
    }
  }

  /// Opens the S.O.S screen: 5 s to cancel, the GPS starts at once
  Future<void> open() async {
    if (state.phase != SosPhase.closed) return;
    _clientId = newUuid();
    state = const SosState(phase: SosPhase.countdown);
    _countdown = Timer.periodic(ref.read(sosCountdownTickProvider), (_) {
      final left = state.countdown - 1;
      if (left > 0) {
        state = state.copyWith(countdown: left);
      } else {
        _countdown?.cancel();
        _countdown = null;
        unawaited(_activate());
      }
    });
    await _startGps();
    final battery = await _device.battery();
    if (battery != null && state.phase != SosPhase.closed) state = state.copyWith(battery: battery);
  }

  Future<void> _activate() async {
    state = state.copyWith(phase: SosPhase.active, countdown: 0, startedAt: _now());
    unawaited(_device.keepScreenOn(true));
    await report();
    _reports = Timer.periodic(ref.read(sosReportIntervalProvider), (_) async {
      final battery = await _device.battery();
      if (battery != null) state = state.copyWith(battery: battery);
      await report();
    });
  }

  Future<void> _startGps() async {
    final gps = ref.read(gpsSourceProvider);
    // No explanation first in an emergency: ask straight away
    var access = await gps.access();
    if (access == GpsAccess.denied) access = await gps.request();
    if (state.phase == SosPhase.closed) return;
    if (access != GpsAccess.allowed) {
      state = state.copyWith(
        gpsError: () => access == GpsAccess.servicesOff ? 'Location Services are off' : 'Location permission is off',
      );
      return;
    }
    state = state.copyWith(gpsError: () => null);
    _gps = gps.watch().listen(
      (f) => state = state.copyWith(
        gpsError: () => null,
        fix: SosFix(
          lat: f.lat,
          lng: f.lng,
          accuracy: f.accuracy,
          // GPS altitude when the phone has it, otherwise the last one
          elevation: f.alt ?? state.fix?.elevation,
          time: f.timestamp,
        ),
      ),
      onError: (Object e) => state = state.copyWith(
        gpsError: () => e is GpsDeniedException ? 'Location permission is off' : 'Searching for GPS…',
      ),
    );
  }

  /// Sends the latest position, battery and message (kept on the phone until it is sent)
  Future<void> report({SosStatus status = SosStatus.active, String? message}) async {
    final started = state.startedAt;
    if (started == null) return;
    final s = state;
    state = s.copyWith(
      delivery: !_online
          ? SosDelivery.waiting
          : s.delivery == SosDelivery.sent
          ? SosDelivery.sent
          : SosDelivery.sending,
    );
    try {
      final done = await _outbox.queue(
        SosReport(
          clientId: _clientId,
          startedAt: DateTime.fromMillisecondsSinceEpoch(started, isUtc: true).toIso8601String(),
          status: status,
          message: message ?? s.sentMessage,
          fix: s.fix,
          battery: s.battery,
        ),
      );
      state = done
          ? state.copyWith(delivery: SosDelivery.sent, sentAt: _now(), deliveryError: () => null)
          : state.copyWith(delivery: SosDelivery.waiting);
    } on Object catch (e) {
      state = !_online || isNetworkError(e)
          ? state.copyWith(delivery: SosDelivery.waiting)
          : state.copyWith(delivery: SosDelivery.error, deliveryError: () => '$e');
    }
  }

  Future<void> sendMessage(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    state = state.copyWith(sentMessage: t);
    await report(message: t);
  }

  Future<void> toggleSiren() async {
    final on = !state.siren;
    state = state.copyWith(siren: on);
    await _device.siren(on);
  }

  void setLight(bool on) => state = state.copyWith(light: on);

  /// Cancel during the countdown, or "I'm safe": the admin is told (later without signal)
  Future<void> close() async {
    final wasActive = state.phase == SosPhase.active && state.startedAt != null;
    final last = state;
    _stopAll();
    if (last.siren) unawaited(_device.siren(false));
    unawaited(_device.keepScreenOn(false));
    unawaited(_device.torch(false));
    state = const SosState();
    if (wasActive) {
      try {
        await _outbox.queue(
          SosReport(
            clientId: _clientId,
            startedAt: DateTime.fromMillisecondsSinceEpoch(last.startedAt!, isUtc: true).toIso8601String(),
            status: SosStatus.resolved,
            message: last.sentMessage,
            fix: last.fix,
            battery: last.battery,
          ),
        );
      } on Object {
        // Kept in the outbox; sent when the connection is back
      }
    }
  }

  void _stopAll() {
    _countdown?.cancel();
    _countdown = null;
    _reports?.cancel();
    _reports = null;
    unawaited(_gps?.cancel());
    _gps = null;
  }
}

// --- Emergency contacts (on this phone, per account) ------------------------------------------

final emergencyContactsProvider = AsyncNotifierProvider<EmergencyContacts, List<EmergencyContact>>(
  EmergencyContacts.new,
);

class EmergencyContacts extends AsyncNotifier<List<EmergencyContact>> {
  @override
  Future<List<EmergencyContact>> build() async {
    final userId = ref.watch(authUserIdProvider).value;
    if (userId == null) return const [];
    return decodeEmergencyContacts(await ref.read(sosPrefsProvider).getString(emergencyContactsKey(userId)));
  }

  Future<void> _save(List<EmergencyContact> list) async {
    final userId = ref.read(authUserIdProvider).value;
    state = AsyncData(list);
    if (userId == null) return;
    await ref.read(sosPrefsProvider).setString(emergencyContactsKey(userId), encodeEmergencyContacts(list));
  }

  /// Null when added, else the problem
  Future<String?> add(String name, String phone) async {
    final list = state.value ?? const [];
    final c = EmergencyContact(name: name.trim(), phone: phone.trim());
    final problem = emergencyContactError(c, list);
    if (problem != null) return problem;
    await _save([...list, c]);
    return null;
  }

  Future<void> remove(int index) async {
    final list = [...?state.value]..removeAt(index);
    await _save(list);
  }
}

// --- Admin: active alerts, checked every 30 s while the app is open --------------------------

class SosAlertsState {
  const SosAlertsState({this.active = const [], this.error});
  final List<SosAlert> active;
  final String? error;
}

final sosAlertsProvider = NotifierProvider<SosAlertsController, SosAlertsState>(SosAlertsController.new);

class SosAlertsController extends Notifier<SosAlertsState> {
  Timer? _poll;

  @override
  SosAlertsState build() {
    ref.onDispose(() => _poll?.cancel());
    ref.listen(profileProvider, (_, next) {
      final admin = next.value?.isAdmin ?? false;
      _poll?.cancel();
      _poll = null;
      if (!admin) {
        state = const SosAlertsState();
        return;
      }
      unawaited(Future(() => ref.mounted ? refresh() : null));
      _poll = Timer.periodic(sosReportEvery, (_) => unawaited(refresh()));
    }, fireImmediately: true);
    return const SosAlertsState();
  }

  Future<void> refresh() async {
    if (!(ref.read(profileProvider).value?.isAdmin ?? false)) return;
    try {
      state = SosAlertsState(active: await ref.read(sosBackendProvider).alerts(onlyActive: true));
    } on Object catch (e) {
      state = SosAlertsState(active: state.active, error: '$e');
    }
  }
}
