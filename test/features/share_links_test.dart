import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/marked/marked_locations.dart';
import 'package:landscape360/domain/search/place_search.dart';
import 'package:landscape360/domain/share/share_location.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:landscape360/features/map/poi_layer.dart';
import 'package:landscape360/features/map/share_location_sheet.dart';
import 'package:landscape360/features/map/shared_links.dart';

// Share links opening the app, Share Location, and points of interest on the map

const _token = '0123456789abcdef0123456789abcdef';

void main() {
  group('share links', () {
    ProviderContainer container(PlaceOpener opener) {
      final c = ProviderContainer(overrides: [placeOpenerProvider.overrideWithValue(opener)]);
      addTearDown(c.dispose);
      c
        ..listen(sharedLinkProvider, (_, _) {})
        ..listen(flyToProvider, (_, _) {});
      return c;
    }

    test('?at= shows a pin there and keeps the map from jumping to the GPS', () async {
      final c = container((_) async => null);
      final link = IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/?at=-6.74710,106.99320'))!;
      await c.read(sharedLinkProvider.notifier).open(link);
      final v = c.read(sharedLinkProvider)! as SharedPin;
      expect((v.point.lat, v.point.lng), (-6.7471, 106.9932));
      expect(c.read(flyToProvider), (lng: 106.9932, lat: -6.7471, zoom: 15.0));
      expect(c.read(sharedLinkProvider.notifier).openedFromLink, isTrue);
    });

    test('?place= opens the shared marked location without signing in', () async {
      String? asked;
      final c = container((t) async {
        asked = t;
        return const LinkedPlace(
          name: 'Mata air Kandang Badak',
          category: MarkedLocationCategory.water,
          lat: -6.77,
          lng: 106.97,
          elevationM: 2400,
          ownerName: 'Rina',
        );
      });
      await c.read(sharedLinkProvider.notifier).open(const PlaceLink(_token));
      expect(asked, _token);
      final v = c.read(sharedLinkProvider)! as SharedPlace;
      expect((v.status, v.place!.name), (LinkStatus.ok, 'Mata air Kandang Badak'));
      expect(c.read(flyToProvider)?.lat, -6.77);
    });

    test('a link turned off says so; a failure says to check the connection', () async {
      final gone = container((_) async => null);
      await gone.read(sharedLinkProvider.notifier).open(const PlaceLink(_token));
      expect((gone.read(sharedLinkProvider)! as SharedPlace).status, LinkStatus.gone);

      final failing = container((_) async => throw Exception('offline'));
      await failing.read(sharedLinkProvider.notifier).open(const PlaceLink(_token));
      expect((failing.read(sharedLinkProvider)! as SharedPlace).status, LinkStatus.error);
    });

    test('the place row from the server is read like the web', () {
      final p = LinkedPlace.fromRow({
        'name': 'Pos 3',
        'category': 'shelter',
        'lat': -6.78,
        'lng': 106.98,
        'elevation_m': null,
        'tags': ['shelter', 'water'],
        'owner_name': null,
      });
      expect((p.category, p.elevationM), (MarkedLocationCategory.shelter, null));
      expect(p.tags, ['shelter', 'water']);
      expect(LinkedPlace.fromRow({'name': 'x', 'category': 'nope', 'lat': 0, 'lng': 0}).category, MarkedLocationCategory.poi);
    });

    testWidgets('the card shows the place and closes', (tester) async {
      final c = container((_) async => null);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: buildAppTheme(), home: const Scaffold(body: SharedLinkCard())),
        ),
      );
      await c.read(sharedLinkProvider.notifier).open(const PointLink((lat: -6.7471, lng: 106.9932)));
      await tester.pump();
      expect(find.text('Shared location'), findsOneWidget);
      expect(find.textContaining('6°44'), findsOneWidget);
      await tester.tap(find.byKey(const Key('shared-link-close')));
      await tester.pump();
      expect(c.read(sharedLinkProvider), isNull);
    });
  });

  group('Share Location', () {
    Future<void> pump(WidgetTester tester, {Future<double?> Function(double, double)? terrain}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            phoneFixProvider.overrideWithValue(
              () async => const LocationFix(lat: -6.7471, lng: 106.9932, elevation: 2930, accuracy: 8, time: 1700000000000),
            ),
            authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
            profileProvider.overrideWith(
              (ref) async => const AccountProfile(
                userId: 'u1',
                email: 'rina@x.id',
                displayName: 'Rina',
                plan: Plan.free,
                role: UserRole.pengguna360,
                isAdmin: false,
                canUseSos: false,
              ),
            ),
          ],
          child: MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => Consumer(
                  builder: (context, ref, _) {
                    ref.watch(profileProvider);
                    return TextButton(
                      onPressed: () => showShareLocationSheet(context, terrainAt: terrain),
                      child: const Text('go'),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    testWidgets('one fix, with the terrain height when the map has it', (tester) async {
      await pump(tester, terrain: (_, _) async => 2958.4);
      expect(find.textContaining("6°44'49.56\" S 106°59'35.52\" E"), findsOneWidget);
      expect(find.textContaining('2958 mdpl · ±8 m'), findsOneWidget);
      expect(find.byKey(const Key('share-whatsapp')), findsOneWidget);
      expect(find.byKey(const Key('share-copy')), findsOneWidget);
    });

    testWidgets('the GPS height when there is no terrain', (tester) async {
      await pump(tester, terrain: (_, _) async => null);
      expect(find.textContaining('2930 mdpl'), findsOneWidget);
    });
  });

  group('points of interest', () {
    const pois = [
      PointOfInterest(id: 'a', name: 'Gunung Gede', category: 'mountain', lng: 106.98, lat: -6.78, subtitle: '2.958 mdpl'),
      PointOfInterest(id: 'b', name: 'Mata air', category: 'water', lng: 106.97, lat: -6.77),
    ];

    test('each point keeps its id and category for the colour and the tap', () {
      final features = poiGeoJson(pois)['features']! as List;
      expect(features, hasLength(2));
      expect((features.first as Map)['properties'], {'id': 'a', 'kind': 'mountain'});
    });

    test('every category has a label, colour and icon; unknown ones look like a place', () {
      expect(poiMeta('mountain').$1, 'Summit');
      expect(poiMeta('something-else').$1, 'Place');
    });

    testWidgets('the card shows the point and closes', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: buildAppTheme(), home: const Scaffold(body: PoiCard())),
        ),
      );
      c.read(selectedPoiProvider.notifier).select(pois.first);
      await tester.pump();
      expect(find.text('Gunung Gede'), findsOneWidget);
      expect(find.text('SUMMIT · 2.958 MDPL'), findsOneWidget);
      await tester.tap(find.byKey(const Key('poi-close')));
      await tester.pump();
      expect(c.read(selectedPoiProvider), isNull);
    });
  });
}
