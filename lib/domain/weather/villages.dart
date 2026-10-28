import 'dart:math' as math;

// Every desa / kelurahan with its Kemendagri code (BMKG's ADM4) and the centre of its
// boundary (assets/data/villages.tsv.gz, built by tool/wilayah/build_villages.py from Badan
// Informasi Geospasial data). The nearest village is found on the phone, so only its code,
// never the user's position, goes to BMKG.

class Village {
  const Village({
    required this.code,
    required this.name,
    required this.kecamatan,
    required this.kabKota,
    required this.lat,
    required this.lng,
  });

  final String code; // e.g. 31.74.07.1010
  final String name; // Cipete Utara
  final String kecamatan; // Kebayoran Baru
  final String kabKota; // Kota Adm. Jakarta Selatan
  final double lat;
  final double lng;
}

/// Reads the TSV (header: code, desa, kecamatan, kabkota, lat, lon); bad lines are skipped
List<Village> parseVillagesTsv(String tsv) {
  final villages = <Village>[];
  for (final line in tsv.split('\n').skip(1)) {
    final f = line.split('\t');
    if (f.length < 6) continue;
    final lat = double.tryParse(f[4]), lng = double.tryParse(f[5]);
    if (lat == null || lng == null || f[0].split('.').length != 4) continue;
    villages.add(Village(code: f[0], name: f[1], kecamatan: f[2], kabKota: f[3], lat: lat, lng: lng));
  }
  return villages;
}

/// Nearest-village lookup over a grid of 0.1° cells
class VillageIndex {
  VillageIndex(List<Village> villages) : _all = villages {
    for (var i = 0; i < villages.length; i++) {
      _cells.putIfAbsent(_cell(villages[i].lat, villages[i].lng), () => []).add(i);
    }
  }

  static const _cellDeg = 0.1;
  final List<Village> _all;
  final _cells = <int, List<int>>{};

  int get length => _all.length;

  static int _key(int row, int col) => row * 10000 + col;
  static int _cell(double lat, double lng) => _key(((lat + 90) / _cellDeg).floor(), ((lng + 180) / _cellDeg).floor());

  /// Approximate distance in km (equirectangular; fine at village scale)
  static double distanceKm(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final x = (lng2 - lng1) * math.pi / 180 * math.cos((lat1 + lat2) / 2 * math.pi / 180);
    final y = (lat2 - lat1) * math.pi / 180;
    return math.sqrt(x * x + y * y) * r;
  }

  /// Up to [count] villages nearest to the point, within [maxKm]; nearest first
  List<Village> nearest(double lat, double lng, {int count = 3, double maxKm = 30}) {
    final row = ((lat + 90) / _cellDeg).floor(), col = ((lng + 180) / _cellDeg).floor();
    final found = <(double, Village)>[];
    // Grow the search ring by ring until enough villages are found (or the limit is passed)
    final maxRing = (maxKm / 11).ceil() + 1;
    for (var ring = 0; ring <= maxRing; ring++) {
      for (var dr = -ring; dr <= ring; dr++) {
        for (var dc = -ring; dc <= ring; dc++) {
          if (dr.abs() != ring && dc.abs() != ring) continue; // only the new outer ring
          for (final i in _cells[_key(row + dr, col + dc)] ?? const <int>[]) {
            final v = _all[i];
            final d = distanceKm(lat, lng, v.lat, v.lng);
            if (d <= maxKm) found.add((d, v));
          }
        }
      }
      // Anything outside this ring is at least ring * ~11 km away
      if (found.length >= count && ring >= 1) {
        found.sort((a, b) => a.$1.compareTo(b.$1));
        if (found[count - 1].$1 <= ring * _cellDeg * 111 * math.cos(lat * math.pi / 180)) break;
      }
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, v) in found.take(count)) v];
  }
}
