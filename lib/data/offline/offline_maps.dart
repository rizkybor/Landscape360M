import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/map/map_settings.dart';
import '../../domain/map/offline_regions.dart';

// Offline maps: the record of each downloaded area in the cloud (table offline_maps, whose
// insert trigger checks the plan's count and size), and the map data on the phone in
// Mapbox's own offline store, which the map uses by itself when there is no signal.

class OfflineRegionRecord {
  const OfflineRegionRecord({
    required this.id,
    required this.name,
    required this.bounds,
    required this.minZoom,
    required this.maxZoom,
    required this.tileCount,
    required this.sizeEstMb,
    this.createdAt,
  });

  factory OfflineRegionRecord.fromRow(Map<String, dynamic> r) => OfflineRegionRecord(
    id: '${r['id']}',
    name: '${r['name'] ?? ''}',
    bounds: OfflineBounds.fromJson(Map<String, dynamic>.from(r['bounds'] as Map)),
    minZoom: (r['min_zoom'] as num).toInt(),
    maxZoom: (r['max_zoom'] as num).toInt(),
    tileCount: (r['tile_count'] as num? ?? 0).toInt(),
    sizeEstMb: (r['size_est_mb'] as num? ?? 0).toDouble(),
    createdAt: DateTime.tryParse('${r['created_at']}'),
  );

  final String id;
  final String name;
  final OfflineBounds bounds;
  final int minZoom;
  final int maxZoom;
  final int tileCount;
  final double sizeEstMb;
  final DateTime? createdAt;

  Map<String, dynamic> toRow(String userId) => {
    'id': id,
    'user_id': userId,
    'name': name,
    'bounds': bounds.toJson(),
    'min_zoom': minZoom,
    'max_zoom': maxZoom,
    'tile_count': tileCount,
    'size_est_mb': sizeEstMb,
  };
}

class OfflineException implements Exception {
  const OfflineException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract interface class OfflineRecords {
  Future<List<OfflineRegionRecord>> list(String userId);
  Future<void> add(String userId, OfflineRegionRecord r);
  Future<void> delete(String userId, String id);
}

class SupabaseOfflineRecords implements OfflineRecords {
  SupabaseOfflineRecords(this.client);

  final SupabaseClient client;

  @override
  Future<List<OfflineRegionRecord>> list(String userId) async {
    final rows = await client.from('offline_maps').select().eq('user_id', userId).order('created_at');
    return rows.map(OfflineRegionRecord.fromRow).toList();
  }

  @override
  Future<void> add(String userId, OfflineRegionRecord r) async {
    try {
      await client.from('offline_maps').insert(r.toRow(userId));
    } on PostgrestException catch (e) {
      // check_offline_map_limits explains the limit in its message
      throw OfflineException(e.message);
    }
  }

  @override
  Future<void> delete(String userId, String id) =>
      client.from('offline_maps').delete().eq('id', id).eq('user_id', userId);
}

/// The map data on the phone
abstract interface class OfflineEngine {
  /// Downloads the styles and the tiles of the area; [onProgress] gets 0..1
  Future<void> download({
    required String id,
    required String name,
    required OfflineBounds bounds,
    required int minZoom,
    required int maxZoom,
    required List<MapStyle> styles,
    required void Function(double) onProgress,
  });

  Future<void> remove(String id);

  /// Areas on this phone and their size in bytes
  Future<Map<String, int>> stored();
}

class MapboxOfflineEngine implements OfflineEngine {
  TileStore? _tiles;
  OfflineManager? _styles;

  Future<TileStore> get _store async => _tiles ??= await TileStore.createDefault();

  @override
  Future<void> download({
    required String id,
    required String name,
    required OfflineBounds bounds,
    required int minZoom,
    required int maxZoom,
    required List<MapStyle> styles,
    required void Function(double) onProgress,
  }) async {
    // Style, fonts and icons first (a few hundred KB), counted as the first 5%
    final manager = _styles ??= await OfflineManager.create();
    for (final style in styles) {
      await manager.loadStylePack(
        style.uri,
        StylePackLoadOptions(
          glyphsRasterizationMode: GlyphsRasterizationMode.IDEOGRAPHS_RASTERIZED_LOCALLY,
          acceptExpired: false,
        ),
        null,
      );
    }
    onProgress(0.05);
    final geometry = Polygon(
      coordinates: [
        [for (final (lng, lat) in bounds.ring) Position(lng, lat)],
      ],
    ).toJson();
    final store = await _store;
    await store.loadTileRegion(
      id,
      TileRegionLoadOptions(
        geometry: geometry,
        descriptorsOptions: [
          for (final style in styles)
            TilesetDescriptorOptions(
              styleURI: style.uri,
              minZoom: minZoom,
              maxZoom: maxZoom,
              // The elevation the app adds for 3D, contours and heights
              tilesets: [terrainSourceUrl],
            ),
        ],
        metadata: {'name': name},
        acceptExpired: true,
        networkRestriction: NetworkRestriction.NONE,
      ),
      (p) {
        if (p.requiredResourceCount > 0) {
          onProgress(0.05 + 0.95 * p.completedResourceCount / p.requiredResourceCount);
        }
      },
    );
    onProgress(1);
  }

  @override
  Future<void> remove(String id) async {
    await (await _store).removeRegion(id);
  }

  @override
  Future<Map<String, int>> stored() async {
    final regions = await (await _store).allTileRegions();
    return {for (final r in regions) r.id: r.completedResourceSize};
  }
}
