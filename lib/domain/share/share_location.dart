import '../survey/survey_utils.dart';
import '../util/js_compat.dart';

// Port of src/lib/shareLocation.ts. Share Location sends where you are right now (one
// point, not live) with a link that opens Landscape 360 there: https://…/?at=lat,lng

const siteUrl = 'https://landscape360.jcdigital.co.id';

typedef SharedPoint = ({double lat, double lng});

class LocationFix {
  const LocationFix({required this.lat, required this.lng, this.elevation, this.accuracy, required this.time});

  final double lat;
  final double lng;
  final double? elevation; // meters
  final double? accuracy; // meters
  final int time; // ms since epoch
}

String _fixed5(double v) => v.toStringAsFixed(5);

/// Link that opens the map at a point
String sharedLocationUrl(double lat, double lng, [String base = siteUrl]) =>
    '$base/?at=${_fixed5(lat)},${_fixed5(lng)}';

/// The point in a "?at=lat,lng" query, or null when there is none or it is not valid
SharedPoint? parseSharedPoint(String search) {
  final at = queryParam(search, 'at');
  if (at == null || at.isEmpty) return null;
  final parts = at.split(',');
  final lat = jsNumber(parts[0]);
  final lng = parts.length > 1 ? jsNumber(parts[1]) : double.nan;
  if (!lat.isFinite || !lng.isFinite) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  return (lat: lat, lng: lng);
}

/// Message text: readable in a chat, with a Google Maps and a Landscape 360 link
String buildShareLocationText(LocationFix fix, [String name = '']) {
  final who = name.trim();
  final details = [
    if (fix.elevation != null) '${jsRoundStr(fix.elevation!)} mdpl',
    if (fix.accuracy != null) '±${jsRoundStr(fix.accuracy!)} m',
    formatDayTime(fix.time),
  ];
  return [
    who.isNotEmpty ? "📍 Lokasi $who / $who's location" : '📍 Lokasi saya / My location',
    '${toDMS(fix.lat, isLat: true)} ${toDMS(fix.lng, isLat: false)}',
    '${_fixed5(fix.lat)}, ${_fixed5(fix.lng)}',
    details.join(' · '),
    'Google Maps: https://maps.google.com/?q=${_fixed5(fix.lat)},${_fixed5(fix.lng)}',
    'Landscape 360: ${sharedLocationUrl(fix.lat, fix.lng)}',
  ].join('\n');
}

final _token = RegExp(r'^[0-9a-f]{32}$');

/// Link to a shared marked location: /?place=<32-character token>
String placeLinkUrl(String token, [String base = siteUrl]) => '$base/?place=$token';

/// The token in a "?place=" query, or null
String? parsePlaceToken(String search) {
  final token = queryParam(search, 'place');
  return token != null && _token.hasMatch(token) ? token : null;
}

String buildPlaceShareText({
  required String name,
  required String categoryLabel,
  required double lat,
  required double lng,
  required double? elevationM,
  required String url,
}) => [
  '📍 $name ($categoryLabel)',
  '${toDMS(lat, isLat: true)} ${toDMS(lng, isLat: false)}',
  if (elevationM != null) '${jsRoundStr(elevationM)} mdpl',
  'Open on Landscape 360 (no sign-in needed): $url',
].join('\n');

/// Link to a shared marked area: /?area=<32-character token>
String areaLinkUrl(String token, [String base = siteUrl]) => '$base/?area=$token';

/// The token in a "?area=" query, or null
String? parseAreaToken(String search) {
  final token = queryParam(search, 'area');
  return token != null && _token.hasMatch(token) ? token : null;
}

String buildAreaShareText({
  required String name,
  required String size,
  required String perimeter,
  required String url,
}) => ['🗺️ $name', 'Area $size · perimeter $perimeter', 'Open on Landscape 360 (no sign-in needed): $url'].join('\n');

/// Link to a shared Classic Field Work: /?classic=<32-character token>
String classicLinkUrl(String token, [String base = siteUrl]) => '$base/?classic=$token';

/// The token in a "?classic=" query, or null
String? parseClassicToken(String search) {
  final token = queryParam(search, 'classic');
  return token != null && _token.hasMatch(token) ? token : null;
}

/// The WhatsApp message for a shared Field Work (ClassicPanel.tsx)
String buildClassicShareText({required String name, required String mode, required String url}) =>
    '🧭 $name (${mode[0].toUpperCase()}${mode.substring(1)} practice)\nOpen on Landscape 360 (no sign-in needed): $url';

/// WhatsApp with the message filled in (the user picks the chat)
String whatsappShareUrl(String text) => 'https://wa.me/?text=${Uri.encodeComponent(text)}';

/// What an incoming link (universal link / app link) asks the app to open
sealed class IncomingLink {
  const IncomingLink();

  /// Reads a link to the Landscape 360 site; null when it is not one of the share links.
  /// Only links to [siteUrl]'s host are accepted.
  static IncomingLink? parse(Uri uri, {String host = 'landscape360.jcdigital.co.id'}) {
    if (uri.scheme != 'https' || uri.host != host) return null;
    if (uri.path.isNotEmpty && uri.path != '/') return null;
    final search = uri.query;
    final classic = parseClassicToken(search);
    if (classic != null) return ClassicLink(classic);
    final area = parseAreaToken(search);
    if (area != null) return AreaLink(area);
    final place = parsePlaceToken(search);
    if (place != null) return PlaceLink(place);
    final point = parseSharedPoint(search);
    if (point != null) return PointLink(point);
    return null;
  }
}

class PointLink extends IncomingLink {
  const PointLink(this.point);
  final SharedPoint point;
}

class PlaceLink extends IncomingLink {
  const PlaceLink(this.token);
  final String token;
}

class ClassicLink extends IncomingLink {
  const ClassicLink(this.token);
  final String token;
}

class AreaLink extends IncomingLink {
  const AreaLink(this.token);
  final String token;
}
