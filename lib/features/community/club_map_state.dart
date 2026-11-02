import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/community/club_map_repository.dart';
import '../../data/community/community_repository.dart' show CommunityException;
import '../../data/geo/elevation_sampler.dart';
import '../../domain/community/club_map.dart';
import '../../domain/community/community.dart';
import '../../domain/geo/spherical.dart';
import '../../domain/map/map_settings.dart' show MapView;
import '../map/map_settings_controller.dart';
import '../map/map_tools_state.dart';
import 'community_state.dart';

// The club map in the app: the drawings and saved views of the club whose Map tab was opened
// (shown on the map until closed, read again every 30 seconds while shown), drawing one
// point by point on the map, and flying to a saved view.

final clubMapRepositoryProvider = Provider<ClubMapRepository>(
  (ref) => ClubMapRepository(ref.watch(communityBackendProvider)),
);

final elevationSamplerProvider = Provider<ElevationSampler>((ref) => TerrariumSampler());

/// Not real time, like the web
const clubMapRefreshEvery = Duration(seconds: 30);

class ClubMapState {
  const ClubMapState({
    this.club,
    this.annotations = const [],
    this.views = const [],
    this.selectedId,
    this.loading = false,
    this.error,
  });

  /// The club whose drawings are on the map (null: none)
  final CommunityClub? club;
  final List<Annotation> annotations;
  final List<SavedView> views;
  final String? selectedId;
  final bool loading;
  final String? error;

  bool get shown => club != null;
  Annotation? get selected => annotations.where((a) => a.id == selectedId).firstOrNull;

  ClubMapState copyWith({
    List<Annotation>? annotations,
    List<SavedView>? views,
    String? Function()? selectedId,
    bool? loading,
    String? Function()? error,
  }) => ClubMapState(
    club: club,
    annotations: annotations ?? this.annotations,
    views: views ?? this.views,
    selectedId: selectedId == null ? this.selectedId : selectedId(),
    loading: loading ?? this.loading,
    error: error == null ? this.error : error(),
  );
}

final clubMapProvider = NotifierProvider<ClubMapController, ClubMapState>(ClubMapController.new);

class ClubMapController extends Notifier<ClubMapState> {
  Timer? _timer;

  @override
  ClubMapState build() {
    ref.onDispose(() => _timer?.cancel());
    // Signed out or another account: nothing of the old club stays
    ref.listen(authUserIdProvider, (prev, next) {
      // Only a real change of account (not the first value arriving)
      if ((prev?.hasValue ?? false) && next.hasValue && prev!.value != next.value) close();
    });
    return const ClubMapState();
  }

  ClubMapRepository get _repo => ref.read(clubMapRepositoryProvider);

  /// Shows [club]'s drawings (the Map tab was opened) and keeps them fresh
  Future<void> open(CommunityClub club) async {
    if (state.club?.id != club.id) {
      state = ClubMapState(club: club, loading: true);
    }
    _timer?.cancel();
    _timer = Timer.periodic(clubMapRefreshEvery, (_) => unawaited(reload()));
    await reload();
  }

  void close() {
    _timer?.cancel();
    _timer = null;
    if (state.shown) state = const ClubMapState();
  }

  Future<void> reload() async {
    final club = state.club;
    if (club == null) return;
    try {
      final a = await _repo.annotations(club.id);
      final v = await _repo.views(club.id);
      if (!ref.mounted || state.club?.id != club.id) return;
      final keep = a.any((x) => x.id == state.selectedId);
      state = state.copyWith(
        annotations: a,
        views: v,
        loading: false,
        error: () => null,
        selectedId: keep ? null : () => null,
      );
    } on Object catch (e) {
      if (!ref.mounted || state.club?.id != club.id) return;
      state = state.copyWith(loading: false, error: () => e is CommunityException ? e.message : '$e');
    }
  }

  void select(String? id) => state = state.copyWith(selectedId: () => id);

  /// The selected drawing (or all of them) fits the screen
  void fit([Annotation? a]) {
    final pts = a == null ? [for (final x in state.annotations) ...x.points] : a.points;
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      ref.read(flyToProvider.notifier).go(pts.first.$1, pts.first.$2, zoom: 15);
    } else {
      ref.read(fitPointsProvider.notifier).go(pts);
    }
  }

  Future<String> save(
    String? id, {
    required AnnotationKind kind,
    required String label,
    required String note,
    required String color,
    required Map<String, Object> geometry,
  }) async {
    final club = state.club!;
    final saved = await _repo.save(club.id, id, kind: kind, label: label, note: note, color: color, geometry: geometry);
    state = state.copyWith(selectedId: () => saved);
    await reload();
    return saved;
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    state = state.copyWith(
      annotations: [
        for (final a in state.annotations)
          if (a.id != id) a,
      ],
      selectedId: state.selectedId == id ? () => null : null,
    );
  }

  /// Saves the camera as it is now under [name]
  Future<void> saveView(String name) async {
    final club = state.club!;
    final c = ref.read(mapCenterProvider);
    final t = ref.read(mapTiltProvider);
    final threeD = ref.read(mapSettingsProvider).is3D;
    await _repo.saveView(
      club.id,
      name: name,
      lng: c.lng,
      lat: c.lat,
      zoom: ref.read(mapZoomProvider),
      pitch: threeD ? t.pitch : 0,
      bearing: t.bearing,
      terrain: threeD,
    );
    await reload();
  }

  Future<void> deleteView(String id) async {
    await _repo.deleteView(id);
    state = state.copyWith(
      views: [
        for (final v in state.views)
          if (v.id != id) v,
      ],
    );
  }

  /// Flies to [v], in 3D when it was saved in 3D
  void flyTo(SavedView v) {
    ref.read(mapSettingsProvider.notifier).setView(v.terrain ? MapView.threeD : MapView.twoD);
    ref.read(cameraToProvider.notifier).go((
      lng: v.lng,
      lat: v.lat,
      zoom: v.zoom,
      pitch: v.terrain ? v.pitch : 0,
      bearing: v.bearing,
    ));
  }
}

// --- Drawing -------------------------------------------------------------------------------------

/// A drawing being made ([editingId] null) or changed: its points on the map, then its details
class ClubDraw {
  const ClubDraw({
    required this.kind,
    this.editingId,
    this.points = const [],
    this.color = '#d49b22',
    this.label = '',
    this.note = '',
  });

  final AnnotationKind kind;
  final String? editingId;
  final List<LngLat> points;
  final String color;
  final String label;
  final String note;

  bool get ready => points.length >= kind.needed;

  ClubDraw copyWith({List<LngLat>? points, String? color, String? label, String? note}) => ClubDraw(
    kind: kind,
    editingId: editingId,
    points: points ?? this.points,
    color: color ?? this.color,
    label: label ?? this.label,
    note: note ?? this.note,
  );
}

final clubDrawProvider = NotifierProvider<ClubDrawController, ClubDraw?>(ClubDrawController.new);

/// The drawing whose points are done: the details form opens for it (the map screen listens)
final clubDrawDoneProvider = NotifierProvider<ClubDrawDone, ClubDraw?>(ClubDrawDone.new);

class ClubDrawDone extends Notifier<ClubDraw?> {
  @override
  ClubDraw? build() => null;

  void set(ClubDraw? d) => state = d;
}

class ClubDrawController extends Notifier<ClubDraw?> {
  @override
  ClubDraw? build() => null;

  /// New [kind], or [existing] again with its points, label, note and colour
  void start(AnnotationKind kind, {Annotation? existing}) => state = ClubDraw(
    kind: kind,
    editingId: existing?.id,
    points: existing?.points ?? const [],
    color: existing?.color ?? annotationColors.first,
    label: existing?.label ?? '',
    note: existing?.note ?? '',
  );

  /// Back to the map with the details kept ("Change shape")
  void resume(ClubDraw d) => state = d;

  /// A pin or note moves to the tap; a line or area gets one more point
  void tap(LngLat p) {
    final d = state;
    if (d == null) return;
    state = d.copyWith(points: d.kind.isPoint ? [p] : [...d.points, p]);
  }

  void undo() {
    final d = state;
    if (d == null || d.points.isEmpty) return;
    state = d.copyWith(points: d.points.sublist(0, d.points.length - 1));
  }

  void cancel() => state = null;

  /// The points are done: on to the label, note and colour
  void done() {
    final d = state;
    if (d == null || !d.ready) return;
    state = null;
    ref.read(clubDrawDoneProvider.notifier).set(d);
  }
}
