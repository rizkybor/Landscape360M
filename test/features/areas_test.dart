import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/marked/marked_area_repository.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/geo/spherical.dart';
import 'package:landscape360/domain/marked/area_contours.dart';
import 'package:landscape360/domain/share/share_location.dart';
import 'package:landscape360/features/areas/area_layer.dart';
import 'package:landscape360/features/areas/area_panel.dart';
import 'package:landscape360/features/areas/area_state.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:landscape360/features/map/shared_links.dart';

// Marked Areas: drawing, the form, saving, focus, and an area opened from its link

// About 111 m × 111 m near Gede
const List<LngLat> square = [(106.98, -6.78), (106.981, -6.78), (106.981, -6.779), (106.98, -6.779)];

class FakeAreas implements MarkedAreaBackend {
  List<MarkedArea> rows = [];
  final calls = <String>[];
  LinkedArea? linked;
  int _n = 0;

  MarkedArea _of(String id, MarkedAreaInput input) {
    final r = input.toRow();
    return MarkedArea(
      id: id,
      userId: 'u1',
      name: r['name'] as String,
      color: input.color,
      notes: r['notes'] as String?,
      ring: input.ring,
      areaM2: r['area_m2'] as double,
      perimeterM: r['perimeter_m'] as double,
    );
  }

  @override
  Future<List<MarkedArea>> mine(String userId) async => rows;

  @override
  Future<MarkedArea> create(MarkedAreaInput input) async {
    calls.add('create:${input.name}');
    return _of('a${++_n}', input);
  }

  @override
  Future<MarkedArea> update(String id, MarkedAreaInput input) async {
    calls.add('update:$id');
    return _of(id, input);
  }

  @override
  Future<void> delete(String id) async => calls.add('delete:$id');

  @override
  Future<String?> link(String id) async => null;

  @override
  Future<String> createLink(String id) async => '0123456789abcdef0123456789abcdef';

  @override
  Future<void> revokeLink(String id) async {}

  @override
  Future<LinkedArea?> open(String token) async => linked;

  List<AreaContourMeta> meta = [];
  final contourData = <String, Map<String, dynamic>>{};
  ContourSet? linkedContours;

  @override
  Future<List<AreaContourMeta>> contourMeta(String userId) async => meta;

  @override
  Future<Map<String, dynamic>> contours(String areaId) async {
    calls.add('contours:$areaId');
    return contourData[areaId]!;
  }

  @override
  Future<ContourSet?> linkContours(String token) async => linkedContours;
}

/// Two lines, 1200 m (an index line every 50 m at 12.5 m) and 1212.5 m
Map<String, dynamic> lines() => {
  'type': 'FeatureCollection',
  'features': [
    for (final e in [1200.0, 1212.5])
      {
        'type': 'Feature',
        'properties': {'elevation': e},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [106.98, -6.78],
            [106.981, -6.779],
          ],
        },
      },
  ],
};

AccountProfile _profile(Plan plan) => AccountProfile(
  userId: 'u1',
  email: 'u@x.id',
  displayName: 'U',
  plan: plan,
  role: UserRole.pengguna360,
  isAdmin: false,
  canUseSos: false,
);

MarkedArea _area(String id) =>
    MarkedArea(id: id, userId: 'u1', name: 'Area $id', color: '#d49b22', ring: square, areaM2: 12300, perimeterM: 444);

void main() {
  late FakeAreas backend;

  setUp(() => backend = FakeAreas());

  ProviderContainer container({Plan plan = Plan.pro}) {
    final c = ProviderContainer(
      overrides: [
        areaBackendProvider.overrideWithValue(backend),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith((ref) async => _profile(plan)),
      ],
    );
    addTearDown(c.dispose);
    c
      ..listen(areasProvider, (_, _) {})
      ..listen(profileProvider, (_, _) {})
      ..listen(fitPointsProvider, (_, _) {})
      ..listen(sharedLinkProvider, (_, _) {});
    return c;
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  test('drawing: taps add corners, undo removes the last, Done needs 3', () async {
    final c = container();
    await settle();
    final rec = c.read(areasProvider.notifier)
      ..newArea()
      ..addPoint(square[0])
      ..addPoint(square[1]);
    expect(c.read(areasProvider).drawing, isTrue);
    rec.finishDrawing();
    expect(c.read(areasProvider).drawing, isTrue, reason: 'two points are not a shape');
    rec
      ..addPoint(square[2])
      ..addPoint((0, 0))
      ..undoPoint()
      ..addPoint(square[3])
      ..finishDrawing();
    final s = c.read(areasProvider);
    expect((s.drawing, s.panelOpen), (false, true));
    expect(s.form?.ring, square);
  });

  test('cancelling the drawing keeps the panel and adds nothing', () async {
    final c = container();
    await settle();
    c.read(areasProvider.notifier)
      ..newArea()
      ..addPoint(square[0])
      ..cancelDrawing();
    final s = c.read(areasProvider);
    expect((s.drawing, s.panelOpen, s.form), (false, true, null));
    expect(s.draft, isEmpty);
  });

  test('save checks the form, then stores the size; edit keeps the id; delete leaves focus', () async {
    final c = container();
    await settle();
    final rec = c.read(areasProvider.notifier)..newArea();
    for (final p in square) {
      rec.addPoint(p);
    }
    rec.finishDrawing();
    expect(await rec.save(), 'Give the area a name');

    rec.updateForm(c.read(areasProvider).form!.copyWith(name: 'Surya Kencana', color: '#2563eb'));
    expect(await rec.save(), isNull);
    final saved = c.read(areasProvider).areas.single;
    expect(saved.areaM2, closeTo(12200, 300), reason: '~111 m × ~110 m');
    expect((saved.color, c.read(areasProvider).selectedId, c.read(areasProvider).form), ('#2563eb', saved.id, null));

    rec.edit(saved);
    rec.updateForm(c.read(areasProvider).form!.copyWith(name: 'Alun-alun'));
    await rec.save();
    expect(backend.calls.last, 'update:${saved.id}');
    expect(c.read(areasProvider).areas.single.name, 'Alun-alun');

    rec.focus(saved.id);
    expect(c.read(fitPointsProvider), square, reason: 'the map fits the area');
    await rec.delete(saved.id);
    expect(c.read(areasProvider).areas, isEmpty);
    expect(c.read(areasProvider).focusId, isNull);
  });

  test('the stored ring is rounded to 7 decimals and the size is worked out', () {
    final row = const MarkedAreaInput(
      name: ' A ',
      color: '#d49b22',
      ring: [(106.123456789, -6.1), (106.2, -6.1), (106.2, -6.2)],
    ).toRow();
    expect((row['ring']! as List).first, [106.1234568, -6.1]);
    expect((row['name'], row['notes']), ('A', null));
    expect(row['area_m2'], greaterThan(0));
  });

  test('the drawn shape closes once it has 3 points', () {
    final two = draftGeoJson(square.sublist(0, 2))['features']! as List;
    expect(((two.first as Map)['geometry'] as Map)['coordinates'], hasLength(2));
    final three = draftGeoJson(square.sublist(0, 3))['features']! as List;
    expect(((three.first as Map)['geometry'] as Map)['coordinates'], hasLength(4));
    expect(
      three.whereType<Map<String, Object>>().where((f) => (f['geometry']! as Map)['type'] == 'Point'),
      hasLength(3),
    );
  });

  test('?area= opens the area in focus without signing in; a turned-off link says so', () async {
    backend.linked = const LinkedArea(name: 'Camp', color: '#365b25', ring: square, areaM2: 12000, perimeterM: 440);
    final c = container();
    await c.read(sharedLinkProvider.notifier).open(const AreaLink('0123456789abcdef0123456789abcdef'));
    final v = c.read(sharedLinkProvider)! as SharedArea;
    expect((v.status, v.area!.name), (LinkStatus.ok, 'Camp'));
    expect(c.read(fitPointsProvider), square);
    expect(c.read(sharedLinkProvider.notifier).openedFromLink, isTrue);

    backend.linked = null;
    await c.read(sharedLinkProvider.notifier).open(const AreaLink('0123456789abcdef0123456789abcdef'));
    expect((c.read(sharedLinkProvider)! as SharedArea).status, LinkStatus.gone);
  });

  group('contours uploaded on the website', () {
    test('index lines like contourGeo.ts (1:4, or 1:5 at 5, 10 and 100 m)', () {
      expect([5, 10, 12.5, 25, 50, 100, 125, 20].map((v) => indexIntervalFor(v.toDouble())), [
        25,
        50,
        50,
        100,
        200,
        500,
        500,
        80,
      ]);
      expect((isIndexLine(1200, 12.5), isIndexLine(1212.5, 12.5), isIndexLine(-50, 12.5)), (true, false, true));
      expect(isIndexLine(null, 10), isFalse);
      // Without a known interval every line is drawn as an index line
      final f =
          contourLinesGeoJson([(data: lines(), intervalM: 12.5), (data: lines(), intervalM: null)])['features']!
              as List;
      expect([for (final x in f) ((x as Map)['properties'] as Map)['index']], [true, false, true, true]);
    });

    test('loading knows which areas have contours; focusing one shows them; hide and show', () async {
      backend
        ..rows = [_area('a1'), _area('a2')]
        ..meta = [
          AreaContourMeta.fromRow({
            'area_id': 'a1',
            'source_name': 'kontur.shp',
            'source_format': 'shp',
            'interval_m': 12.5,
            'line_count': 2,
            'min_elevation': 1200,
            'max_elevation': 1212.5,
          }),
        ]
        ..contourData['a1'] = lines();
      final c = container();
      await settle();
      expect(c.read(areasProvider).contourMeta.keys, ['a1']);
      expect(c.read(areasProvider).shownContours, isEmpty, reason: 'lines are loaded only when needed');

      final rec = c.read(areasProvider.notifier)..focus('a2');
      await settle();
      expect(backend.calls.where((x) => x.startsWith('contours')), isEmpty, reason: 'a2 has none');
      rec.focus('a1');
      await settle();
      expect(c.read(areasProvider).contourSets.single.intervalM, 12.5);

      rec.hideContours('a1');
      expect(c.read(areasProvider).shownContours, isEmpty);
      await rec.showContours('a1');
      await rec.showContours('a1');
      expect(backend.calls.where((x) => x == 'contours:a1'), hasLength(2), reason: 'not again while shown');

      await rec.delete('a1');
      expect(c.read(areasProvider).contourMeta, isEmpty);
      expect(c.read(areasProvider).shownContours, isEmpty);
    });

    test('a shared area brings its contours', () async {
      backend
        ..linked = LinkedArea(name: 'Kawah', color: '#E46C24', ring: square, areaM2: 1, perimeterM: 1)
        ..linkedContours = (data: lines(), intervalM: 12.5);
      final c = container();
      await settle();
      await c.read(sharedLinkProvider.notifier).open(const AreaLink('0123456789abcdef0123456789abcdef'));
      final v = c.read(sharedLinkProvider)! as SharedArea;
      expect(v.contours?.intervalM, 12.5);
    });
  });

  group('screens', () {
    Future<ProviderContainer> pump(WidgetTester tester, Widget child, {Plan plan = Plan.pro}) async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final c = container(plan: plan);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(padding: const EdgeInsets.all(12), child: child),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('the drawing bar: Done only with 3 points, then the form', (tester) async {
      final c = await pump(
        tester,
        Consumer(builder: (_, ref, _) => ref.watch(areasProvider).drawing ? const AreaDrawingBar() : const AreaPanel()),
      );
      c.read(areasProvider.notifier).setPanelOpen(true);
      await tester.pump();
      await tester.tap(find.byKey(const Key('area-add')));
      await tester.pump();
      expect(find.text('Tap the map to add the corners of the area'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('area-done'))).onPressed, isNull);
      for (final p in square.take(3)) {
        c.read(areasProvider.notifier).addPoint(p);
      }
      await tester.pump();
      expect(find.textContaining('3 points ·'), findsOneWidget);
      await tester.tap(find.byKey(const Key('area-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('area-name')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('area-name')), 'Pos 5');
      await tester.tap(find.byKey(const Key('area-color-#b4302a')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('area-save')));
      await tester.pumpAndSettle();
      expect(backend.calls, ['create:Pos 5']);
      expect(c.read(areasProvider).areas.single.color, '#b4302a');
      expect(find.text('Pos 5'), findsOneWidget, reason: 'back in the list');
    });

    testWidgets('Free plan at its limit cannot add', (tester) async {
      backend.rows = [
        for (var i = 0; i < 5; i++)
          MarkedArea(
            id: 'a$i',
            userId: 'u1',
            name: 'Area $i',
            color: '#d49b22',
            ring: square,
            areaM2: 1,
            perimeterM: 1,
          ),
      ];
      final c = await pump(tester, const AreaPanel(), plan: Plan.free);
      c.read(areasProvider.notifier).setPanelOpen(true);
      await tester.pumpAndSettle();
      expect(find.text('5 / 5'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('area-add'))).onPressed, isNull);
      expect(find.textContaining('Free plan allows 5 areas'), findsOneWidget);
    });

    testWidgets('the area link card shows its size and owner', (tester) async {
      backend.linked = const LinkedArea(
        name: 'Camp',
        color: '#365b25',
        ring: square,
        areaM2: 12000,
        perimeterM: 440,
        ownerName: 'Rina',
        notes: 'Bring water',
      );
      final c = await pump(tester, const SharedLinkCard());
      await c.read(sharedLinkProvider.notifier).open(const AreaLink('0123456789abcdef0123456789abcdef'));
      await tester.pump();
      expect(find.text('Camp'), findsOneWidget);
      expect(find.text('1.20 ha · perimeter 440.0 m · shared by Rina'), findsOneWidget);
      expect(find.text('Bring water'), findsOneWidget);
      expect(areaLinkUrl('x'), endsWith('/?area=x'));
    });
  });
}
