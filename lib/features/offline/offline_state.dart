import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/offline/offline_maps.dart';
import '../../domain/map/map_settings.dart';
import '../../domain/map/offline_regions.dart';
import '../../domain/survey/survey_model.dart' show newUuid;

// Offline maps (OfflineManager.tsx, RegionDrawingOverlay.tsx on the web): the areas this
// account downloaded, which of them are on this phone, downloads with progress, and the
// frame on the map that picks a new area. The plan's limits are checked here first and
// again by the server when the record is saved.

final offlineRecordsProvider = Provider<OfflineRecords>(
  (ref) => SupabaseOfflineRecords(ref.watch(supabaseClientProvider)),
);

final offlineEngineProvider = Provider<OfflineEngine>((ref) => MapboxOfflineEngine());

enum OfflineStatus { downloading, ready, notOnPhone, failed }

class OfflineRegionView {
  const OfflineRegionView(this.record, this.status, {this.progress = 0, this.bytes});
  final OfflineRegionRecord record;
  final OfflineStatus status;
  final double progress; // 0..1 while downloading
  final int? bytes; // size on this phone
}

class OfflineState {
  const OfflineState({
    this.userId,
    this.records = const [],
    this.stored = const {},
    this.progress = const {},
    this.failed = const {},
    this.loading = false,
    this.framing = false,
    this.error,
  });

  final String? userId;
  final List<OfflineRegionRecord> records;
  final Map<String, int> stored; // id → bytes on this phone
  final Map<String, double> progress; // downloads running
  final Set<String> failed;
  final bool loading;
  final bool framing; // picking a new area on the map
  final String? error;

  List<OfflineRegionView> get regions => [
    for (final r in records)
      if (progress.containsKey(r.id))
        OfflineRegionView(r, OfflineStatus.downloading, progress: progress[r.id]!)
      else if (failed.contains(r.id))
        OfflineRegionView(r, OfflineStatus.failed)
      else if (stored.containsKey(r.id))
        OfflineRegionView(r, OfflineStatus.ready, bytes: stored[r.id])
      else
        OfflineRegionView(r, OfflineStatus.notOnPhone),
  ];

  OfflineState copyWith({
    List<OfflineRegionRecord>? records,
    Map<String, int>? stored,
    Map<String, double>? progress,
    Set<String>? failed,
    bool? loading,
    bool? framing,
    String? Function()? error,
  }) => OfflineState(
    userId: userId,
    records: records ?? this.records,
    stored: stored ?? this.stored,
    progress: progress ?? this.progress,
    failed: failed ?? this.failed,
    loading: loading ?? this.loading,
    framing: framing ?? this.framing,
    error: error == null ? this.error : error(),
  );
}

final offlineProvider = NotifierProvider<OfflineController, OfflineState>(OfflineController.new);

/// Asks the map to open the Offline maps sheet: User Account closes first, so the map is in
/// view when an area is framed for download
class OfflineSheetRequest extends Notifier<bool> {
  @override
  bool build() => false;

  void open() => state = true;

  /// The map opened it
  void done() => state = false;
}

/// True until the map has opened the sheet (kept if the map is not on screen yet)
final offlineSheetRequestProvider = NotifierProvider<OfflineSheetRequest, bool>(OfflineSheetRequest.new);

/// What a new download would be
class OfflinePlan {
  const OfflinePlan({
    required this.bounds,
    required this.minZoom,
    required this.maxZoom,
    required this.tiles,
    required this.sizeMb,
  });

  factory OfflinePlan.of(OfflineBounds bounds, double zoom, {required bool satellite, required bool map}) {
    final (min, max) = offlineZoomRange(zoom);
    final tiles = tileCount(bounds, min, max);
    return OfflinePlan(
      bounds: bounds,
      minZoom: min,
      maxZoom: max,
      tiles: tiles,
      sizeMb: estimateOfflineMb(tiles, satellite: satellite, map: map),
    );
  }

  final OfflineBounds bounds;
  final int minZoom;
  final int maxZoom;
  final int tiles;
  final double sizeMb;
}

class OfflineController extends Notifier<OfflineState> {
  @override
  OfflineState build() {
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
    return const OfflineState();
  }

  OfflineRecords get _records => ref.read(offlineRecordsProvider);
  OfflineEngine get _engine => ref.read(offlineEngineProvider);

  ({String plan, bool admin}) get _account {
    final p = ref.read(profileProvider).value;
    return (plan: p?.plan.value ?? 'Free', admin: p?.isAdmin ?? false);
  }

  ({int count, double sizeMb}) get limits => offlineLimits(_account.plan, isAdmin: _account.admin);

  Future<void> init(String userId) async {
    if (state.userId == userId) return;
    state = OfflineState(userId: userId);
    await refresh();
  }

  void reset() => state = const OfflineState();

  Future<void> refresh() async {
    final userId = state.userId;
    if (userId == null) return;
    state = state.copyWith(loading: true);
    try {
      final stored = await _engine.stored();
      if (state.userId == userId) state = state.copyWith(stored: stored);
      final records = await _records.list(userId);
      if (state.userId == userId) state = state.copyWith(records: records, error: () => null);
    } on Object catch (e) {
      // Without signal the list from the last visit stays, with what is on the phone
      if (state.userId == userId) state = state.copyWith(error: () => 'Could not load offline maps: $e');
    } finally {
      if (state.userId == userId) state = state.copyWith(loading: false);
    }
  }

  void startFraming() => state = state.copyWith(framing: true, error: () => null);
  void stopFraming() => state = state.copyWith(framing: false);
  void clearError() => state = state.copyWith(error: () => null);

  /// Why [plan] cannot be downloaded now, or null
  String? check(OfflinePlan plan) => offlineLimitError(
    plan: _account.plan,
    isAdmin: _account.admin,
    existing: state.records.length,
    sizeMb: plan.sizeMb,
  );

  /// Saves the record (the server checks the limits again), then downloads; null when it
  /// started, else the problem
  Future<String?> download(String name, OfflinePlan plan, {required bool satellite, required bool map}) async {
    final userId = state.userId;
    if (userId == null) return 'Sign in to download offline maps.';
    if (name.trim().isEmpty) return 'Give the area a name';
    if (!satellite && !map) return 'Choose satellite, map or both';
    final problem = check(plan);
    if (problem != null) return problem;
    final record = OfflineRegionRecord(
      id: newUuid(),
      name: name.trim(),
      bounds: plan.bounds,
      minZoom: plan.minZoom,
      maxZoom: plan.maxZoom,
      tileCount: plan.tiles,
      sizeEstMb: plan.sizeMb,
    );
    try {
      await _records.add(userId, record);
    } on Object catch (e) {
      return '$e';
    }
    state = state.copyWith(records: [...state.records, record], framing: false);
    unawaited(_load(record, [if (satellite) MapStyle.satellite, if (map) MapStyle.outdoors]));
    return null;
  }

  /// Downloads an area that is not (or not fully) on this phone, e.g. saved on another device
  Future<void> downloadAgain(OfflineRegionRecord record) =>
      _load(record, const [MapStyle.satellite, MapStyle.outdoors]);

  Future<void> _load(OfflineRegionRecord r, List<MapStyle> styles) async {
    state = state.copyWith(progress: {...state.progress, r.id: 0}, failed: {...state.failed}..remove(r.id));
    try {
      await _engine.download(
        id: r.id,
        name: r.name,
        bounds: r.bounds,
        minZoom: r.minZoom,
        maxZoom: r.maxZoom,
        styles: styles,
        onProgress: (p) {
          if (ref.mounted && state.progress.containsKey(r.id)) {
            state = state.copyWith(progress: {...state.progress, r.id: p});
          }
        },
      );
      final stored = await _engine.stored();
      if (!ref.mounted) return;
      state = state.copyWith(stored: stored, progress: {...state.progress}..remove(r.id));
    } on Object catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(
        progress: {...state.progress}..remove(r.id),
        failed: {...state.failed, r.id},
        error: () => 'Download of "${r.name}" stopped: $e',
      );
    }
  }

  /// Removes the area from this phone and from the account
  Future<void> delete(OfflineRegionRecord r) async {
    final userId = state.userId;
    if (userId == null) return;
    await _records.delete(userId, r.id);
    try {
      await _engine.remove(r.id);
    } on Object {
      // Not on this phone: nothing to free
    }
    state = state.copyWith(
      records: state.records.where((x) => x.id != r.id).toList(),
      stored: {...state.stored}..remove(r.id),
      failed: {...state.failed}..remove(r.id),
    );
  }
}

/// "12.4 MB" for bytes on the phone
String formatBytes(int bytes) =>
    bytes >= 1024 * 1024 ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB' : '${(bytes / 1024).ceil()} KB';
