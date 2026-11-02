// The club map end to end on the real map (Stage 3): a club's drawings shown, a line drawn point
// by point, its label and colour, the saved line, its elevation profile from the real SRTM
// tiles, and a saved view in 3D. The club backend is in memory (nothing reaches a real club);
// the map, terrain and elevation tiles are real. On a simulator it prints "SHOT:<name>" at
// every scene (a script saves the screen); run alone it just checks the flow:
//   flutter test integration_test/club_map_flow_test.dart -d <device> --dart-define-from-file=config/dev.json
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/community/community_repository.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/community/club_map.dart';
import 'package:landscape360/domain/community/community.dart';
import 'package:landscape360/domain/map/map_settings.dart';
import 'package:landscape360/features/community/club_map_state.dart';
import 'package:landscape360/features/community/club_map_ui.dart';
import 'package:landscape360/features/community/community_state.dart';
import 'package:landscape360/features/map/map_screen.dart';
import 'package:landscape360/features/map/map_settings_controller.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' show MapboxOptions;

const _member = AccountProfile(
  userId: 'u1',
  email: 'rina@landscape360.app',
  displayName: 'Rina Wulandari',
  plan: Plan.enterprise,
  role: UserRole.pengguna360,
  isAdmin: false,
  canUseSos: false,
);

final _club = CommunityClub(
  id: '11111111-2222-4333-8444-555555555555',
  name: 'Mapala Merbabu',
  role: ClubRole.owner,
  createdAt: DateTime.utc(2026),
  canManage: true,
);

/// The club's side of the server in memory: drawings, comments and views as the RPCs keep them
class MemoryClubBackend implements CommunityBackend {
  final annotations = <Map<String, dynamic>>[
    {
      'id': 'camp',
      'kind': 'area',
      'label': 'Camp Sabana 1',
      'note': 'Flat ground for 12 tents',
      'color': '#2f7d3b',
      'geometry': {
        'type': 'Polygon',
        'coordinates': [
          [
            [110.4362, -7.4668],
            [110.4392, -7.4664],
            [110.4396, -7.4642],
            [110.4366, -7.4640],
            [110.4362, -7.4668],
          ],
        ],
      },
      'author_name': 'Dodi P.',
      'is_mine': false,
      'comment_count': 1,
      'created_at': '2026-11-01T00:00:00Z',
      'updated_at': '2026-11-01T00:00:00Z',
    },
    {
      'id': 'water',
      'kind': 'pin',
      'label': 'Water source',
      'color': '#1f6feb',
      'geometry': {
        'type': 'Point',
        'coordinates': [110.4415, -7.4720],
      },
      'author_name': 'Rina W.',
      'is_mine': true,
      'comment_count': 0,
      'created_at': '2026-11-01T00:00:00Z',
      'updated_at': '2026-11-01T00:00:00Z',
    },
  ];
  final views = <Map<String, dynamic>>[];
  final calls = <String>[];
  var _n = 0;

  @override
  Future<Object?> rpc(String fn, Map<String, dynamic> p) async {
    calls.add(fn);
    switch (fn) {
      case 'community_club_annotations':
        return annotations;
      case 'community_club_views':
        return views;
      case 'community_club_annotation_comments':
        return [
          {
            'id': 'c1',
            'body': 'Windy at night',
            'author_name': 'Dodi P.',
            'is_mine': false,
            'created_at': '2026-11-01T00:00:00Z',
          },
        ];
      case 'save_community_club_annotation':
        final id = (p['p_id'] as String?) ?? 'new${_n++}';
        annotations
          ..removeWhere((a) => a['id'] == id)
          ..add({
            'id': id,
            'kind': p['p_kind'],
            'label': p['p_label'],
            'note': p['p_note'],
            'color': p['p_color'],
            'geometry': p['p_geometry'],
            'author_name': 'Rina W.',
            'is_mine': true,
            'comment_count': 0,
            'created_at': DateTime.now().toUtc().toIso8601String(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          });
        return id;
      case 'save_community_club_view':
        views.add({
          'id': 'v${_n++}',
          'name': p['p_name'],
          'lng': p['p_lng'],
          'lat': p['p_lat'],
          'zoom': p['p_zoom'],
          'pitch': p['p_pitch'],
          'bearing': p['p_bearing'],
          'terrain': p['p_terrain'],
          'is_mine': true,
        });
        return views.last['id'];
    }
    return null; // the feed and the rest of Community: nothing
  }

  @override
  Future<void> upload(String path, Uint8List bytes) async {}

  @override
  Future<void> remove(List<String> paths) async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();

  Future<void> wait(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> shot(WidgetTester tester, String name, {int settle = 7000}) async {
    await wait(tester, settle);
    debugPrint('SHOT:$name');
    await wait(tester, 4000);
  }

  testWidgets('club map: drawings, a new line, its profile, a 3D view', (tester) async {
    MapboxOptions.setAccessToken(config.mapboxPublicToken);
    final backend = MemoryClubBackend();
    final nav = GlobalKey<NavigatorState>();
    WidgetRef? ref;
    final c = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith((ref) async => _member),
        storageUsageProvider.overrideWith((ref) async => null),
        communityBackendProvider.overrideWithValue(backend),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          navigatorKey: nav,
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: Consumer(
            builder: (context, r, _) {
              ref = r;
              return const MapScreen();
            },
          ),
        ),
      ),
    );
    await wait(tester, 6000);
    c.read(mapSettingsProvider.notifier).setStyle(MapStyle.outdoors);
    void log(String step) {
      final m = c.read(mapCenterProvider), t = c.read(mapTiltProvider);
      debugPrint(
        'CAMERA $step: ${m.lng.toStringAsFixed(4)},${m.lat.toStringAsFixed(4)} z${c.read(mapZoomProvider).toStringAsFixed(1)} '
        'pitch ${t.pitch.round()} bearing ${t.bearing.round()}',
      );
    }

    // 1. The club's drawings on the map (the Map tab was opened), all in view
    final map = c.read(clubMapProvider.notifier);
    await map.open(_club);
    expect(c.read(clubMapProvider).annotations, hasLength(2));
    map.fit();
    await shot(tester, 'cm1_drawings', settle: 9000);
    log('all drawings fitted');
    expect(find.byKey(const Key('club-map-card')), findsOneWidget);
    expect(find.text('Mapala Merbabu map'), findsOneWidget);

    // 2. A new line, point by point (each tap goes where a tap on the map goes)
    final draw = c.read(clubDrawProvider.notifier)..start(AnnotationKind.line);
    await wait(tester, 600);
    expect(find.byKey(const Key('club-drawing')), findsOneWidget);
    for (final p in const [(110.4399, -7.4868), (110.4372, -7.4790), (110.4412, -7.4712), (110.4378, -7.4640)]) {
      draw.tap(p);
      await wait(tester, 300);
    }
    expect(find.textContaining('Length '), findsOneWidget);
    await shot(tester, 'cm2_drawing');

    // 3. Done: label, note and colour
    await tester.tap(find.byKey(const Key('club-draw-done')));
    await wait(tester, 1200);
    expect(find.byType(AnnotationFormPage), findsOneWidget);
    await tester.enterText(find.byKey(const Key('annotation-label')), 'Selo trail, upper part');
    await tester.enterText(find.byKey(const Key('annotation-note')), 'Loose gravel after Pos 2');
    await tester.tap(find.byKey(const Key('annotation-color-#b4302a')));
    FocusManager.instance.primaryFocus?.unfocus();
    await shot(tester, 'cm3_form', settle: 1500);
    await tester.tap(find.byKey(const Key('annotation-save')));
    await wait(tester, 1500);
    expect(find.byType(AnnotationFormPage), findsNothing);
    final saved = c.read(clubMapProvider).selected!;
    expect((saved.label, saved.color, saved.points.length), ('Selo trail, upper part', '#b4302a', 4));
    await shot(tester, 'cm4_saved');
    log('saved line fitted (expect about 110.439,-7.475)');

    // 4. Its page: length, the elevation profile from the real SRTM tiles, comments
    final context = nav.currentContext!;
    // ignore: use_build_context_synchronously
    final opened = openAnnotation(context, ref!, saved);
    await wait(tester, 1200);
    await tester.tap(find.byKey(const Key('annotation-elevation')));
    var tries = 0;
    while (find.byKey(const Key('annotation-profile')).evaluate().isEmpty && tries++ < 60) {
      await wait(tester, 500);
    }
    expect(find.byKey(const Key('annotation-profile')), findsOneWidget, reason: 'the SRTM tiles were read');
    // Selo (~1,840 m) up towards Sabana: hundreds of metres of climb
    final climb = tester.widgetList<Text>(find.textContaining(RegExp(r'^\+\d+ m$'))).first.data!;
    debugPrint('PROFILE climb $climb');
    expect(int.parse(climb.replaceAll(RegExp(r'[^0-9]'), '')), greaterThan(300));
    await shot(tester, 'cm5_profile', settle: 1500);
    nav.currentState!.pop();
    await opened;
    await wait(tester, 800);

    // 5. A saved view in 3D, tilted, and back to it
    c.read(mapSettingsProvider.notifier).setView(MapView.threeD);
    c.read(cameraToProvider.notifier).go((lng: 110.4392, lat: -7.4735, zoom: 13.6, pitch: 62, bearing: -25));
    await wait(tester, 6000);
    await map.saveView('Briefing: summit approach');
    final view = c.read(clubMapProvider).views.single;
    expect((view.terrain, view.pitch > 40), (true, true));
    c.read(cameraToProvider.notifier).go((lng: 110.44, lat: -7.46, zoom: 11, pitch: 0, bearing: 0));
    await wait(tester, 3000);
    map.flyTo(view);
    await shot(tester, 'cm6_view_3d', settle: 10000);
    log('saved view (expect 110.4392,-7.4735 z13.6 pitch 62 bearing 335)');

    // 6. The Map tab itself
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Mapala Merbabu')),
          body: ClubMapTab(club: _club),
        ),
      ),
    );
    await wait(tester, 1500);
    expect(find.text('All · 3'), findsOneWidget);
    expect(find.byKey(Key('club-view-${view.id}')), findsOneWidget);
    await shot(tester, 'cm7_tab', settle: 1500);
    nav.currentState!.pop();
    map.close();
    await wait(tester, 500);
  });
}
