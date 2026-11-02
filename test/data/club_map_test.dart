import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/data/community/community_repository.dart';
import 'package:landscape360/data/geo/elevation_sampler.dart';
import 'package:landscape360/domain/community/club_map.dart';
import 'package:landscape360/domain/community/community.dart';
import 'package:landscape360/domain/map/map_settings.dart';
import 'package:landscape360/features/community/club_map_state.dart';
import 'package:landscape360/features/community/community_state.dart';
import 'package:landscape360/features/map/map_settings_controller.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../domain/club_map_test.dart' show annotationRow;
import 'community_repository_test.dart' show FakeCommunity;

// The club map's RPCs, the elevation tiles, and the state: the club's drawings on the map,
// drawing point by point, saving, deleting, and saved views

const clubId = '11111111-2222-4333-8444-555555555555';

final club = CommunityClub(id: clubId, name: 'Mapala UI', role: ClubRole.member, createdAt: DateTime.utc(2026));

/// A 256 × 256 terrarium tile of one height
Future<Uint8List> terrariumPng(double height) async {
  final v = height + 32768;
  final r = v ~/ 256, g = (v % 256).floor(), b = ((v - v.floor()) * 256).round();
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 256, 256), Paint()..color = Color.fromARGB(255, r, g, b));
  final image = await recorder.endRecording().toImage(256, 256);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeCommunity backend;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    backend = FakeCommunity()
      ..answers['community_club_annotations'] = [annotationRow()]
      ..answers['community_club_views'] = <Object>[];
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        communityBackendProvider.overrideWithValue(backend),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('repository', () {
    test('saves a drawing with its geometry, trims the note away when blank', () async {
      final c = container();
      backend.answers['save_community_club_annotation'] = 'a9';
      final id = await c
          .read(clubMapRepositoryProvider)
          .save(
            clubId,
            null,
            kind: AnnotationKind.pin,
            label: ' Spring ',
            note: '  ',
            color: '#2f7d3b',
            geometry: annotationGeometry(AnnotationKind.pin, [(106.9, -6.7)])!,
          );
      expect(id, 'a9');
      expect(backend.params('save_community_club_annotation'), {
        'p_club_id': clubId,
        'p_id': null,
        'p_kind': 'pin',
        'p_label': 'Spring',
        'p_note': null,
        'p_color': '#2f7d3b',
        'p_geometry': {
          'type': 'Point',
          'coordinates': [106.9, -6.7],
        },
      });
    });

    test('comments and views', () async {
      final repo = container().read(clubMapRepositoryProvider);
      backend.answers['community_club_annotation_comments'] = [
        {
          'id': 'c1',
          'body': 'Dry in August',
          'author_name': 'Dodi',
          'is_mine': false,
          'created_at': '2026-11-02T00:00:00Z',
        },
      ];
      expect((await repo.comments('a1')).single.body, 'Dry in August');
      await repo.addComment('a1', ' Thanks ');
      expect(backend.params('add_community_club_annotation_comment'), {'p_id': 'a1', 'p_body': 'Thanks'});
      await repo.deleteView('v1');
      expect(backend.params('delete_community_club_view'), {'p_id': 'v1'});
    });
  });

  group('elevation tiles', () {
    test('terrarium decoding', () {
      expect(decodeTerrarium(128, 0, 0), 0);
      expect(decodeTerrarium(137, 213, 128), closeTo(2517.5, 1e-9));
    });

    testWidgets('heights between the pixels of the open tiles; NaN where the sea has none', (tester) async {
      await tester.runAsync(() async {
        final land = await terrariumPng(2400);
        final asked = <String>[];
        final sampler = TerrariumSampler(
          client: MockClient((req) async {
            asked.add(req.url.path);
            // Tiles east of 107° are "sea"
            final x = int.parse(req.url.pathSegments[req.url.pathSegments.length - 2]);
            return x >= 6531 ? http.Response('', 404) : http.Response.bytes(land, 200);
          }),
        );
        final h = await sampler.sample([(106.9, -6.7), (107.5, -6.7)]);
        expect(h.first, closeTo(2400, 1));
        expect(h.last.isNaN, isTrue);
        expect(asked.first, startsWith('/elevation-tiles-prod/terrarium/13/'));
      });
    });

    testWidgets('no signal and too long', (tester) async {
      await tester.runAsync(() async {
        final offline = TerrariumSampler(client: MockClient((_) async => throw http.ClientException('offline')));
        await expectLater(
          offline.sample([(106.9, -6.7)]),
          throwsA(isA<ElevationException>().having((e) => e.message, 'message', contains('No signal'))),
        );
        final far = TerrariumSampler(client: MockClient((_) async => http.Response('', 404)));
        await expectLater(
          far.sample([for (var i = 0; i < 600; i++) (100.0 + i * 0.05, -6.7)]),
          throwsA(isA<ElevationException>().having((e) => e.message, 'message', contains('too long'))),
        );
      });
    });
  });

  group('state', () {
    test('opening the Map tab shows the club and reads its drawings and views', () async {
      final c = container();
      c.listen(clubMapProvider, (_, _) {});
      await c.read(clubMapProvider.notifier).open(club);
      final s = c.read(clubMapProvider);
      expect(s.shown, isTrue);
      expect(s.annotations.single.label, 'Water source');
      expect(backend.params('community_club_views'), {'p_club_id': clubId});
      c.read(clubMapProvider.notifier).close();
      expect(c.read(clubMapProvider).shown, isFalse);
    });

    test('an error is kept and shown', () async {
      final c = container();
      c.listen(clubMapProvider, (_, _) {});
      backend.fail['community_club_annotations'] = const CommunityException('Members only');
      await c.read(clubMapProvider.notifier).open(club);
      expect(c.read(clubMapProvider).error, 'Members only');
    });

    test('drawing: taps add points (a pin moves), undo, done hands it to the form', () {
      final c = container();
      final draw = c.read(clubDrawProvider.notifier)..start(AnnotationKind.line);
      draw.tap((1, 1));
      expect(c.read(clubDrawProvider)!.ready, isFalse);
      draw
        ..tap((2, 2))
        ..tap((3, 3))
        ..undo();
      expect(c.read(clubDrawProvider)!.points, [(1.0, 1.0), (2.0, 2.0)]);
      draw.done();
      expect(c.read(clubDrawProvider), isNull);
      expect(c.read(clubDrawDoneProvider)!.points, hasLength(2));

      draw
        ..start(AnnotationKind.pin)
        ..tap((1, 1))
        ..tap((5, 5));
      expect(c.read(clubDrawProvider)!.points, [(5.0, 5.0)]);
    });

    test('editing starts from the drawing', () {
      final c = container();
      final a = Annotation.fromRow(annotationRow());
      c.read(clubDrawProvider.notifier).start(a.kind, existing: a);
      final d = c.read(clubDrawProvider)!;
      expect((d.editingId, d.label, d.color, d.points.length), ('a1', 'Water source', '#1f6feb', 2));
    });

    test('saving selects the new drawing; deleting removes it', () async {
      final c = container();
      c.listen(clubMapProvider, (_, _) {});
      final map = c.read(clubMapProvider.notifier);
      await map.open(club);
      backend.answers['save_community_club_annotation'] = 'a1';
      await map.save(
        null,
        kind: AnnotationKind.line,
        label: 'Shortcut',
        note: '',
        color: '#d49b22',
        geometry: annotationGeometry(AnnotationKind.line, [(1, 1), (2, 2)])!,
      );
      expect(c.read(clubMapProvider).selectedId, 'a1');
      await map.delete('a1');
      expect(c.read(clubMapProvider).annotations, isEmpty);
      expect(c.read(clubMapProvider).selectedId, isNull);
    });

    test('a saved view keeps the camera (tilt only in 3D) and flies back to it', () async {
      final c = container();
      c.listen(clubMapProvider, (_, _) {});
      final map = c.read(clubMapProvider.notifier);
      await map.open(club);
      c.read(mapCenterProvider.notifier).set(106.98, -6.78);
      c.read(mapZoomProvider.notifier).set(14);
      c.read(mapTiltProvider.notifier).set(55, 30);
      backend.answers['save_community_club_view'] = 'v1';
      await map.saveView('Summit');
      expect(backend.params('save_community_club_view')['p_pitch'], 0, reason: '2D');
      expect(backend.params('save_community_club_view')['p_bearing'], 30);
      expect(backend.params('save_community_club_view')['p_terrain'], false);

      map.flyTo(
        const SavedView(
          id: 'v1',
          name: 'Summit',
          lng: 106.98,
          lat: -6.78,
          zoom: 14,
          pitch: 55,
          bearing: 30,
          terrain: true,
        ),
      );
      expect(c.read(mapSettingsProvider).view, MapView.threeD);
      expect(c.read(cameraToProvider), (lng: 106.98, lat: -6.78, zoom: 14.0, pitch: 55.0, bearing: 30.0));
    });
  });
}
