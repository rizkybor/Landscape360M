import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import '../../domain/geo/spherical.dart';

// Heights above sea level at points, from the open AWS Terrain Tiles (SRTM, ~30 m over
// Indonesia): the same tiles and maths as the web (terrainDem.ts sampleElevations), so a profile
// reads the same in the app and on the website, in 2D or 3D. Tiles are 256 px Web Mercator PNGs
// in "terrarium" encoding; heights are interpolated between the four nearest pixels.

abstract interface class ElevationSampler {
  /// One height per point; NaN where there is no data (open sea)
  Future<List<double>> sample(List<LngLat> points);
}

class ElevationException implements Exception {
  const ElevationException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Terrarium encoding: height = R * 256 + G + B / 256 - 32768
double decodeTerrarium(int r, int g, int b) => r * 256 + g + b / 256 - 32768;

const _tile = 256;

double _mercX(double lng, int z) => (lng + 180) / 360 * math.pow(2, z) * _tile;

double _mercY(double lat, int z) {
  final r = lat * math.pi / 180;
  return (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * math.pow(2, z) * _tile;
}

class TerrariumSampler implements ElevationSampler {
  TerrariumSampler({http.Client? client, this.zoom = 13}) : _client = client ?? http.Client();

  final http.Client _client;
  final int zoom;

  static const _concurrency = 6;
  static const _maxTiles = 400;

  static Uri tileUrl(int z, int x, int y) =>
      Uri.parse('https://s3.amazonaws.com/elevation-tiles-prod/terrarium/$z/$x/$y.png');

  /// Heights of one tile, row by row; NaN where it has no data; null for no tile (open sea)
  Future<Float32List?> _load(int x, int y) async {
    final res = await _client.get(tileUrl(zoom, x, y)).timeout(const Duration(seconds: 20));
    if (res.statusCode == 404 || res.statusCode == 403) return null;
    if (res.statusCode != 200) throw ElevationException('Elevation data is not available now (${res.statusCode}).');
    return heightsFromPng(res.bodyBytes);
  }

  /// The RGB values are data, not colours: decoded straight (no premultiplied alpha)
  static Future<Float32List> heightsFromPng(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    final w = frame.image.width, h = frame.image.height;
    frame.image.dispose();
    codec.dispose();
    if (data == null) throw const ElevationException('Could not read the elevation data.');
    final px = data.buffer.asUint8List();
    final out = Float32List(_tile * _tile)..fillRange(0, _tile * _tile, double.nan);
    for (var row = 0; row < math.min(h, _tile); row++) {
      for (var col = 0; col < math.min(w, _tile); col++) {
        final i = (row * w + col) * 4;
        final v = decodeTerrarium(px[i], px[i + 1], px[i + 2]);
        out[row * _tile + col] = v < -12000 ? double.nan : v;
      }
    }
    return out;
  }

  @override
  Future<List<double>> sample(List<LngLat> points) async {
    final px = [for (final p in points) (_mercX(p.$1, zoom), _mercY(p.$2, zoom))];
    final needed = <(int, int)>{};
    for (final (x, y) in px) {
      for (final gx in [x.floor(), x.floor() + 1]) {
        for (final gy in [y.floor(), y.floor() + 1]) {
          needed.add((gx ~/ _tile, gy ~/ _tile));
        }
      }
    }
    if (needed.length > _maxTiles) throw const ElevationException('This line is too long for an elevation profile.');
    final keys = needed.toList();
    final tiles = <(int, int), Float32List?>{};
    var next = 0;
    Future<void> worker() async {
      while (next < keys.length) {
        final k = keys[next++];
        tiles[k] = await _load(k.$1, k.$2);
      }
    }

    try {
      await Future.wait([for (var i = 0; i < math.min(_concurrency, keys.length); i++) worker()]);
    } on ElevationException {
      rethrow;
    } on Object {
      throw const ElevationException('No signal: elevation data needs the internet.');
    }
    double at(int gx, int gy) {
      final tx = gx ~/ _tile, ty = gy ~/ _tile;
      final h = tiles[(tx, ty)];
      return h == null ? double.nan : h[(gy - ty * _tile) * _tile + (gx - tx * _tile)];
    }

    return [
      for (final (x, y) in px)
        () {
          final x0 = x.floor(), y0 = y.floor();
          final fx = x - x0, fy = y - y0;
          final top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx;
          final bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx;
          return top * (1 - fy) + bottom * fy;
        }(),
    ];
  }
}
