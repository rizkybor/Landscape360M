import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/map/map_settings.dart';

void main() {
  test('defaults match the web: satellite, 2D, 1.5× exaggeration, DD', () {
    const s = MapSettings();
    expect(s.style.uri, 'mapbox://styles/mapbox/satellite-streets-v12');
    expect((s.view, s.exaggeration, s.coordFormat), (MapView.twoD, 1.5, CoordFormat.dd));
    expect(MapStyle.outdoors.uri, 'mapbox://styles/mapbox/outdoors-v12');
    expect(MapStyle.streets.uri, 'mapbox://styles/mapbox/streets-v12');
  });

  test('terrain looks flat in 2D and uses the chosen exaggeration in 3D', () {
    const s = MapSettings(exaggeration: 2.5);
    expect(s.appliedExaggeration, 1.0);
    expect(s.copyWith(view: MapView.threeD).appliedExaggeration, 2.5);
  });

  test('saved settings round-trip, always open in 2D, and bad values fall back', () {
    final saved = const MapSettings(
      style: MapStyle.outdoors,
      view: MapView.threeD,
      exaggeration: 2,
      coordFormat: CoordFormat.dms,
    ).toJson();
    final back = MapSettings.fromJson(saved);
    expect(
      (back.style, back.view, back.exaggeration, back.coordFormat),
      (MapStyle.outdoors, MapView.twoD, 2.0, CoordFormat.dms),
    );

    final bad = MapSettings.fromJson({'style': 'neon', 'exaggeration': 99, 'coordFormat': 'utm'});
    expect((bad.style, bad.exaggeration, bad.coordFormat), (MapStyle.satellite, maxExaggeration, CoordFormat.dd));
    expect(MapSettings.fromJson({'exaggeration': 'x'}).exaggeration, defaultExaggeration);
  });

  test('slope: the steeper of the east and north neighbours, like the web', () {
    expect(terrainSlopeDegrees(100, 100, 100), 0);
    // 11.132 m up over 11.132 m -> 45°
    expect(terrainSlopeDegrees(100, 111.132, 100), closeTo(45, 1e-9));
    expect(terrainSlopeDegrees(100, 95, 88.868), closeTo(45, 1e-9));
  });

  test('elevation without the terrain exaggeration, bearing as 0..360', () {
    expect(realElevation(3000, 1.5), 2000);
    expect(realElevation(812, 1), 812);
    expect(normalizeBearing(-90), 270);
    expect(normalizeBearing(370), 10);
    expect(normalizeBearing(0), 0);
  });
}
