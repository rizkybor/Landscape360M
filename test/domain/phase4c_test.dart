import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/route/route_planner.dart';
import 'package:landscape360/domain/search/place_search.dart';
import 'package:landscape360/domain/weather/bmkg.dart';

// Route planner, BMKG weather and location search, same rules as the web

void main() {
  group('route planner', () {
    test('Directions request matches the web for each mode', () {
      const a = (lng: 106.8, lat: -6.2), b = (lng: 106.9, lat: -6.3);
      final toll = directionsUrl(token: 'pk.x', mode: RouteMode.drivingToll, start: a, end: b);
      expect(toll.path, '/directions/v5/mapbox/driving/106.8,-6.2;106.9,-6.3');
      expect(toll.queryParameters, {
        'geometries': 'geojson',
        'overview': 'full',
        'alternatives': 'false',
        'steps': 'false',
        'access_token': 'pk.x',
      });
      expect(
        directionsUrl(token: 'pk.x', mode: RouteMode.drivingNoToll, start: a, end: b).queryParameters['exclude'],
        'toll',
      );
      expect(
        directionsUrl(token: 'pk.x', mode: RouteMode.walking, start: a, end: b).path,
        startsWith('/directions/v5/mapbox/walking/'),
      );
    });

    test('reads the first route, or says none was found', () {
      final r = parseDirections({
        'routes': [
          {
            'distance': 12345.6,
            'duration': 3900,
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                [106.8, -6.2],
                [106.85, -6.25],
                [106.9, -6.3],
              ],
            },
          },
        ],
      });
      expect(r.coordinates, hasLength(3));
      expect((r.distanceM, r.durationS), (12345.6, 3900.0));
      expect(() => parseDirections({'routes': <Object>[]}), throwsA(isA<RouteException>()));
      expect(() => parseDirections({'message': 'Not Authorized'}), throwsA(isA<RouteException>()));
    });

    test('formats distance, duration and points like the web', () {
      expect(formatRouteKm(12345.6), '12.35');
      expect(formatRouteDuration(3900), '1 h 5 min');
      expect(formatRouteDuration(1500), '25 min');
      expect(formatRouteDuration(10), '1 min');
      expect(formatRoutePoint((lng: 106.8456, lat: -6.2088)), '6.2088° S, 106.8456° E');
    });

    test('taps set start, then destination, then a new route', () {
      var d = const RouteDraft();
      d = d.tap((lng: 1, lat: 1));
      expect((d.start, d.end, d.complete), ((lng: 1.0, lat: 1.0), null, false));
      d = d.tap((lng: 2, lat: 2));
      expect(d.complete, isTrue);
      expect(d.swapped().start, (lng: 2.0, lat: 2.0));
      d = d.tap((lng: 3, lat: 3));
      expect((d.start, d.end), ((lng: 3.0, lat: 3.0), null));
    });
  });

  group('BMKG weather', () {
    Map<String, dynamic> sample(String when, num t, String desc) => {
      'local_datetime': when,
      't': t,
      'hu': 80,
      'weather_desc': desc,
      'ws': 9.5,
      'wd': 'SW',
    };

    final response = {
      'lokasi': {'kotakab': 'Kota Adm. Jakarta Pusat'},
      'data': [
        {
          'lokasi': {'kotkab': 'Kota Adm. Jakarta Pusat', 'desa': 'Kemayoran'},
          'cuaca': [
            [
              sample('2026-10-28 07:00:00', 26, 'Cerah'),
              sample('2026-10-28 13:00:00', 32, 'Berawan'),
              sample('2026-10-28 19:00:00', 28, 'Hujan Ringan'),
            ],
            [sample('2026-10-29 07:00:00', 25, 'Kabut'), sample('2026-10-29 13:00:00', 33, 'Hujan Petir')],
            [sample('2026-10-30 13:00:00', 31, 'Cerah Berawan')],
            [sample('2026-10-31 13:00:00', 30, 'Cerah')],
          ],
        },
      ],
    };

    test('picks the forecast hour nearest to now and the next 3 days', () {
      final r = parseBmkg(response, DateTime(2026, 10, 28, 14, 10));
      expect((r.location, r.region), ('Kemayoran', 'Kota Adm. Jakarta Pusat')); // desa first, city below
      expect((r.current.temperature, r.current.description), (32.0, 'Berawan'));
      expect(r.days.map((d) => d.date), ['2026-10-28', '2026-10-29', '2026-10-30']);
      expect((r.days[0].dayName, r.days[0].dayShort), ('Rabu', 'Rab'));
      expect((r.days[0].min, r.days[0].max), (26.0, 32.0));
      expect(r.days[0].description, 'Berawan'); // middle sample of the day, like the web
      expect(r.days[1].description, 'Hujan Petir');
    });

    test('place name from "kotkab" (BMKG\'s field), else the fallback', () {
      expect(
        parseBmkg({
          'data': [
            {
              'lokasi': <String, Object>{},
              'cuaca': [
                [sample('2026-10-28 13:00:00', 30, 'Cerah')],
              ],
            },
          ],
        }, DateTime(2026, 10, 28)).location,
        'Jakarta Pusat',
      );
    });

    test('icons follow the BMKG description', () {
      expect(['Cerah', 'Berawan Tebal', 'Kabut', 'Hujan Sedang', 'Hujan Petir', '???'].map(weatherKind), [
        WeatherKind.sun,
        WeatherKind.cloud,
        WeatherKind.fog,
        WeatherKind.rain,
        WeatherKind.storm,
        WeatherKind.cloud,
      ]);
    });

    test('empty or broken responses are an error, the URL is the web one', () {
      expect(() => parseBmkg({'data': <Object>[]}, DateTime.now()), throwsA(isA<WeatherException>()));
      expect(() => parseBmkg('oops', DateTime.now()), throwsA(isA<WeatherException>()));
      expect(bmkgForecastUrl().toString(), 'https://api.bmkg.go.id/publik/prakiraan-cuaca?adm4=31.71.03.1001');
    });
  });

  group('location search', () {
    const pois = [
      PointOfInterest(
        id: 'a',
        name: 'Gunung Gede',
        subtitle: '2.958 mdpl',
        category: 'mountain',
        lng: 106.98,
        lat: -6.79,
      ),
      PointOfInterest(id: 'b', name: 'Mata Air Gede', category: 'water', lng: 106.97, lat: -6.78),
      PointOfInterest(id: 'c', name: 'BC Gede Cibodas', category: 'basecamp', lng: 107, lat: -6.74),
    ];

    test('coordinates "lat, lon" are recognised and searched as lon,lat without country filter', () {
      expect(parseCoordinateQuery('-6.77, 106.98'), (lat: -6.77, lng: 106.98));
      expect(parseCoordinateQuery('95, 10'), isNull);
      expect(parseCoordinateQuery('Gede'), isNull);
      final url = geocodingUrl(query: '-6.77, 106.98', token: 'pk.x');
      expect(url.pathSegments.last, '106.98,-6.77.json');
      expect(url.toString(), isNot(contains('%25'))); // encoded once
      expect(url.queryParameters.containsKey('country'), isFalse);
      expect(url.queryParameters['proximity'], 'ip');
    });

    test('text search: Indonesian, in Indonesia, near the user', () {
      final url = geocodingUrl(query: 'gede', token: 'pk.x', near: (lng: 106.8, lat: -6.2));
      expect(url.queryParameters['language'], 'id');
      expect(url.queryParameters['country'], 'id');
      expect(url.queryParameters['limit'], '10');
      expect(url.queryParameters['proximity'], '106.8,-6.2');
      expect(geocodingUrl(query: 'Jl. A/B', token: 'pk.x').path, '/geocoding/v5/mapbox.places/Jl.%20A%2FB.json');
      expect(isSearchable('ge'), isFalse);
      expect(isSearchable('ged'), isTrue);
    });

    test('verified points match by name, skip water, and come first without duplicates', () {
      final verified = searchPois(pois, 'GEDE');
      expect(verified.map((r) => r.title), ['Gunung Gede', 'BC Gede Cibodas']);
      expect(verified.map((r) => r.kind), [ResultKind.mountain, ResultKind.basecamp]);
      expect(verified.first.subtitle, '2.958 mdpl');
      final places = parseGeocoding({
        'features': [
          {
            'id': 'place.1',
            'place_name': 'Cibodas, Cianjur, Jawa Barat, Indonesia',
            'text': 'Cibodas',
            'center': [107.0, -6.74],
            'place_type': ['locality'],
          },
          {
            'id': 'a',
            'place_name': 'Duplicate',
            'center': [1, 1],
            'place_type': ['poi'],
          },
        ],
      });
      expect(places.first.title, 'Cibodas');
      expect(places.first.subtitle, 'Cianjur, Jawa Barat, Indonesia');
      final merged = mergeResults(verified, places);
      expect(merged.map((r) => r.id), ['a', 'c', 'place.1']);
    });

    test('bundled points get the web\'s categories', () {
      final p = PointOfInterest.fromBundled({
        'id': '7',
        'place_name': 'Gunung Salak',
        'text': '-',
        'center': [106.73, -6.72],
      });
      expect((p.id, p.category, p.subtitle), ('bundled-7', 'mountain', null));
      expect(guessPoiCategory('Mata Air Kandang Badak'), 'water');
      expect(guessPoiCategory('Pos 1', 'Pos tiket'), 'basecamp');
    });
  });
}
