// Contours uploaded to a Marked Area on the website (table marked_area_contours,
// 20261030000021; AreaContourLines.tsx and contourGeo.ts on the web). The app shows them;
// downloading and uploading stay on the website.

/// Interval of the thicker, labelled index lines (indexIntervalFor in contourGeo.ts)
double indexIntervalFor(double interval) {
  if (interval == 12.5) return 50;
  if (interval == 25) return 100;
  if (interval == 50) return 200;
  if (interval == 125) return 500;
  return interval * (interval == 5 || interval == 10 || interval == 100 ? 5 : 4);
}

/// isIndexLine in contourGeo.ts (JS % keeps the sign, like Dart's remainder)
bool isIndexLine(double? elevation, double? interval) =>
    elevation != null && interval != null && elevation.remainder(indexIntervalFor(interval)).abs() < 1e-6;

/// Which of my areas have contours, without the lines (the AreaContourMeta of the web)
class AreaContourMeta {
  const AreaContourMeta({
    required this.areaId,
    required this.sourceName,
    required this.sourceFormat,
    this.intervalM,
    required this.lineCount,
    this.minElevation,
    this.maxElevation,
  });

  factory AreaContourMeta.fromRow(Map<String, dynamic> r) {
    double? n(String k) => (r[k] as num?)?.toDouble();
    return AreaContourMeta(
      areaId: '${r['area_id']}',
      sourceName: '${r['source_name'] ?? ''}',
      sourceFormat: '${r['source_format'] ?? ''}',
      intervalM: n('interval_m'),
      lineCount: (r['line_count'] as num? ?? 0).toInt(),
      minElevation: n('min_elevation'),
      maxElevation: n('max_elevation'),
    );
  }

  final String areaId;
  final String sourceName;
  final String sourceFormat; // shp, geotiff, geojson, kml or kmz
  final double? intervalM;
  final int lineCount;
  final double? minElevation;
  final double? maxElevation;
}

/// A set of contour lines (a GeoJSON FeatureCollection of LineStrings with "elevation") and
/// the interval it was made at, when known
typedef ContourSet = ({Map<String, dynamic> data, double? intervalM});

/// One collection for the map: every line keeps its elevation and says whether it is an
/// index line (without a known interval every line is drawn as one, like the web)
Map<String, Object> contourLinesGeoJson(Iterable<ContourSet> sets) => {
  'type': 'FeatureCollection',
  'features': [
    for (final s in sets)
      for (final f in (s.data['features'] as List? ?? const []).whereType<Map<dynamic, dynamic>>())
        if ((f['geometry'] as Map?)?['type'] == 'LineString')
          {
            'type': 'Feature',
            'geometry': f['geometry'] as Object,
            'properties': {
              'elevation': ((f['properties'] as Map?)?['elevation'] as num?)?.toDouble(),
              'index':
                  s.intervalM == null ||
                  isIndexLine(((f['properties'] as Map?)?['elevation'] as num?)?.toDouble(), s.intervalM),
            },
          },
  ],
};
