import '../../domain/community/club_map.dart';
import 'community_repository.dart';

// The club map over the functions of 20261102000030_community_club_map.sql (the same backend as
// the rest of Community): drawings, their comments, and saved views.

List<Map<String, dynamic>> _rows(Object? data) => [
  for (final r in (data is List ? data : const <Object?>[]))
    if (r is Map) Map<String, dynamic>.from(r),
];

class ClubMapRepository {
  ClubMapRepository(this.backend);

  final CommunityBackend backend;

  Future<List<Annotation>> annotations(String clubId) async =>
      _rows(await backend.rpc('community_club_annotations', {'p_club_id': clubId})).map(Annotation.fromRow).toList();

  /// Creates ([id] null) or changes a drawing; returns its id
  Future<String> save(
    String clubId,
    String? id, {
    required AnnotationKind kind,
    required String label,
    String note = '',
    required String color,
    required Map<String, Object> geometry,
  }) async =>
      '${await backend.rpc('save_community_club_annotation', {'p_club_id': clubId, 'p_id': id, 'p_kind': kind.name, 'p_label': label.trim(), 'p_note': note.trim().isEmpty ? null : note.trim(), 'p_color': color, 'p_geometry': geometry})}';

  Future<void> delete(String id) => backend.rpc('delete_community_club_annotation', {'p_id': id});

  Future<List<AnnotationComment>> comments(String annotationId) async =>
      _rows(await backend.rpc('community_club_annotation_comments', {'p_id': annotationId}))
          .map(AnnotationComment.fromRow)
          .toList();

  Future<void> addComment(String annotationId, String body) =>
      backend.rpc('add_community_club_annotation_comment', {'p_id': annotationId, 'p_body': body.trim()});

  Future<void> deleteComment(String id) => backend.rpc('delete_community_club_annotation_comment', {'p_id': id});

  Future<List<SavedView>> views(String clubId) async =>
      _rows(await backend.rpc('community_club_views', {'p_club_id': clubId})).map(SavedView.fromRow).toList();

  Future<String> saveView(
    String clubId, {
    required String name,
    required double lng,
    required double lat,
    required double zoom,
    required double pitch,
    required double bearing,
    required bool terrain,
  }) async =>
      '${await backend.rpc('save_community_club_view', {'p_club_id': clubId, 'p_name': name.trim(), 'p_lng': lng, 'p_lat': lat, 'p_zoom': zoom, 'p_pitch': pitch, 'p_bearing': bearing, 'p_terrain': terrain})}';

  Future<void> deleteView(String id) => backend.rpc('delete_community_club_view', {'p_id': id});
}
