import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers.dart';
import '../../data/basemaps/custom_basemaps.dart';
import '../map/style_guard.dart';

// Custom basemaps on the phone: the account's list, which are switched on (saved in the
// account like the web), the opacity of each (on this phone), and the pictures kept here so
// they show without signal. Every Enterprise account; the admin counts as Enterprise.

final basemapBackendProvider = Provider<BasemapBackend>(
  (ref) => SupabaseBasemapBackend(ref.watch(supabaseClientProvider)),
);

final basemapFilesProvider = Provider<BasemapFiles>((ref) => DiskBasemapFiles());

final basemapPrefsProvider = Provider<SharedPreferencesAsync>((ref) => SharedPreferencesAsync());

const _opacityKey = 'l360-basemap-opacity';

class BasemapsState {
  const BasemapsState({
    this.userId,
    this.basemaps = const [],
    this.files = const {},
    this.opacity = const {},
    this.loading = false,
    this.error,
  });

  final String? userId;
  final List<CustomBasemap> basemaps;
  final Map<String, String> files; // id → picture on this phone
  final Map<String, double> opacity; // id → 0..1
  final bool loading;
  final String? error;

  int get usedBytes => basemaps.fold(0, (a, b) => a + b.fileSize);
  double opacityOf(String id) => opacity[id] ?? 1;

  BasemapsState copyWith({
    List<CustomBasemap>? basemaps,
    Map<String, String>? files,
    Map<String, double>? opacity,
    bool? loading,
    String? Function()? error,
  }) => BasemapsState(
    userId: userId,
    basemaps: basemaps ?? this.basemaps,
    files: files ?? this.files,
    opacity: opacity ?? this.opacity,
    loading: loading ?? this.loading,
    error: error == null ? this.error : error(),
  );
}

final basemapsProvider = NotifierProvider<BasemapsController, BasemapsState>(BasemapsController.new);

class BasemapsController extends Notifier<BasemapsState> {
  @override
  BasemapsState build() {
    ref.listen(authUserIdProvider, (_, next) {
      if (!next.hasValue) return;
      final id = next.value;
      unawaited(
        Future(() {
          if (!ref.mounted) return;
          id == null ? reset() : unawaited(init(id));
        }),
      );
    }, fireImmediately: true);
    return const BasemapsState();
  }

  BasemapBackend get _cloud => ref.read(basemapBackendProvider);
  BasemapFiles get _files => ref.read(basemapFilesProvider);

  /// Same rule as can_upload_custom_basemaps() on the server
  bool get canUse {
    final p = ref.read(profileProvider).value;
    return p != null && (p.isAdmin || p.plan.value == 'Enterprise');
  }

  Future<void> init(String userId) async {
    if (state.userId == userId) return;
    state = BasemapsState(userId: userId);
    try {
      final raw = await ref.read(basemapPrefsProvider).getString('$_opacityKey-$userId');
      final map = raw == null ? const <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
      state = state.copyWith(opacity: {for (final e in map.entries) e.key: (e.value as num).toDouble().clamp(0, 1)});
    } on Object {
      // No saved opacity: fully visible
    }
    await refresh();
  }

  void reset() => state = const BasemapsState();

  Future<void> refresh() async {
    final userId = state.userId;
    if (userId == null) return;
    state = state.copyWith(loading: true);
    try {
      final list = await _cloud.list(userId);
      if (state.userId != userId) return;
      state = state.copyWith(basemaps: list, error: () => null);
      await _bringFiles();
    } on Object catch (e) {
      if (state.userId == userId) state = state.copyWith(error: () => 'Could not load basemaps: $e');
    } finally {
      if (state.userId == userId) state = state.copyWith(loading: false);
    }
  }

  /// Pictures of the switched-on basemaps onto the phone (once; then they work offline)
  Future<void> _bringFiles() async {
    for (final b in state.basemaps.where((b) => b.active)) {
      if (state.files.containsKey(b.id)) continue;
      try {
        final file = await _files.get(b.id) ?? await _files.save(b.id, await _cloud.download(b.filePath));
        state = state.copyWith(files: {...state.files, b.id: file.path});
      } on Object catch (e) {
        state = state.copyWith(error: () => 'Could not download "${b.name}": $e');
      }
    }
  }

  Future<void> setActive(String id, bool active) async {
    final before = state.basemaps;
    state = state.copyWith(basemaps: [for (final b in before) b.id == id ? b.withActive(active) : b]);
    try {
      await _cloud.setActive(id, active);
      if (active) await _bringFiles();
    } on Object catch (e) {
      state = state.copyWith(basemaps: before, error: () => 'Could not switch the basemap: $e');
    }
  }

  void setOpacity(String id, double v) {
    state = state.copyWith(opacity: {...state.opacity, id: v.clamp(0, 1)});
    final userId = state.userId;
    if (userId != null) {
      unawaited(
        ref
            .read(basemapPrefsProvider)
            .setString('$_opacityKey-$userId', jsonEncode(state.opacity))
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> delete(CustomBasemap b) async {
    await _cloud.delete(b);
    await _files.remove(b.id);
    state = state.copyWith(
      basemaps: state.basemaps.where((x) => x.id != b.id).toList(),
      files: {...state.files}..remove(b.id),
    );
  }
}

// --- On the map ------------------------------------------------------------------------------

String _source(String id) => 'basemap-$id';
String _layer(String id) => 'basemap-layer-$id';

/// Each switched-on basemap as a picture on its four corners, from the file on the phone
class BasemapLayer {
  BasemapLayer(this.map);

  final mbx.MapboxMap map;
  final _shown = <String, String>{}; // id → file shown
  bool _installed = false;

  /// After a style change everything is added again
  void reset() {
    _shown.clear();
    _installed = true;
  }

  Future<void> show(BasemapsState s, {String? below}) => onStyle(() => _show(s, below: below));

  Future<void> _show(BasemapsState s, {String? below}) async {
    if (!_installed) return;
    final want = {
      for (final b in s.basemaps)
        if (b.active && b.bounds != null && s.files[b.id] != null) b.id: b,
    };
    for (final id in _shown.keys.toList()) {
      if (want.containsKey(id) && want[id] != null && _shown[id] == s.files[id]) continue;
      if (await map.styleLayerExists(_layer(id))) await map.removeStyleLayer(_layer(id));
      if (await map.styleSourceExists(_source(id))) await map.removeStyleSource(_source(id));
      _shown.remove(id);
    }
    for (final b in want.values) {
      final file = s.files[b.id]!;
      if (!_shown.containsKey(b.id)) {
        final g = b.bounds!;
        await map.addStyleSource(
          _source(b.id),
          jsonEncode({
            'type': 'image',
            'url': Uri.file(file).toString(),
            'coordinates': [
              [g.west, g.north],
              [g.east, g.north],
              [g.east, g.south],
              [g.west, g.south],
            ],
          }),
        );
        await map.addStyleLayer(
          jsonEncode({
            'id': _layer(b.id),
            'type': 'raster',
            'source': _source(b.id),
            'paint': {'raster-opacity': s.opacityOf(b.id), 'raster-fade-duration': 300},
          }),
          below == null ? null : mbx.LayerPosition(below: below),
        );
        _shown[b.id] = file;
      } else {
        await map.setStyleLayerProperty(_layer(b.id), 'raster-opacity', s.opacityOf(b.id));
      }
    }
  }
}
