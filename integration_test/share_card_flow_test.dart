// Share as image on the real map: a Merbabu track (imported GPX) → the four cards (the Map card
// from a real Mapbox snapshot) → the pictures the share sheet would get. Set L360_CARD_OUT to a
// folder the simulator can write to, to keep them.
//   flutter test integration_test/share_card_flow_test.dart -d <simulator> --dart-define-from-file=config/dev.json
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/tracks/share_card.dart';
import 'package:landscape360/features/tracks/share_card_page.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' show MapboxOptions;

import '../test/features/track_recorder_panel_test.dart' show MemoryTrackStore;
import '../test/features/track_recorder_state_test.dart' show FakeGps, FakeTrackCloud;
import 'gpx_import_flow_test.dart' show seloGpx;

const _out = String.fromEnvironment('L360_CARD_OUT');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();

  Future<void> wait(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> shot(WidgetTester tester, String name, {int settle = 1500}) async {
    await wait(tester, settle);
    debugPrint('SHOT:$name');
    await wait(tester, 3500);
  }

  testWidgets('share cards of a Merbabu track', (tester) async {
    MapboxOptions.setAccessToken(config.mapboxPublicToken);
    final saved = <String>[];
    final photo = (await rootBundle.load('assets/images/view_3d.jpg')).buffer.asUint8List();
    final c = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith(
          (ref) async => const AccountProfile(
            userId: 'u1',
            email: 'rina@landscape360.app',
            displayName: 'Rina Wulandari',
            plan: Plan.enterprise,
            role: UserRole.pengguna360,
            isAdmin: false,
            canUseSos: false,
          ),
        ),
        storageUsageProvider.overrideWith((ref) async => null),
        trackLocalStoreProvider.overrideWithValue(MemoryTrackStore()),
        trackCloudProvider.overrideWithValue(FakeTrackCloud()),
        gpsSourceProvider.overrideWithValue(FakeGps()),
        cardPhotoPickerProvider.overrideWithValue(() async => photo),
        cardShareProvider.overrideWithValue((png, name) async {
          saved.add(name);
          debugPrint('CARD $name ${png.length} bytes');
          if (_out.isNotEmpty) await File('$_out/$name').writeAsBytes(png);
        }),
      ],
    );
    addTearDown(c.dispose);
    c
      ..listen(trackRecorderProvider, (_, _) {})
      ..listen(authUserIdProvider, (_, _) {});
    await c.read(authUserIdProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildAppTheme(), home: const SizedBox()),
      ),
    );
    await wait(tester, 500);
    final id = await c.read(trackRecorderProvider.notifier).importGpx(seloGpx(), 'merbabu.gpx');
    expect(id, isNotNull);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: ShareCardPage(trackId: id!),
        ),
      ),
    );
    // The map snapshot comes from the network
    await wait(tester, 12000);
    await shot(tester, 'card1_map');
    await tester.tap(find.byKey(const Key('share-send')));
    await wait(tester, 3000);

    for (final t in [ShareCardTemplate.sticker, ShareCardTemplate.photo, ShareCardTemplate.profile]) {
      await tester.tap(find.byKey(Key('share-template-${t.name}')));
      await wait(tester, 800);
      if (t == ShareCardTemplate.photo) {
        await tester.tap(find.byKey(const Key('share-photo')));
        await wait(tester, 1000);
      }
      await shot(tester, 'card_${t.name}');
      await tester.tap(find.byKey(const Key('share-send')));
      await wait(tester, 3000);
    }
    expect(saved, hasLength(4));

    // Hiding the ends redraws the route and takes the map again
    await tester.tap(find.byKey(const Key('share-template-map')));
    await tester.tap(find.byKey(const Key('share-hide-ends')));
    await wait(tester, 12000);
    await tester.tap(find.byKey(const Key('share-send')));
    await wait(tester, 3000);
  });
}
