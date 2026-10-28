import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers.dart';
import '../../data/map/map_services.dart';
import '../../domain/route/route_planner.dart';
import '../../domain/search/place_search.dart';
import '../../domain/weather/villages.dart';

// State of the map tools (weather, search, route planner) shared by the sheet and the map

final weatherServiceProvider = Provider<WeatherService>((ref) => WeatherService());

/// Villages for the weather's nearest-village lookup (loaded once, when first needed)
final villageIndexProvider = FutureProvider<VillageIndex>((ref) => loadVillageIndex());

final geocodingServiceProvider = Provider<GeocodingService>(
  (ref) => GeocodingService(token: ref.watch(appConfigProvider).mapboxPublicToken),
);

final directionsServiceProvider = Provider<DirectionsService>(
  (ref) => DirectionsService(token: ref.watch(appConfigProvider).mapboxPublicToken),
);

final poiRepositoryProvider = Provider<PoiRepository>((ref) {
  SupabaseClient? client;
  try {
    client = ref.watch(supabaseClientProvider);
  } on Object {
    client = null; // not initialised (tests)
  }
  return PoiRepository(client: client);
});

/// Published points of interest: the cached / bundled list at once, then the server's
class PoisController extends AsyncNotifier<List<PointOfInterest>> {
  @override
  Future<List<PointOfInterest>> build() async {
    final repo = ref.watch(poiRepositoryProvider);
    final first = await repo.cachedOrBundled();
    unawaited(
      repo.refresh().then((fresh) {
        if (fresh != null && ref.mounted) state = AsyncData(fresh);
      }),
    );
    return first;
  }
}

final poisProvider = AsyncNotifierProvider<PoisController, List<PointOfInterest>>(PoisController.new);

/// The weather card is shown on the map
class WeatherShown extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void hide() => state = false;
}

final weatherShownProvider = NotifierProvider<WeatherShown, bool>(WeatherShown.new);

typedef FlyTarget = ({double lng, double lat, double zoom});

/// A place the map should move to (a search result); the map clears it once there
class FlyTo extends Notifier<FlyTarget?> {
  @override
  FlyTarget? build() => null;

  void go(double lng, double lat, {double zoom = 16}) => state = (lng: lng, lat: lat, zoom: zoom);
  void done() => state = null;
}

final flyToProvider = NotifierProvider<FlyTo, FlyTarget?>(FlyTo.new);

class RoutePlannerState {
  const RoutePlannerState({
    this.enabled = false,
    this.mode = RouteMode.drivingToll,
    this.draft = const RouteDraft(),
    this.result,
    this.loading = false,
    this.error,
  });

  final bool enabled;
  final RouteMode mode;
  final RouteDraft draft;
  final RouteResult? result;
  final bool loading;
  final String? error;

  /// Which point the next tap sets: 'start', 'end', or null when both are set
  String? get nextStep => draft.start == null
      ? 'start'
      : draft.end == null
      ? 'end'
      : null;

  RoutePlannerState copyWith({
    bool? enabled,
    RouteMode? mode,
    RouteDraft? draft,
    RouteResult? Function()? result,
    bool? loading,
    String? Function()? error,
  }) => RoutePlannerState(
    enabled: enabled ?? this.enabled,
    mode: mode ?? this.mode,
    draft: draft ?? this.draft,
    result: result == null ? this.result : result(),
    loading: loading ?? this.loading,
    error: error == null ? this.error : error(),
  );
}

/// Route planner, same behaviour as useRouteStore on the web
class RoutePlanner extends Notifier<RoutePlannerState> {
  int _request = 0;

  @override
  RoutePlannerState build() => const RoutePlannerState();

  void enable() => state = state.copyWith(enabled: true);

  /// Closing clears the route (like the web)
  void disable() {
    _request++;
    state = RoutePlannerState(mode: state.mode);
  }

  void clear() {
    _request++;
    state = RoutePlannerState(enabled: state.enabled, mode: state.mode);
  }

  /// Tap on the map: start, then destination (route computed), then a new start
  Future<void> tap(RoutePoint p) async {
    if (!state.enabled) return;
    final next = state.draft.tap(p);
    state = state.copyWith(draft: next, result: () => null, error: () => null);
    if (next.complete) await compute();
  }

  void swap() {
    if (!state.draft.complete) return;
    state = state.copyWith(draft: state.draft.swapped(), result: () => null, error: () => null);
  }

  /// Picking another mode recomputes a complete route
  Future<void> setMode(RouteMode mode) async {
    state = state.copyWith(mode: mode);
    if (state.draft.complete) await compute();
  }

  Future<void> compute() async {
    final start = state.draft.start, end = state.draft.end;
    if (start == null || end == null) return;
    final id = ++_request;
    state = state.copyWith(loading: true, error: () => null);
    try {
      final r = await ref.read(directionsServiceProvider).route(mode: state.mode, start: start, end: end);
      if (id != _request) return;
      state = state.copyWith(result: () => r, loading: false);
    } on RouteException catch (e) {
      if (id != _request) return;
      state = state.copyWith(result: () => null, loading: false, error: () => e.message);
    } on Object {
      if (id != _request) return;
      state = state.copyWith(result: () => null, loading: false, error: () => 'Gagal mengambil rute.');
    }
  }
}

final routePlannerProvider = NotifierProvider<RoutePlanner, RoutePlannerState>(RoutePlanner.new);
