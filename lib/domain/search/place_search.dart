// Location search, port of src/components/SearchPanel.tsx and src/lib/pointsOfInterest.ts
// (web): the app's verified points of interest first, then Mapbox Geocoding.

const poiCategories = ['poi', 'mountain', 'basecamp', 'water', 'river', 'cliff', 'cave'];

class PointOfInterest {
  const PointOfInterest({
    required this.id,
    required this.name,
    required this.category,
    required this.lng,
    required this.lat,
    this.subtitle,
    this.description,
  });

  /// Row of points_of_interest (20261024000012)
  factory PointOfInterest.fromRow(Map<String, dynamic> r) => PointOfInterest(
    id: '${r['id']}',
    name: '${r['name'] ?? ''}',
    subtitle: r['subtitle'] as String?,
    description: r['description'] as String?,
    category: poiCategories.contains(r['category']) ? r['category'] as String : 'poi',
    lng: (r['lng'] as num?)?.toDouble() ?? double.tryParse('${r['lng']}') ?? 0,
    lat: (r['lat'] as num?)?.toDouble() ?? double.tryParse('${r['lat']}') ?? 0,
  );

  /// Entry of the bundled list shipped with the web (src/data/myDataLocation.json)
  factory PointOfInterest.fromBundled(Map<String, dynamic> l) {
    final center = (l['center'] as List).cast<num>();
    final text = l['text'] as String?;
    final name = '${l['place_name'] ?? ''}';
    final properties = l['properties'];
    return PointOfInterest(
      id: 'bundled-${l['id']}',
      name: name,
      subtitle: text != null && text != '-' ? text : null,
      description: properties is Map ? properties['wikidata'] as String? : null,
      category: guessPoiCategory(name, text ?? '', l['type'] as String? ?? ''),
      lng: center[0].toDouble(),
      lat: center[1].toDouble(),
    );
  }

  Map<String, dynamic> toRow() => {
    'id': id,
    'name': name,
    'subtitle': subtitle,
    'description': description,
    'category': category,
    'lng': lng,
    'lat': lat,
  };

  final String id;
  final String name;
  final String? subtitle; // e.g. "2.958 mdpl"
  final String? description;
  final String category;
  final double lng;
  final double lat;
}

/// Same rules as the web (and the seed in the migration) for the bundled list
String guessPoiCategory(String name, [String subtitle = '', String type = '']) {
  final n = name.toLowerCase();
  if (type.toLowerCase() == 'water' || n.startsWith('mata air')) return 'water';
  if (n.startsWith('bc ') || n.contains('basecamp') || subtitle.toLowerCase().contains('pos tiket')) return 'basecamp';
  if (n.startsWith('sungai')) return 'river';
  if (n.startsWith('tebing')) return 'cliff';
  if (n.startsWith('gua')) return 'cave';
  if (n.startsWith('gunung')) return 'mountain';
  return 'poi';
}

enum ResultKind { mountain, basecamp, poi, place }

class SearchResult {
  const SearchResult({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.lng,
    required this.lat,
    required this.kind,
    required this.verified,
  });

  final String id;
  final String title;
  final String subtitle;
  final double lng;
  final double lat;
  final ResultKind kind;
  final bool verified; // one of the app's own points of interest
}

final _coordinate = RegExp(r'^(-?\d+(\.\d+)?),\s*(-?\d+(\.\d+)?)$');

/// "lat, lon" typed in the search box, or null
({double lat, double lng})? parseCoordinateQuery(String query) {
  final m = _coordinate.firstMatch(query.trim());
  if (m == null) return null;
  final lat = double.parse(m[1]!), lng = double.parse(m[3]!);
  if (lat.abs() > 90 || lng.abs() > 180) return null;
  return (lat: lat, lng: lng);
}

/// Searches start from 3 characters (the web's rule)
bool isSearchable(String query) => query.length > 2;

/// Mapbox Geocoding request with the web's parameters: Indonesian, inside Indonesia, near
/// the user (or the IP location without a fix)
Uri geocodingUrl({required String query, required String token, ({double lng, double lat})? near}) {
  final coordinate = parseCoordinateQuery(query);
  final text = coordinate == null ? query : '${coordinate.lng},${coordinate.lat}';
  // Built from segments so the text is encoded once, "/" included
  return Uri(
    scheme: 'https',
    host: 'api.mapbox.com',
    pathSegments: ['geocoding', 'v5', 'mapbox.places', '$text.json'],
    queryParameters: {
      'access_token': token,
      'limit': '10',
      'language': 'id',
      if (coordinate == null) 'country': 'id',
      if (coordinate == null) 'types': 'country,region,district,place,locality,neighborhood,address,poi',
      'proximity': near == null ? 'ip' : '${near.lng},${near.lat}',
    },
  );
}

ResultKind _kind(List<String> types) {
  if (types.contains('mountain')) return ResultKind.mountain;
  if (types.contains('basecamp')) return ResultKind.basecamp;
  if (types.contains('poi')) return ResultKind.poi;
  return ResultKind.place;
}

/// Places from a Geocoding response: title is the first part of place_name, the rest below
List<SearchResult> parseGeocoding(Object? json) {
  final features = json is Map ? json['features'] : null;
  if (features is! List) return const [];
  return [
    for (final f in features)
      if (f is Map && f['center'] is List && (f['center'] as List).length >= 2)
        () {
          final name = '${f['place_name'] ?? f['text'] ?? ''}';
          final parts = name.split(',');
          final center = (f['center'] as List).cast<num>();
          final types = (f['place_type'] as List? ?? const []).map((t) => '$t').toList();
          return SearchResult(
            id: '${f['id'] ?? '${center[0]},${center[1]}'}',
            title: parts.first.trim(),
            subtitle: parts.skip(1).join(',').trim().isEmpty ? '${f['text'] ?? ''}' : parts.skip(1).join(',').trim(),
            lng: center[0].toDouble(),
            lat: center[1].toDouble(),
            kind: _kind(types),
            verified: false,
          );
        }(),
  ];
}

/// The app's points matching the text (case-insensitive), leaving water sources out
List<SearchResult> searchPois(List<PointOfInterest> pois, String query) {
  if (parseCoordinateQuery(query) != null) return const [];
  final q = query.toLowerCase();
  return [
    for (final p in pois)
      if (p.name.toLowerCase().contains(q) && p.category != 'water')
        SearchResult(
          id: p.id,
          title: p.name,
          subtitle: p.subtitle ?? '',
          lng: p.lng,
          lat: p.lat,
          kind: _kind(['poi', p.category]),
          verified: true,
        ),
  ];
}

/// Verified points first, then places, without the same id or position twice
List<SearchResult> mergeResults(List<SearchResult> verified, List<SearchResult> places) {
  final seen = <String>{};
  return [
    for (final r in [...verified, ...places])
      if (seen.add(r.id.isNotEmpty ? r.id : '${r.lng},${r.lat}')) r,
  ];
}
