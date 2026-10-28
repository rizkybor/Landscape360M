import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/map/map_services.dart';
import 'package:landscape360/domain/route/route_planner.dart';
import 'package:landscape360/domain/search/place_search.dart';
import 'package:landscape360/domain/weather/villages.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:landscape360/features/map/route_panel.dart';
import 'package:landscape360/features/map/search_page.dart';
import 'package:landscape360/features/map/weather_card.dart';

// Route planner, search and weather against fake servers (no real network calls)

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, Object> _route(double km) => {
  'routes': [
    {
      'distance': km * 1000,
      'duration': 1500,
      'geometry': {
        'coordinates': [
          [106.8, -6.2],
          [106.9, -6.3],
        ],
      },
    },
  ],
};

void main() {
  group('route planner', () {
    late List<Uri> requests;
    late List<Completer<http.Response>> pending;
    late ProviderContainer c;

    setUp(() {
      requests = [];
      pending = [];
      c = ProviderContainer(
        overrides: [
          directionsServiceProvider.overrideWithValue(
            DirectionsService(
              token: 'pk.test',
              client: MockClient((req) {
                requests.add(req.url);
                final done = Completer<http.Response>();
                pending.add(done);
                return done.future;
              }),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
    });

    RoutePlanner planner() => c.read(routePlannerProvider.notifier);
    RoutePlannerState state() => c.read(routePlannerProvider);

    test('taps only count while open; the second tap computes the route', () async {
      await planner().tap((lng: 1, lat: 1));
      expect(state().draft.start, isNull);
      planner().enable();
      await planner().tap((lng: 106.8, lat: -6.2));
      expect(state().nextStep, 'end');
      final computing = planner().tap((lng: 106.9, lat: -6.3));
      await Future<void>.delayed(Duration.zero);
      expect(state().loading, isTrue);
      expect(requests.single.path, contains('/driving/106.8,-6.2;106.9,-6.3'));
      pending.single.complete(_json(_route(12.3)));
      await computing;
      expect((state().loading, state().result?.distanceM), (false, 12300.0));
    });

    test('changing the mode recomputes; an older answer never replaces a newer one', () async {
      planner().enable();
      await planner().tap((lng: 106.8, lat: -6.2));
      final first = planner().tap((lng: 106.9, lat: -6.3));
      await Future<void>.delayed(Duration.zero);
      final second = planner().setMode(RouteMode.walking);
      await Future<void>.delayed(Duration.zero);
      expect(requests.last.path, contains('/walking/'));
      pending[1].complete(_json(_route(5)));
      await second;
      pending[0].complete(_json(_route(99)));
      await first;
      expect(state().result?.distanceM, 5000); // the walking route, not the stale driving one
    });

    test('errors are shown; clear and close reset the route', () async {
      planner().enable();
      await planner().tap((lng: 106.8, lat: -6.2));
      final f = planner().tap((lng: 106.9, lat: -6.3));
      await Future<void>.delayed(Duration.zero);
      pending.single.complete(_json({'message': 'Not Authorized - Invalid Token'}, 401));
      await f;
      expect(state().error, 'Directions API error (401)');
      planner().clear();
      expect((state().enabled, state().draft.start, state().error), (true, null, null));
      planner().disable();
      expect(state().enabled, isFalse);
    });
  });

  testWidgets('route panel shows the steps, the result and the travel modes', (tester) async {
    final c = ProviderContainer(
      overrides: [
        directionsServiceProvider.overrideWithValue(
          DirectionsService(token: 'pk.test', client: MockClient((_) async => _json(_route(12.3)))),
        ),
      ],
    );
    addTearDown(c.dispose);
    c.read(routePlannerProvider.notifier).enable();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const Scaffold(body: RoutePanel()),
        ),
      ),
    );
    expect(find.text('Tap on the map to set this point'), findsOneWidget);
    expect(find.text('Waiting for start point'), findsOneWidget);
    await c.read(routePlannerProvider.notifier).tap((lng: 106.8456, lat: -6.2088));
    await c.read(routePlannerProvider.notifier).tap((lng: 106.9, lat: -6.3));
    await tester.pumpAndSettle();
    expect(find.text('6.2088° S, 106.8456° E'), findsOneWidget);
    expect(find.textContaining('12.30 km', findRichText: true), findsOneWidget);
    expect(find.textContaining('25 min', findRichText: true), findsOneWidget);
    expect(find.text('Tap the map again to start a new route.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('route-close')));
    expect(c.read(routePlannerProvider).enabled, isFalse);
  });

  testWidgets('search: verified points first, then places; picking returns the place', (tester) async {
    SearchResult? picked;
    final queries = <Uri>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          poisProvider.overrideWith(
            () => _FixedPois(const [
              PointOfInterest(
                id: 'p1',
                name: 'Gunung Gede',
                subtitle: '2.958 mdpl',
                category: 'mountain',
                lng: 106.98,
                lat: -6.79,
              ),
            ]),
          ),
          geocodingServiceProvider.overrideWithValue(
            GeocodingService(
              token: 'pk.test',
              client: MockClient((req) async {
                queries.add(req.url);
                return _json({
                  'features': [
                    {
                      'id': 'place.1',
                      'place_name': 'Gede Bage, Bandung, Jawa Barat',
                      'center': [107.69, -6.94],
                      'place_type': ['locality'],
                    },
                  ],
                });
              }),
            ),
          ),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) =>
                TextButton(onPressed: () async => picked = await showPlaceSearch(context), child: const Text('open')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search-field')), 'ge');
    await tester.pump(const Duration(milliseconds: 600));
    expect(queries, isEmpty); // under 3 characters
    await tester.enterText(find.byKey(const Key('search-field')), 'gede');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(queries.single.queryParameters['country'], 'id');
    expect(find.text('VERIFIED LOCATIONS'), findsOneWidget);
    expect(find.text('PLACES'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Gunung Gede')).dy, lessThan(tester.getTopLeft(find.text('Gede Bage')).dy));
    await tester.tap(find.text('Gunung Gede'));
    await tester.pumpAndSettle();
    expect((picked?.lng, picked?.lat), (106.98, -6.79));
  });

  group('weather card', () {
    Map<String, Object> s(String t, num c, String d) => {
      'local_datetime': t,
      't': c,
      'hu': 78,
      'weather_desc': d,
      'ws': 10,
      'wd': 'W',
    };
    Map<String, Object> forecast(String desa, String kec, String kota) => {
      'lokasi': {'desa': desa, 'kecamatan': kec, 'kotkab': kota},
      'data': [
        {
          'lokasi': {'desa': desa, 'kecamatan': kec, 'kotkab': kota},
          'cuaca': [
            [s('2026-10-28 13:00:00', 32, 'Berawan')],
            [s('2026-10-29 13:00:00', 31, 'Hujan Ringan')],
            [s('2026-10-30 13:00:00', 30, 'Cerah')],
          ],
        },
      ],
    };
    final villages = VillageIndex(
      parseVillagesTsv(
        'code\tdesa\tkecamatan\tkabkota\tlat\tlon\n'
        '31.74.07.1010\tCipete Utara\tKebayoran Baru\tKota Adm. Jakarta Selatan\t-6.26173\t106.80436\n'
        '31.74.07.1002\tGunung\tKebayoran Baru\tKota Adm. Jakarta Selatan\t-6.23581\t106.79321\n',
      ),
    );

    Future<List<String>> pump(
      WidgetTester tester,
      http.Response Function(String adm4) reply, {
      LatLng? gps,
      LatLng? center,
    }) async {
      final asked = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            villageIndexProvider.overrideWith((ref) async => villages),
            weatherServiceProvider.overrideWithValue(
              WeatherService(
                client: MockClient((req) async {
                  final adm4 = req.url.queryParameters['adm4']!;
                  asked.add(adm4);
                  return reply(adm4);
                }),
              ),
            ),
          ],
          child: MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: WeatherCard(
                now: () => DateTime(2026, 10, 28, 13),
                locate: () async => gps,
                mapCenter: center == null ? null : () => center,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return asked;
    }

    testWidgets('forecast for the kelurahan nearest to the user', (tester) async {
      final asked = await pump(
        tester,
        (_) => _json(forecast('Cipete Utara', 'Kebayoran Baru', 'Kota Adm. Jakarta Selatan')),
        gps: (lat: -6.262, lng: 106.803),
      );
      expect(asked, ['31.74.07.1010']);
      expect(find.text('Cipete Utara, Kebayoran Baru'), findsOneWidget);
      expect(find.text('Kota Adm. Jakarta Selatan · Near your location'), findsOneWidget);
      expect(find.byKey(const Key('weather-use-location')), findsNothing);
      expect(find.text('32°C'), findsOneWidget);
      expect(find.text('Kamis'), findsOneWidget);
      expect(find.text('Sumber: BMKG · Wilayah: BIG'), findsOneWidget);
      await tester.tap(find.text('Cipete Utara, Kebayoran Baru'));
      await tester.pumpAndSettle();
      expect(find.text('32°C · Berawan'), findsOneWidget); // shrunk to a pill
    });

    testWidgets('a code BMKG does not know falls through to the next village', (tester) async {
      final asked = await pump(
        tester,
        (adm4) => adm4 == '31.74.07.1010'
            ? http.Response('not found', 404)
            : _json(forecast('Gunung', 'Kebayoran Baru', 'Kota Adm. Jakarta Selatan')),
        gps: (lat: -6.262, lng: 106.803),
      );
      expect(asked, ['31.74.07.1010', '31.74.07.1002']);
      expect(find.text('Gunung, Kebayoran Baru'), findsOneWidget);
    });

    testWidgets('without location the map centre is used', (tester) async {
      await pump(
        tester,
        (_) => _json(forecast('Gunung', 'Kebayoran Baru', 'Kota Adm. Jakarta Selatan')),
        center: (lat: -6.236, lng: 106.793),
      );
      expect(find.text('Kota Adm. Jakarta Selatan · Map centre'), findsOneWidget);
      expect(find.byKey(const Key('weather-use-location')), findsOneWidget); // a way to use the real position
    });

    testWidgets('outside Indonesia it says so and shows the default place', (tester) async {
      final asked = await pump(
        tester,
        (_) => _json(forecast('Kemayoran', 'Kemayoran', 'Kota Adm. Jakarta Pusat')),
        center: (lat: 1.35, lng: 103.82),
      );
      expect(asked, ['31.71.03.1001']);
      expect(find.textContaining('Outside BMKG coverage'), findsOneWidget);
    });

    testWidgets('says so when BMKG cannot be reached', (tester) async {
      await pump(tester, (_) => http.Response('down', 503), gps: (lat: -6.262, lng: 106.803));
      expect(find.text('Gagal memuat data cuaca.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });
}

class _FixedPois extends PoisController {
  _FixedPois(this.list);

  final List<PointOfInterest> list;

  @override
  Future<List<PointOfInterest>> build() async => list;
}
