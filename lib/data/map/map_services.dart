import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter/foundation.dart' show compute;

import 'package:flutter/services.dart' show rootBundle, Uint8List;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/route/route_planner.dart';
import '../../domain/search/place_search.dart';
import '../../domain/weather/bmkg.dart';
import '../../domain/weather/villages.dart';

// Network services of the map tools: BMKG weather, Mapbox Geocoding and Directions, and
// the app's points of interest. The Mapbox token is the public (pk.) one the map uses.

const _timeout = Duration(seconds: 15);

Future<Object?> _getJson(http.Client client, Uri url) async {
  final res = await client.get(url).timeout(_timeout);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw http.ClientException('HTTP ${res.statusCode}', url);
  }
  return jsonDecode(res.body);
}

class WeatherService {
  WeatherService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Forecast of one village (ADM4 code); Kemayoran when none is given
  Future<WeatherReport> forecast({String adm4 = bmkgDefaultAdm4, DateTime? now}) async {
    try {
      return parseBmkg(await _getJson(_client, bmkgForecastUrl(adm4)), now ?? DateTime.now());
    } on WeatherException {
      rethrow;
    } on Object {
      throw const WeatherException('Gagal memuat data cuaca.');
    }
  }
}

class GeocodingService {
  GeocodingService({required this.token, http.Client? client}) : _client = client ?? http.Client();

  final String token;
  final http.Client _client;

  Future<List<SearchResult>> search(String query, {({double lng, double lat})? near}) async =>
      parseGeocoding(await _getJson(_client, geocodingUrl(query: query, token: token, near: near)));
}

class DirectionsService {
  DirectionsService({required this.token, http.Client? client}) : _client = client ?? http.Client();

  final String token;
  final http.Client _client;

  Future<RouteResult> route({required RouteMode mode, required RoutePoint start, required RoutePoint end}) async {
    if (token.isEmpty) throw const RouteException('Mapbox token belum dikonfigurasi.');
    final res = await _client.get(directionsUrl(token: token, mode: mode, start: start, end: end)).timeout(_timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw RouteException('Directions API error (${res.statusCode})');
    }
    return parseDirections(jsonDecode(res.body));
  }
}

/// Published points of interest: the last list seen (works offline), refreshed from the
/// server, the list bundled with the app before either exists (like usePoiStore on the web)
class PoiRepository {
  PoiRepository({required this.client, SharedPreferencesAsync? prefs}) : _prefs = prefs ?? SharedPreferencesAsync();

  final SupabaseClient? client;
  final SharedPreferencesAsync _prefs;
  static const _cacheKey = 'l360-points-of-interest';

  Future<List<PointOfInterest>> cachedOrBundled() async {
    try {
      final raw = await _prefs.getString(_cacheKey);
      if (raw != null) {
        return (jsonDecode(raw) as List).cast<Map<String, dynamic>>().map(PointOfInterest.fromRow).toList();
      }
    } on Object {
      // Unreadable cache: fall back to the bundled list
    }
    final bundled = jsonDecode(await rootBundle.loadString('assets/data/pois_bundled.json')) as List;
    return bundled.cast<Map<String, dynamic>>().map(PointOfInterest.fromBundled).toList();
  }

  /// Fresh list from the server (and cached), or null offline / before the migration
  Future<List<PointOfInterest>?> refresh() async {
    final c = client;
    if (c == null) return null;
    try {
      final rows = await c
          .from('points_of_interest')
          .select('id, name, subtitle, description, category, lng, lat')
          .eq('is_published', true)
          .order('name');
      final list = rows.map(PointOfInterest.fromRow).toList();
      unawaited(_prefs.setString(_cacheKey, jsonEncode([for (final p in list) p.toRow()])).catchError((Object _) {}));
      return list;
    } on Object {
      return null;
    }
  }
}

/// Villages bundled with the app, decoded off the UI thread and indexed for nearest lookups
Future<VillageIndex> loadVillageIndex() async {
  final bytes = (await rootBundle.load('assets/data/villages.tsv.gz')).buffer.asUint8List();
  final villages = await compute(_decodeVillages, bytes);
  return VillageIndex(villages);
}

List<Village> _decodeVillages(Uint8List gz) => parseVillagesTsv(utf8.decode(gzip.decode(gz)));
