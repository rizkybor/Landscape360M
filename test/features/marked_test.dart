import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/marked/marked_location_repository.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/marked/marked_locations.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:landscape360/features/marked/marked_sheet.dart';
import 'package:landscape360/features/marked/marked_state.dart';

// Marked Locations: what the list and the map show, saving, sharing, links, picking

MarkedLocation loc(String id, {String user = 'u1', String name = 'Pos 3', List<String> tags = const []}) =>
    MarkedLocation(
      id: id,
      userId: user,
      name: name,
      category: MarkedLocationCategory.shelter,
      lat: -6.78,
      lng: 106.98,
      elevationM: 2100,
      tags: tags,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

class FakeMarked implements MarkedLocationBackend {
  List<MarkedLocation> rows = [];
  List<OwnedLocation> sharedRows = [];
  List<OwnedLocation> allRows = [];
  final calls = <String>[];
  String? token;
  int _n = 0;

  @override
  Future<List<MarkedLocation>> mine(String userId) async => rows;

  @override
  Future<List<OwnedLocation>> sharedWithMe() async => sharedRows;

  @override
  Future<List<OwnedLocation>> all() async => allRows;

  @override
  Future<MarkedLocation> create(MarkedLocationInput input) async {
    calls.add('create:${input.name}:${input.toRow()['tags']}');
    final l = MarkedLocation(
      id: 'new${++_n}',
      userId: 'u1',
      name: input.name.trim(),
      category: input.category,
      lat: input.lat,
      lng: input.lng,
      elevationM: input.elevationM,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    rows = [l, ...rows];
    return l;
  }

  @override
  Future<MarkedLocation> update(String id, MarkedLocationInput input) async {
    calls.add('update:$id:${input.name}');
    return loc(id, name: input.name);
  }

  @override
  Future<void> delete(String id) async => calls.add('delete:$id');

  @override
  Future<ShareResult> share(List<String> ids, String recipient) async {
    calls.add('share:${ids.join(',')}:$recipient');
    return ShareResult(userId: 'r1', name: 'Budi', emailMasked: 'b***@x.id', sharedCount: ids.length);
  }

  @override
  Future<List<ShareSuggestion>> suggestions(String query) async => query.isEmpty
      ? const [ShareSuggestion(userId: 'r1', name: 'Budi', emailMasked: 'b***@x.id', recent: true)]
      : const [];

  @override
  Future<List<LocationShare>> shares(String id) async => const [];

  @override
  Future<void> removeShare(String id, String recipientId) async => calls.add('remove:$id:$recipientId');

  @override
  Future<String?> link(String id) async => token;

  @override
  Future<String> createLink(String id) async => token = '0123456789abcdef0123456789abcdef';

  @override
  Future<void> revokeLink(String id) async {
    calls.add('revoke-link:$id');
    token = null;
  }
}

AccountProfile _profile(Plan plan, {bool admin = false}) => AccountProfile(
  userId: 'u1',
  email: 'u@x.id',
  displayName: 'U',
  plan: plan,
  role: UserRole.pengguna360,
  isAdmin: admin,
  canUseSos: false,
);

void main() {
  late FakeMarked backend;

  setUp(() => backend = FakeMarked());

  ProviderContainer container({Plan plan = Plan.pro, bool admin = false}) {
    final c = ProviderContainer(
      overrides: [
        markedBackendProvider.overrideWithValue(backend),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith((ref) async => _profile(plan, admin: admin)),
      ],
    );
    addTearDown(c.dispose);
    c
      ..listen(markedProvider, (_, _) {})
      ..listen(profileProvider, (_, _) {})
      ..listen(flyToProvider, (_, _) {});
    return c;
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  test('signing in loads mine and shared; the map shows each once, mine first', () async {
    backend
      ..rows = [loc('a')]
      ..sharedRows = [OwnedLocation(loc('b', user: 'u2'), owner: 'Budi'), OwnedLocation(loc('a'), owner: 'x')]
      ..allRows = [OwnedLocation(loc('c', user: 'u3'), owner: 'c@x.id')];
    final c = container(admin: true);
    await settle();
    var visible = c.read(markedProvider).visible;
    expect({for (final v in visible) v.location.id: v.kind}, {'a': MarkedKind.mine, 'b': MarkedKind.shared});

    c.read(markedProvider.notifier).setShowAllOnMap(true);
    await settle();
    visible = c.read(markedProvider).visible;
    expect(visible.map((v) => v.location.id).toSet(), {'a', 'b', 'c'});
    expect(visible.firstWhere((v) => v.location.id == 'c').owner, 'c@x.id');
  });

  test('plan rules for the list (the server checks them again)', () async {
    final free = container(plan: Plan.free);
    await settle();
    final p = free.read(markedProvider.notifier).policy;
    expect((p.maxLocations, p.canShare), (10, false));
  });

  test('create, edit and delete keep the list and the open location in step', () async {
    final c = container();
    await settle();
    final rec = c.read(markedProvider.notifier);
    final created = await rec.create(
      MarkedLocationInput(
        name: '  Mata air  ',
        category: MarkedLocationCategory.water,
        lat: -6.77,
        lng: 106.97,
        tags: parseTags('water, Water, 2024'),
      ),
    );
    expect(backend.calls.single, 'create:  Mata air  :[water, 2024]');
    expect(c.read(markedProvider).mine.first.id, created.id);

    rec.select(created.id);
    await rec.update(
      created.id,
      const MarkedLocationInput(name: 'Mata air 2', category: MarkedLocationCategory.water, lat: 0, lng: 0),
    );
    expect(c.read(markedProvider).mine.first.name, 'Mata air 2');

    await rec.delete(created.id);
    expect(c.read(markedProvider).mine, isEmpty);
    expect(c.read(markedProvider).selectedId, isNull);
  });

  test('a recipient removes a shared location from their own list', () async {
    backend.sharedRows = [OwnedLocation(loc('b', user: 'u2'), owner: 'Budi')];
    final c = container();
    await settle();
    await c.read(markedProvider.notifier).leaveShared('b');
    expect(backend.calls, ['remove:b:u1']);
    expect(c.read(markedProvider).shared, isEmpty);
  });

  test('tapping a marker opens it, tapping again closes it; picking clears the selection', () async {
    backend.rows = [loc('a')];
    final c = container();
    await settle();
    final rec = c.read(markedProvider.notifier)..toggle('a');
    expect(c.read(markedProvider).selected?.location.id, 'a');
    rec.toggle('a');
    expect(c.read(markedProvider).selectedId, isNull);

    rec
      ..toggle('a')
      ..startPicking();
    expect((c.read(markedProvider).picking, c.read(markedProvider).selectedId), (true, null));
    rec.setPicked((lng: 106.9, lat: -6.7, elevationM: 1500));
    expect(c.read(markedProvider).picking, isFalse);
    expect(c.read(markedProvider).picked?.elevationM, 1500);
  });

  test('form checks and rows match the web', () {
    expect(markedFormError(name: ' ', lat: '1', lng: '1', elevation: ''), 'Name is required');
    expect(markedFormError(name: 'x', lat: '91', lng: '1', elevation: ''), startsWith('Set a valid position'));
    expect(markedFormError(name: 'x', lat: '-6.7', lng: '106.9', elevation: 'abc'), 'Elevation must be a number');
    expect(markedFormError(name: 'x', lat: '-6.7', lng: '106.9', elevation: ''), isNull);
    expect(roundCoord(-6.7471234567), '-6.747123');
    expect(roundCoord(107), '107');
    expect(
      const MarkedLocationInput(
        name: ' A ',
        category: MarkedLocationCategory.cave,
        lat: 1,
        lng: 2,
        address: '  ',
      ).toRow(),
      {
        'name': 'A',
        'category': 'cave',
        'lng': 2.0,
        'lat': 1.0,
        'elevation_m': null,
        'description': null,
        'address': null,
        'contact': null,
        'tags': <String>[],
      },
    );
    expect(loc('a', tags: ['camp']).matches('CAMP'), isTrue);
    expect(loc('a').matches('shelter'), isTrue, reason: 'the category label is searched too');
    expect(loc('a').matches('zzz'), isFalse);
    expect(recipientLabel('Budi', 'b***@x.id'), 'Budi (b***@x.id)');
    expect(recipientLabel(null, null), 'Unknown account');
  });

  group('screens', () {
    Future<ProviderContainer> pump(
      WidgetTester tester,
      Widget Function(BuildContext, WidgetRef) open, {
      Plan plan = Plan.pro,
    }) async {
      tester.view.physicalSize = const Size(1179, 4200); // tall enough for the whole form
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final c = container(plan: plan);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: Consumer(builder: (context, ref, _) => Center(child: open(context, ref))),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('the list: search, limit reached, add disabled', (tester) async {
      backend.rows = [for (var i = 0; i < 10; i++) loc('l$i', name: i == 3 ? 'Kandang Badak' : 'Pos $i')];
      await pump(
        tester,
        (context, ref) =>
            TextButton(onPressed: () => showMarkedSheet(context, markedHost(ref)), child: const Text('go')),
        plan: Plan.free,
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('10 / 10'), findsOneWidget);
      expect(find.textContaining('10-location limit'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('marked-add'))).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('marked-search')), 'badak');
      await tester.pump();
      expect(find.text('Kandang Badak'), findsOneWidget);
      expect(find.text('Pos 1'), findsNothing);
    });

    testWidgets('the form checks the fields, then saves and shows the location', (tester) async {
      final c = await pump(
        tester,
        (context, ref) => TextButton(
          onPressed: () => openMarkedForm(context, markedHost(ref), const MarkedDraft()),
          child: const Text('go'),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('marked-save')));
      await tester.pump();
      expect(find.text('Name is required'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('marked-name')), 'Mata air');
      await tester.tap(find.byKey(const Key('marked-cat-water')));
      await tester.enterText(find.byKey(const Key('marked-lat')), '-6.77');
      await tester.enterText(find.byKey(const Key('marked-lng')), '106.97');
      await tester.tap(find.byKey(const Key('marked-save')));
      await tester.pumpAndSettle();
      expect(backend.calls.single, startsWith('create:Mata air'));
      final saved = c.read(markedProvider).mine.single;
      expect((saved.category, c.read(markedProvider).selectedId), (MarkedLocationCategory.water, saved.id));
      expect(c.read(flyToProvider)?.lat, -6.77);
      expect(find.byKey(const Key('marked-save')), findsNothing, reason: 'back on the map');
    });

    testWidgets('Pick on map keeps what was typed and starts picking', (tester) async {
      final c = await pump(
        tester,
        (context, ref) => TextButton(
          onPressed: () => openMarkedForm(context, markedHost(ref), const MarkedDraft()),
          child: const Text('go'),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('marked-name')), 'Puncak');
      await tester.tap(find.byKey(const Key('marked-pick')));
      await tester.pumpAndSettle();
      expect(c.read(markedProvider).picking, isTrue);
      expect(c.read(markedDraftProvider)?.name, 'Puncak');
    });

    testWidgets('sharing: a recent recipient, then a link that can be turned off', (tester) async {
      backend.rows = [loc('a')];
      await pump(
        tester,
        (context, ref) => TextButton(onPressed: () => showMarkedShareSheet(context, ['a']), child: const Text('go')),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Recent'), findsOneWidget);
      await tester.tap(find.text('Budi (b***@x.id)'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('share:a:r1'));
      expect(find.textContaining('Shared location with Budi'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('link-create')));
      await tester.tap(find.byKey(const Key('link-create')));
      await tester.pumpAndSettle();
      expect(find.textContaining('?place=0123456789abcdef0123456789abcdef'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('link-off')));
      await tester.tap(find.byKey(const Key('link-off')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turn off').last); // the dialog's button
      await tester.pumpAndSettle();
      expect(backend.calls, contains('revoke-link:a'));
      expect(find.byKey(const Key('link-create')), findsOneWidget);
    });
  });
}
