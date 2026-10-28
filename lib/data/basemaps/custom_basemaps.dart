import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/map/offline_regions.dart';

// Custom basemaps (useCustomBasemapStore.ts): maps an Enterprise account uploaded on the web
// (GeoTIFF / PDF turned into a PNG with its bounds), from table custom_basemaps and the
// private storage bucket custom-basemaps. The app shows them on the map and keeps the
// picture on the phone, so a basemap still shows without signal. Uploading stays on the web.

const basemapStorageLimit = 5 * 1024 * 1024; // the web's quota per account

class CustomBasemap {
  const CustomBasemap({
    required this.id,
    required this.name,
    required this.filePath,
    required this.fileSize,
    this.bounds,
    required this.active,
  });

  factory CustomBasemap.fromRow(Map<String, dynamic> r) => CustomBasemap(
    id: '${r['id']}',
    name: '${r['name'] ?? ''}',
    filePath: '${r['file_path']}',
    fileSize: (r['file_size'] as num? ?? 0).toInt(),
    bounds: r['bounds'] is Map ? OfflineBounds.fromJson(Map<String, dynamic>.from(r['bounds'] as Map)) : null,
    active: r['is_active'] == true,
  );

  final String id;
  final String name;
  final String filePath; // in the storage bucket
  final int fileSize; // bytes
  final OfflineBounds? bounds; // where the picture goes; null = cannot be placed
  final bool active;

  CustomBasemap withActive(bool v) =>
      CustomBasemap(id: id, name: name, filePath: filePath, fileSize: fileSize, bounds: bounds, active: v);
}

abstract interface class BasemapBackend {
  Future<List<CustomBasemap>> list(String userId);
  Future<void> setActive(String id, bool active);
  Future<void> delete(CustomBasemap b);
  Future<Uint8List> download(String filePath);
}

class SupabaseBasemapBackend implements BasemapBackend {
  SupabaseBasemapBackend(this.client);

  final SupabaseClient client;

  @override
  Future<List<CustomBasemap>> list(String userId) async {
    final rows = await client
        .from('custom_basemaps')
        .select()
        .eq('user_id', userId)
        .order('created_at', ascending: false);
    return rows.map(CustomBasemap.fromRow).toList();
  }

  @override
  Future<void> setActive(String id, bool active) =>
      client.from('custom_basemaps').update({'is_active': active}).eq('id', id);

  /// The record first, then the file (a leftover file is only storage, not a broken map)
  @override
  Future<void> delete(CustomBasemap b) async {
    await client.from('custom_basemaps').delete().eq('id', b.id);
    try {
      await client.storage.from('custom-basemaps').remove([b.filePath]);
    } on Object {
      // Orphan file; the web reports it the same way
    }
  }

  @override
  Future<Uint8List> download(String filePath) => client.storage.from('custom-basemaps').download(filePath);
}

/// Basemap pictures on the phone, in the app's support folder
abstract interface class BasemapFiles {
  /// The file of a basemap when it is on the phone
  Future<File?> get(String id);
  Future<File> save(String id, Uint8List bytes);
  Future<void> remove(String id);
}

class DiskBasemapFiles implements BasemapFiles {
  Future<Directory> get _dir async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'basemaps'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String id) async => File(p.join((await _dir).path, '$id.png'));

  @override
  Future<File?> get(String id) async {
    final f = await _file(id);
    return await f.exists() ? f : null;
  }

  @override
  Future<File> save(String id, Uint8List bytes) async => (await _file(id)).writeAsBytes(bytes, flush: true);

  @override
  Future<void> remove(String id) async {
    final f = await _file(id);
    if (await f.exists()) await f.delete();
  }
}
