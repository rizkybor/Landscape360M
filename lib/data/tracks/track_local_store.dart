import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../domain/tracks/recorded_track.dart';
import '../../domain/tracks/track_recorder_geo.dart';

// Tracks on the phone (src/utils/trackRecorderDb.ts on the web). Every accepted GPS point
// is written here first, so a recording survives no signal, the app being closed and the
// phone restarting. SQLite in the app's own sandbox, one row per track and per point.

abstract interface class TrackLocalStore {
  Future<void> saveTrack(RecordedTrack track);
  Future<RecordedTrack?> getTrack(String id);

  /// This account's tracks, newest first
  Future<List<RecordedTrack>> listTracks(String userId);
  Future<void> addPoint(String trackId, int seq, TrackPoint point);
  Future<List<TrackPoint>> getPoints(String trackId);
  Future<void> deleteTrack(String trackId);
}

extension UnfinishedTrack on TrackLocalStore {
  /// A recording that was interrupted (app closed, phone restarted)
  Future<RecordedTrack?> findUnfinishedTrack(String userId) async {
    for (final t in await listTracks(userId)) {
      if (t.status != TrackStatus.completed) return t;
    }
    return null;
  }
}

class SqliteTrackStore implements TrackLocalStore {
  SqliteTrackStore({DatabaseFactory? factory, this.path}) : _factory = factory ?? databaseFactory;

  final DatabaseFactory _factory;

  /// Database file; the app's databases folder when null
  final String? path;
  Future<Database>? _db;

  Future<Database> get _open => _db ??= () async {
    final file = path ?? p.join(await _factory.getDatabasesPath(), 'track_recorder.db');
    return _factory.openDatabase(
      file,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE tracks (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, started_at INTEGER NOT NULL, data TEXT NOT NULL)',
          );
          await db.execute('CREATE INDEX tracks_user ON tracks (user_id, started_at DESC)');
          await db.execute(
            'CREATE TABLE points (track_id TEXT NOT NULL, seq INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY (track_id, seq))',
          );
        },
      ),
    );
  }();

  @override
  Future<void> saveTrack(RecordedTrack track) async {
    final db = await _open;
    await db.insert('tracks', {
      'id': track.id,
      'user_id': track.userId,
      'started_at': track.startedAt,
      'data': jsonEncode(track.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<RecordedTrack?> getTrack(String id) async {
    final rows = await (await _open).query('tracks', columns: ['data'], where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _track(rows.first);
  }

  @override
  Future<List<RecordedTrack>> listTracks(String userId) async {
    final rows = await (await _open).query(
      'tracks',
      columns: ['data'],
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'started_at DESC',
    );
    return rows.map(_track).toList();
  }

  @override
  Future<void> addPoint(String trackId, int seq, TrackPoint point) async {
    await (await _open).insert('points', {
      'track_id': trackId,
      'seq': seq,
      'data': jsonEncode(point.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<TrackPoint>> getPoints(String trackId) async {
    final rows = await (await _open).query(
      'points',
      columns: ['data'],
      where: 'track_id = ?',
      whereArgs: [trackId],
      orderBy: 'seq',
    );
    return [for (final r in rows) TrackPoint.fromJson(jsonDecode(r['data']! as String) as Map<String, dynamic>)];
  }

  @override
  Future<void> deleteTrack(String trackId) async {
    await (await _open).transaction((tx) async {
      await tx.delete('tracks', where: 'id = ?', whereArgs: [trackId]);
      await tx.delete('points', where: 'track_id = ?', whereArgs: [trackId]);
    });
  }

  static RecordedTrack _track(Map<String, Object?> row) =>
      RecordedTrack.fromJson(jsonDecode(row['data']! as String) as Map<String, dynamic>);
}
