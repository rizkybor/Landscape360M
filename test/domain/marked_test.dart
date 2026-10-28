import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/geo/spherical.dart';
import 'package:landscape360/domain/marked/marked_areas.dart';
import 'package:landscape360/domain/marked/marked_locations.dart';

// Same cases as src/utils/markedLocations.test.ts and src/utils/markedAreas.test.ts (web)

MarkedLocationGpx location({
  String name = 'Pos 1',
  String category = 'camp',
  double? elevationM = 1500,
  String? description,
  String? contact,
  List<String> tags = const [],
}) => MarkedLocationGpx(
  name: name,
  category: category,
  lng: 107.6,
  lat: -6.9,
  elevationM: elevationM,
  description: description,
  contact: contact,
  tags: tags,
);

// About 100 m x 100 m near Gunung Gede
const List<LngLat> square = [(106.98, -6.79), (106.980904, -6.79), (106.980904, -6.789096), (106.98, -6.789096)];

void main() {
  group('getMarkedLocationPolicy', () {
    for (final (plan, max, share) in [('Free', 10, false), ('Pro', 100, true), ('Enterprise', 1000, true)]) {
      test('$plan plan: $max locations, share=$share', () {
        expect(
          getMarkedLocationPolicy(hasUser: true, subscriptionStatus: plan, isAdmin: false),
          MarkedLocationPolicy(canUse: true, maxLocations: max, canShare: share),
        );
      });
    }

    test('gives admins unlimited locations and sharing regardless of plan', () {
      expect(
        getMarkedLocationPolicy(hasUser: true, subscriptionStatus: 'Free', isAdmin: true),
        const MarkedLocationPolicy(canUse: true, maxLocations: null, canShare: true),
      );
    });

    test('treats an unknown plan as Free and blocks signed-out visitors', () {
      expect(getMarkedLocationPolicy(hasUser: true, subscriptionStatus: 'Ultimate', isAdmin: false).maxLocations, 10);
      expect(getMarkedLocationPolicy(hasUser: false, subscriptionStatus: 'Pro', isAdmin: false).canUse, isFalse);
    });
  });

  group('parseTags', () {
    test('trims, drops empties and case-insensitive duplicates', () {
      expect(parseTags(' basecamp, water,, Basecamp ,  '), ['basecamp', 'water']);
    });

    test('keeps at most 10 tags of 30 characters', () {
      expect(parseTags(List.generate(15, (i) => 'tag$i').join(',')), hasLength(10));
      expect(parseTags('x' * 50)[0], hasLength(30));
    });
  });

  test('isValidCoordinate accepts valid ranges and rejects the rest', () {
    expect(isValidCoordinate(107.6, -6.9), isTrue);
    expect(isValidCoordinate(181, 0), isFalse);
    expect(isValidCoordinate(0, -91), isFalse);
    expect(isValidCoordinate(double.nan, 0), isFalse);
  });

  test('toGpx writes waypoints with elevation, type and escaped text', () {
    final gpx = markedLocationsToGpx([
      location(name: 'Pos <1> & "A"', description: 'Water ok', tags: ['camp'], contact: 'Ranger'),
      location(name: 'Puncak', category: 'summit', elevationM: null),
    ]);
    expect(gpx, contains('<wpt lat="-6.9" lon="107.6">'));
    expect(gpx, contains('<ele>1500.0</ele>'));
    expect(gpx, contains('<name>Pos &lt;1&gt; &amp; &quot;A&quot;</name>'));
    expect(gpx, contains('<desc>Water ok\nContact: Ranger\nTags: camp</desc>'));
    expect(gpx, contains('<type>Camp / Basecamp</type>'));
    expect(gpx, contains('<type>Summit</type>'));
    expect('<ele>'.allMatches(gpx), hasLength(1));
  });

  group('marked areas', () {
    test('measures area and perimeter', () {
      expect(ringArea(square), inInclusiveRange(9900, 10100));
      expect(ringPerimeter(square), inInclusiveRange(398, 402));
      expect(formatArea(ringArea(square)), '1.00 ha');
      expect(formatArea(450), '450 m²');
      expect(formatArea(2500000), '2.50 km²');
    });

    test('focus mask: the world with the area cut out, whichever way the area was drawn', () {
      for (final ring in [square, square.reversed.toList()]) {
        final mask = focusMaskRings(ring);
        final outer = mask[0], hole = mask[1];
        expect(outer, hasLength(5));
        expect(hole, hasLength(ring.length + 1));
        final world = turfPolygonArea([outer]);
        expect(world - turfPolygonArea(mask), closeTo(ringArea(ring), 50));
      }
    });

    test('bounds, validation and plan limits', () {
      expect(ringBounds(square), ((106.98, -6.79), (106.980904, -6.789096)));
      expect(areaInputError(name: '', ring: square), 'Give the area a name');
      expect(areaInputError(name: 'Camp', ring: square.sublist(0, 2)), 'Draw at least 3 points');
      expect(areaInputError(name: 'Camp', ring: square), isNull);
      expect(
        getMarkedAreaPolicy(hasUser: true, subscriptionStatus: 'Free', isAdmin: false),
        const MarkedAreaPolicy(canUse: true, limit: 5, canShare: false),
      );
      expect(
        getMarkedAreaPolicy(hasUser: true, subscriptionStatus: 'Pro', isAdmin: false),
        const MarkedAreaPolicy(canUse: true, limit: 10, canShare: true),
      );
      expect(getMarkedAreaPolicy(hasUser: true, subscriptionStatus: 'Enterprise', isAdmin: false).limit, 20);
      expect(
        getMarkedAreaPolicy(hasUser: true, subscriptionStatus: 'Free', isAdmin: true),
        const MarkedAreaPolicy(canUse: true, limit: null, canShare: true),
      );
      expect(getMarkedAreaPolicy(hasUser: false, subscriptionStatus: 'Pro', isAdmin: false).canUse, isFalse);
    });
  });
}
