import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/marked/marked_location_repository.dart';
import '../../domain/marked/marked_locations.dart';
import '../../domain/util/js_compat.dart';

// Marked Locations (useMarkedLocationStore.ts): my saved places, the ones shared with me and
// (admin) every account's, the location open on the map, and picking a position on the map
// for the form. Saved in the cloud only, like the web.

final markedBackendProvider = Provider<MarkedLocationBackend>(
  (ref) => SupabaseMarkedLocationBackend(ref.watch(supabaseClientProvider)),
);

enum MarkedKind { mine, shared, other }

/// A location drawn on the map
class VisibleLocation {
  const VisibleLocation(this.location, this.kind, [this.owner]);
  final MarkedLocation location;
  final MarkedKind kind;
  final String? owner;
}

typedef PickedPoint = ({double lng, double lat, double? elevationM});

class MarkedState {
  const MarkedState({
    this.userId,
    this.mine = const [],
    this.shared = const [],
    this.all = const [],
    this.showAllOnMap = false,
    this.loading = false,
    this.error,
    this.selectedId,
    this.picking = false,
    this.picked,
  });

  final String? userId;
  final List<MarkedLocation> mine;
  final List<OwnedLocation> shared;
  final List<OwnedLocation> all; // admin
  final bool showAllOnMap; // admin: also draw every account's locations
  final bool loading;
  final String? error;
  final String? selectedId; // open on the map
  final bool picking; // the next map tap sets the form's position
  final PickedPoint? picked;

  /// Every location this account sees on the map, without duplicates (mine win)
  List<VisibleLocation> get visible {
    final byId = <String, VisibleLocation>{};
    if (showAllOnMap) {
      for (final o in all) {
        byId[o.location.id] = VisibleLocation(o.location, MarkedKind.other, o.owner);
      }
    }
    for (final o in shared) {
      byId[o.location.id] = VisibleLocation(o.location, MarkedKind.shared, o.owner);
    }
    for (final l in mine) {
      byId[l.id] = VisibleLocation(l, MarkedKind.mine);
    }
    return byId.values.toList();
  }

  VisibleLocation? get selected {
    for (final v in visible) {
      if (v.location.id == selectedId) return v;
    }
    return null;
  }

  MarkedState copyWith({
    List<MarkedLocation>? mine,
    List<OwnedLocation>? shared,
    List<OwnedLocation>? all,
    bool? showAllOnMap,
    bool? loading,
    String? Function()? error,
    String? Function()? selectedId,
    bool? picking,
    PickedPoint? Function()? picked,
  }) => MarkedState(
    userId: userId,
    mine: mine ?? this.mine,
    shared: shared ?? this.shared,
    all: all ?? this.all,
    showAllOnMap: showAllOnMap ?? this.showAllOnMap,
    loading: loading ?? this.loading,
    error: error == null ? this.error : error(),
    selectedId: selectedId == null ? this.selectedId : selectedId(),
    picking: picking ?? this.picking,
    picked: picked == null ? this.picked : picked(),
  );
}

final markedProvider = NotifierProvider<MarkedController, MarkedState>(MarkedController.new);

class MarkedController extends Notifier<MarkedState> {
  @override
  MarkedState build() {
    ref.listen(authUserIdProvider, (_, next) {
      if (!next.hasValue) return;
      final id = next.value;
      unawaited(Future(() => id == null ? reset() : init(id)));
    }, fireImmediately: true);
    return const MarkedState();
  }

  MarkedLocationBackend get _cloud => ref.read(markedBackendProvider);

  MarkedLocationPolicy get policy {
    final p = ref.read(profileProvider).value;
    return getMarkedLocationPolicy(
      hasUser: state.userId != null,
      subscriptionStatus: p?.plan.value ?? 'Free',
      isAdmin: p?.isAdmin ?? false,
    );
  }

  Future<void> init(String userId) async {
    if (state.userId == userId) return;
    state = MarkedState(userId: userId);
    await Future.wait([loadMine(), loadShared()]);
  }

  void reset() => state = const MarkedState();

  /// Runs a load and keeps its error; results for an account that signed out are dropped
  Future<void> _load(Future<MarkedState Function(MarkedState)> Function() task) async {
    final userId = state.userId;
    if (userId == null) return;
    state = state.copyWith(loading: true, error: () => null);
    try {
      final apply = await task();
      if (state.userId == userId) state = apply(state);
    } on Object catch (e) {
      if (state.userId == userId) state = state.copyWith(error: () => '$e');
    } finally {
      if (state.userId == userId) state = state.copyWith(loading: false);
    }
  }

  Future<void> loadMine() => _load(() async {
    final list = await _cloud.mine(state.userId!);
    return (MarkedState s) => s.copyWith(mine: list);
  });

  Future<void> loadShared() => _load(() async {
    final list = await _cloud.sharedWithMe();
    return (MarkedState s) => s.copyWith(shared: list);
  });

  Future<void> loadAll() => _load(() async {
    final list = await _cloud.all();
    return (MarkedState s) => s.copyWith(all: list);
  });

  void clearError() => state = state.copyWith(error: () => null);
  void setShowAllOnMap(bool show) {
    state = state.copyWith(showAllOnMap: show);
    if (show && state.all.isEmpty) unawaited(loadAll());
  }

  /// Tapping a marker opens it, tapping it again closes it
  void toggle(String id) => state = state.copyWith(selectedId: () => state.selectedId == id ? null : id);
  void select(String? id) => state = state.copyWith(selectedId: () => id);

  void startPicking() => state = state.copyWith(picking: true, selectedId: () => null, picked: () => null);
  void stopPicking() => state = state.copyWith(picking: false);
  void setPicked(PickedPoint? p) => state = state.copyWith(picked: () => p, picking: false);

  static List<OwnedLocation> _replace(List<OwnedLocation> list, MarkedLocation l) => [
    for (final o in list) o.location.id == l.id ? OwnedLocation(l, owner: o.owner) : o,
  ];

  Future<MarkedLocation> create(MarkedLocationInput input) async {
    final created = await _cloud.create(input);
    state = state.copyWith(mine: [created, ...state.mine], picked: () => null);
    return created;
  }

  Future<MarkedLocation> update(String id, MarkedLocationInput input) async {
    final updated = await _cloud.update(id, input);
    state = state.copyWith(
      mine: [for (final l in state.mine) l.id == id ? updated : l],
      all: _replace(state.all, updated),
      picked: () => null,
    );
    return updated;
  }

  Future<void> delete(String id) async {
    await _cloud.delete(id);
    state = state.copyWith(
      mine: state.mine.where((l) => l.id != id).toList(),
      all: state.all.where((o) => o.location.id != id).toList(),
      selectedId: state.selectedId == id ? () => null : null,
    );
  }

  /// A recipient takes a shared location off their own list
  Future<void> leaveShared(String id) async {
    final userId = state.userId;
    if (userId == null) return;
    await _cloud.removeShare(id, userId);
    state = state.copyWith(
      shared: state.shared.where((o) => o.location.id != id).toList(),
      selectedId: state.selectedId == id ? () => null : null,
    );
  }
}

/// Checks the form like the web; null when it can be saved
String? markedFormError({required String name, required String lat, required String lng, required String elevation}) {
  if (name.trim().isEmpty) return 'Name is required';
  final la = double.tryParse(lat.trim()), lo = double.tryParse(lng.trim());
  if (la == null || lo == null || !isValidCoordinate(lo, la)) {
    return 'Set a valid position: pick it on the map or enter latitude and longitude';
  }
  if (elevation.trim().isNotEmpty && double.tryParse(elevation.trim()) == null) return 'Elevation must be a number';
  return null;
}

/// 6 decimals, like the web's form (about 10 cm)
String roundCoord(double v) => jsNum((v * 1e6).round() / 1e6);
