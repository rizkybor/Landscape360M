import 'package:xml/xml.dart';

import 'track_recorder_geo.dart';

// GPX import into My Tracks, a port of parseGpx in src/utils/trackRecorderGeo.ts: the tracks
// (each <trkseg> becomes a segment), or the routes when the file has no track; the name of the
// first track or route, else of the file's metadata. Invalid points are skipped; times are kept
// in order so duration and moving time stay right.

const gpxImportMaxBytes = 20 * 1024 * 1024;
const gpxImportMaxPoints = 50000;

class GpxImportException implements Exception {
  const GpxImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

typedef ParsedGpx = ({String? name, List<TrackPoint> points});

Iterable<XmlElement> _byTag(XmlNode root, String tag) =>
    root.descendants.whereType<XmlElement>().where((e) => e.localName == tag);

String? _childText(XmlElement el, String tag) {
  for (final c in el.childElements) {
    if (c.localName == tag) {
      final t = c.innerText.trim();
      return t.isEmpty ? null : t;
    }
  }
  return null;
}

String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// Points without a <time> take the previous time (or [fallbackTime], epoch ms), so they add no
/// moving time
ParsedGpx parseGpx(String text, {required int fallbackTime}) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } on Object {
    throw const GpxImportException('This is not a valid GPX file');
  }
  if (doc.rootElement.localName != 'gpx') throw const GpxImportException('This is not a valid GPX file');

  final tracks = _byTag(doc, 'trk').toList();
  final routes = _byTag(doc, 'rte').toList();
  final segments = tracks.isNotEmpty
      ? [
          for (final trk in tracks)
            for (final seg in _byTag(trk, 'trkseg')) _byTag(seg, 'trkpt').toList(),
        ]
      : [for (final rte in routes) _byTag(rte, 'rtept').toList()];

  final raw = <({double lat, double lng, double? alt, int? time, int segment})>[];
  int? lastTime;
  var segment = 0;
  for (final els in segments) {
    var added = false;
    for (final el in els) {
      final lat = double.tryParse(el.getAttribute('lat') ?? '');
      final lng = double.tryParse(el.getAttribute('lon') ?? '');
      if (lat == null || lng == null || !lat.isFinite || !lng.isFinite) continue;
      if (lat.abs() > 90 || lng.abs() > 180) continue;
      final ele = double.tryParse(_childText(el, 'ele') ?? '');
      final parsed = DateTime.tryParse(_childText(el, 'time') ?? '')?.millisecondsSinceEpoch;
      // Out-of-order times would break duration and moving time
      final time = parsed != null && (lastTime == null || parsed >= lastTime) ? parsed : lastTime;
      if (time != null) lastTime = time;
      raw.add((lat: lat, lng: lng, alt: ele != null && ele.isFinite ? ele : null, time: time, segment: segment));
      added = true;
      if (raw.length > gpxImportMaxPoints) {
        throw GpxImportException('The GPX file has more than ${_thousands(gpxImportMaxPoints)} points');
      }
    }
    if (added) segment++;
  }
  if (raw.isEmpty) throw const GpxImportException('The GPX file has no track or route points');

  // Points before the first timed one take that time
  final firstTime = raw.firstWhere((p) => p.time != null, orElse: () => raw.first).time ?? fallbackTime;
  final points = [
    for (final p in raw)
      TrackPoint(
        lat: p.lat,
        lng: p.lng,
        alt: p.alt,
        accuracy: 0,
        speed: null,
        timestamp: p.time ?? firstTime,
        segment: p.segment,
      ),
  ];

  final first = tracks.isNotEmpty ? tracks.first : (routes.isNotEmpty ? routes.first : null);
  final metadata = _byTag(doc, 'metadata').firstOrNull;
  final name =
      (first == null ? null : _childText(first, 'name')) ?? (metadata == null ? null : _childText(metadata, 'name'));
  return (name: name, points: points);
}
