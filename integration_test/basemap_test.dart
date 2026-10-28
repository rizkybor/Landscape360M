// Custom basemaps on the real map (simulator or phone):
//   flutter test integration_test/basemap_test.dart -d <device> --dart-define-from-file=config/dev.json
// A solid red picture saved on the phone is placed over Gede as a basemap; the map's own
// snapshot must be red there (the map reads the picture from the phone, so it works offline),
// at the chosen opacity, and the picture goes away when switched off.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/basemaps/custom_basemaps.dart';
import 'package:landscape360/domain/map/offline_regions.dart';
import 'package:landscape360/features/basemaps/basemap_state.dart';
import 'package:landscape360/features/map/map_screen.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide square;

const _gede = OfflineBounds(west: 106.97, south: -6.80, east: 107.00, north: -6.77);

class _Cloud implements BasemapBackend {
  bool active = true;

  @override
  Future<List<CustomBasemap>> list(String userId) async => [
    CustomBasemap(id: 'red', name: 'Red', filePath: 'u1/red.png', fileSize: 1000, bounds: _gede, active: active),
  ];

  @override
  Future<void> setActive(String id, bool v) async => active = v;

  @override
  Future<void> delete(CustomBasemap b) async {}

  @override
  Future<Uint8List> download(String filePath) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 64, 64), Paint()..color = const Color(0xFFFF0000));
    final image = await recorder.endRecording().toImage(64, 64);
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  }
}

class _Files implements BasemapFiles {
  final dir = Directory.systemTemp.createTempSync('basemaps');

  @override
  Future<File?> get(String id) async {
    final f = File('${dir.path}/$id.png');
    return f.existsSync() ? f : null;
  }

  @override
  Future<File> save(String id, Uint8List bytes) => File('${dir.path}/$id.png').writeAsBytes(bytes);

  @override
  Future<void> remove(String id) async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();

  Future<void> wait(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a basemap from the phone shows on the map, with its opacity', (tester) async {
    MapboxOptions.setAccessToken(config.mapboxPublicToken);
    final cloud = _Cloud();
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith((ref) async => null),
        basemapBackendProvider.overrideWithValue(cloud),
        basemapFilesProvider.overrideWithValue(_Files()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: buildAppTheme(), home: const MapScreen()),
      ),
    );
    await wait(tester, 6000);
    final (lng, lat) = _gede.center;
    container.read(flyToProvider.notifier).go(lng, lat, zoom: 15);
    await wait(tester, 5000);
    expect(container.read(basemapsProvider).files, contains('red'), reason: 'picture kept on the phone');

    final map = debugLiveMap!;
    Future<Color> centre() async {
      final png = await tester.runAsync(map.snapshot);
      final codec = await tester.runAsync(() => ui.instantiateImageCodec(png!));
      final frame = await tester.runAsync(() => codec!.getNextFrame());
      final image = frame!.image;
      final bytes = (await tester.runAsync(() => image.toByteData()))!;
      final at = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
      return Color.fromARGB(bytes.getUint8(at + 3), bytes.getUint8(at), bytes.getUint8(at + 1), bytes.getUint8(at + 2));
    }

    final full = await centre();
    expect((full.r * 255).round(), greaterThan(200), reason: 'red basemap over the map: $full');
    expect((full.g * 255).round(), lessThan(60));

    container.read(basemapsProvider.notifier).setOpacity('red', 0.3);
    await wait(tester, 1500);
    final faint = await centre();
    expect((faint.r * 255).round(), lessThan((full.r * 255).round() - 80), reason: 'the map shows through at 30%: $faint');

    await container.read(basemapsProvider.notifier).setActive('red', false);
    await wait(tester, 1500);
    final off = await centre();
    expect((off.r * 255).round() - (off.g * 255).round(), lessThan(120), reason: 'switched off: $off');
  });
}
