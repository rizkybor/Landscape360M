import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/geo/spherical.dart';
import '../../domain/marked/area_contours.dart';
import '../../domain/marked/marked_areas.dart';

// Marked areas in the cloud (src/services/markedAreaSync.ts): table marked_areas and the
// share-link functions of 20261026000019. The plan limit and who sees what are enforced by
// the database.

/// [[lng, lat], ...] from the database
List<LngLat> _ring(Object? raw) => [
  for (final p in (raw as List? ?? const []).cast<List<dynamic>>())
    ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
];

class MarkedArea {
  const MarkedArea({
    required this.id,
    required this.userId,
    required this.name,
    required this.color,
    this.notes,
    required this.ring,
    required this.areaM2,
    required this.perimeterM,
  });

  factory MarkedArea.fromRow(Map<String, dynamic> r) => MarkedArea(
    id: '${r['id']}',
    userId: '${r['user_id']}',
    name: '${r['name'] ?? ''}',
    color: '${r['color'] ?? areaColors.first}',
    notes: r['notes'] as String?,
    ring: _ring(r['ring']),
    areaM2: (r['area_m2'] as num? ?? 0).toDouble(),
    perimeterM: (r['perimeter_m'] as num? ?? 0).toDouble(),
  );

  final String id;
  final String userId;
  final String name;
  final String color; // #rrggbb
  final String? notes;
  final List<LngLat> ring; // not closed
  final double areaM2;
  final double perimeterM;
}

/// A marked area opened from its share link (no sign-in)
class LinkedArea {
  const LinkedArea({
    required this.name,
    required this.color,
    this.notes,
    required this.ring,
    required this.areaM2,
    required this.perimeterM,
    this.ownerName,
  });

  factory LinkedArea.fromRow(Map<String, dynamic> r) => LinkedArea(
    name: '${r['name'] ?? ''}',
    color: '${r['color'] ?? areaColors.first}',
    notes: r['notes'] as String?,
    ring: _ring(r['ring']),
    areaM2: (r['area_m2'] as num? ?? 0).toDouble(),
    perimeterM: (r['perimeter_m'] as num? ?? 0).toDouble(),
    ownerName: r['owner_name'] as String?,
  );

  final String name;
  final String color;
  final String? notes;
  final List<LngLat> ring;
  final double areaM2;
  final double perimeterM;
  final String? ownerName;
}

class MarkedAreaInput {
  const MarkedAreaInput({required this.name, required this.color, this.notes = '', required this.ring});

  final String name;
  final String color;
  final String notes;
  final List<LngLat> ring;

  /// Size figures are worked out here and stored, so lists and shared links show them at once
  Map<String, dynamic> toRow() {
    double fix7(double v) => double.parse(v.toStringAsFixed(7));
    return {
      'name': name.trim(),
      'color': color,
      'notes': notes.trim().isEmpty ? null : notes.trim(),
      'ring': [
        for (final (lng, lat) in ring) [fix7(lng), fix7(lat)],
      ],
      'area_m2': ringArea(ring),
      'perimeter_m': ringPerimeter(ring),
    };
  }
}

class MarkedAreaException implements Exception {
  const MarkedAreaException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract interface class MarkedAreaBackend {
  Future<List<MarkedArea>> mine(String userId);
  Future<MarkedArea> create(MarkedAreaInput input);
  Future<MarkedArea> update(String id, MarkedAreaInput input);
  Future<void> delete(String id);
  Future<String?> link(String id);
  Future<String> createLink(String id);
  Future<void> revokeLink(String id);

  /// Null when the link does not exist or was turned off
  Future<LinkedArea?> open(String token);

  /// Which of my areas have contours uploaded on the website; empty before the migration
  Future<List<AreaContourMeta>> contourMeta(String userId);

  /// The contour lines of one of my areas (GeoJSON)
  Future<Map<String, dynamic>> contours(String areaId);

  /// The contours of a shared area, or null (none, link off, or migration not run)
  Future<ContourSet?> linkContours(String token);
}

// The table or functions are missing until the migration is run
final _missing = RegExp(
  r'PGRST202|PGRST205|42P01|could not find the (function|table)|relation .* does not exist',
  caseSensitive: false,
);

class SupabaseMarkedAreaBackend implements MarkedAreaBackend {
  SupabaseMarkedAreaBackend(this.client);

  final SupabaseClient client;

  Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on PostgrestException catch (e) {
      throw MarkedAreaException(
        _missing.hasMatch('${e.code ?? ''} ${e.message}')
            ? 'Marked Areas are not set up yet (run the 20261026000019 migration)'
            : e.message,
      );
    }
  }

  @override
  Future<List<MarkedArea>> mine(String userId) => _call(() async {
    final rows = await client.from('marked_areas').select().eq('user_id', userId).order('created_at', ascending: false);
    return rows.map(MarkedArea.fromRow).toList();
  });

  @override
  Future<MarkedArea> create(MarkedAreaInput input) =>
      _call(() async => MarkedArea.fromRow(await client.from('marked_areas').insert(input.toRow()).select().single()));

  @override
  Future<MarkedArea> update(String id, MarkedAreaInput input) => _call(
    () async =>
        MarkedArea.fromRow(await client.from('marked_areas').update(input.toRow()).eq('id', id).select().single()),
  );

  @override
  Future<void> delete(String id) => _call(() => client.from('marked_areas').delete().eq('id', id));

  @override
  Future<String?> link(String id) =>
      _call(() => client.rpc<String?>('get_marked_area_link', params: {'p_area_id': id}));

  @override
  Future<String> createLink(String id) =>
      _call(() => client.rpc<String>('create_marked_area_link', params: {'p_area_id': id}));

  @override
  Future<void> revokeLink(String id) =>
      _call(() => client.rpc<void>('revoke_marked_area_link', params: {'p_area_id': id}));

  @override
  Future<LinkedArea?> open(String token) => _call(() async {
    final rows = await client.rpc<List<dynamic>>('open_marked_area_link', params: {'p_token': token});
    return rows.isEmpty ? null : LinkedArea.fromRow(Map<String, dynamic>.from(rows.first as Map));
  });

  // --- Contours uploaded on the website (marked_area_contours, 20261030000021)

  static const _contourMeta =
      'area_id, source_name, source_format, interval_m, line_count, min_elevation, max_elevation, updated_at';

  @override
  Future<List<AreaContourMeta>> contourMeta(String userId) async {
    try {
      final rows = await client.from('marked_area_contours').select(_contourMeta).eq('user_id', userId);
      return rows.map(AreaContourMeta.fromRow).toList();
    } on PostgrestException catch (e) {
      if (_missing.hasMatch('${e.code ?? ''} ${e.message}')) return const [];
      throw MarkedAreaException(e.message);
    }
  }

  @override
  Future<Map<String, dynamic>> contours(String areaId) => _call(() async {
    final row = await client.from('marked_area_contours').select('data').eq('area_id', areaId).single();
    return Map<String, dynamic>.from(row['data'] as Map);
  });

  @override
  Future<ContourSet?> linkContours(String token) async {
    try {
      final rows = await client.rpc<List<dynamic>>('open_marked_area_link_contours', params: {'p_token': token});
      if (rows.isEmpty) return null;
      final r = Map<String, dynamic>.from(rows.first as Map);
      return (data: Map<String, dynamic>.from(r['data'] as Map), intervalM: (r['interval_m'] as num?)?.toDouble());
    } on Object {
      return null;
    }
  }
}
