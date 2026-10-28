import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/offline/offline_maps.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/map/map_settings.dart';
import 'package:landscape360/domain/map/offline_regions.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:landscape360/features/offline/offline_state.dart';
import 'package:landscape360/features/offline/offline_ui.dart';

// Offline maps: the plan's limits, downloads with progress, areas saved on another phone,
// a stopped download, deleting, and the frame's bar

const gede = OfflineBounds(west: 106.95, south: -6.82, east: 107.02, north: -6.75);

class FakeRecords implements OfflineRecords {
  List<OfflineRegionRecord> rows = [];
  final calls = <String>[];
  String? refuse;

  @override
  Future<List<OfflineRegionRecord>> list(String userId) async => rows;

  @override
  Future<void> add(String userId, OfflineRegionRecord r) async {
    final why = refuse;
    if (why != null) throw OfflineException(why);
    calls.add('add:${r.name}:${r.minZoom}-${r.maxZoom}');
    rows = [...rows, r];
  }

  @override
  Future<void> delete(String userId, String id) async => calls.add('delete:$id');
}

class FakeEngine implements OfflineEngine {
  final stored0 = <String, int>{};
  final downloads = <String, Completer<void>>{};
  final styles = <String, List<MapStyle>>{};
  void Function(double)? progress;

  @override
  Future<void> download({
    required String id,
    required String name,
    required OfflineBounds bounds,
    required int minZoom,
    required int maxZoom,
    required List<MapStyle> styles,
    required void Function(double) onProgress,
  }) {
    progress = onProgress;
    this.styles[id] = styles;
    final c = downloads[id] = Completer<void>();
    return c.future.then((_) => stored0[id] = 4 * 1024 * 1024);
  }

  @override
  Future<void> remove(String id) async => stored0.remove(id);

  @override
  Future<Map<String, int>> stored() async => Map.of(stored0);
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
  late FakeRecords records;
  late FakeEngine engine;

  setUp(() {
    records = FakeRecords();
    engine = FakeEngine();
  });

  ProviderContainer container({Plan plan = Plan.pro}) {
    final c = ProviderContainer(
      overrides: [
        offlineRecordsProvider.overrideWithValue(records),
        offlineEngineProvider.overrideWithValue(engine),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith((ref) async => _profile(plan)),
      ],
    );
    addTearDown(c.dispose);
    c
      ..listen(offlineProvider, (_, _) {})
      ..listen(profileProvider, (_, _) {})
      ..listen(flyToProvider, (_, _) {});
    return c;
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  group('rules', () {
    test('zoom levels: the current one and two deeper, at most 16', () {
      expect(offlineZoomRange(13.7), (13, 15));
      expect(offlineZoomRange(15.2), (15, 16));
    });

    test('size estimate like the web (satellite + elevation 50 KB, map 20 KB a tile)', () {
      expect(estimateOfflineMb(93, satellite: true, map: true), 6.51);
      expect(estimateOfflineMb(93, satellite: false, map: true), 1.86);
    });

    test('limits per plan, admins as Enterprise', () {
      expect(offlineLimits('Free'), (count: 1, sizeMb: 1.0));
      expect(offlineLimits('Pro'), (count: 3, sizeMb: 10.0));
      expect(offlineLimits('Free', isAdmin: true), (count: 10, sizeMb: 25.0));
      expect(offlineLimitError(plan: 'Free', isAdmin: false, existing: 1, sizeMb: 0.1), contains('maximum number'));
      expect(
        offlineLimitError(plan: 'Pro', isAdmin: false, existing: 0, sizeMb: 10.5),
        contains('larger than the 10 MB'),
      );
      expect(offlineLimitError(plan: 'Pro', isAdmin: false, existing: 2, sizeMb: 9.9), isNull);
    });
  });

  test('download: saved in the account, then progress, then on this phone', () async {
    final c = container();
    await settle();
    final rec = c.read(offlineProvider.notifier);
    final plan = OfflinePlan.of(gede, 13.4, satellite: true, map: false);
    expect((plan.minZoom, plan.maxZoom, plan.tiles), (13, 15, 93));

    expect(await rec.download('  ', plan, satellite: true, map: false), 'Give the area a name');
    expect(await rec.download('Gede', plan, satellite: false, map: false), 'Choose satellite, map or both');
    expect(await rec.download('Gede', plan, satellite: true, map: false), isNull);
    expect(records.calls, ['add:Gede:13-15']);
    final id = records.rows.single.id;
    expect(engine.styles[id], [MapStyle.satellite]);
    expect(c.read(offlineProvider).regions.single.status, OfflineStatus.downloading);

    engine.progress!(0.4);
    expect(c.read(offlineProvider).regions.single.progress, 0.4);
    engine.downloads[id]!.complete();
    await settle();
    final v = c.read(offlineProvider).regions.single;
    expect((v.status, v.bytes), (OfflineStatus.ready, 4 * 1024 * 1024));
  });

  test('the limits are checked before anything is saved; the server can still refuse', () async {
    records.rows = [
      const OfflineRegionRecord(
        id: 'a',
        name: 'A',
        bounds: gede,
        minZoom: 13,
        maxZoom: 15,
        tileCount: 1,
        sizeEstMb: 0.1,
      ),
    ];
    final free = container(plan: Plan.free);
    await settle();
    final plan = OfflinePlan.of(gede, 13, satellite: true, map: true);
    expect(
      await free.read(offlineProvider.notifier).download('B', plan, satellite: true, map: true),
      contains('maximum number'),
    );
    expect(records.calls, isEmpty);

    records
      ..rows = []
      ..refuse = 'Map size (6.51) exceeds the limit of 1 MB for Free plan.';
    final pro = container();
    await settle();
    expect(
      await pro.read(offlineProvider.notifier).download('B', plan, satellite: true, map: true),
      contains('exceeds'),
    );
    expect(engine.downloads, isEmpty, reason: 'nothing downloaded when the server says no');
  });

  test('an area saved on another phone, a stopped download, and deleting', () async {
    records.rows = [
      const OfflineRegionRecord(
        id: 'x',
        name: 'From the tablet',
        bounds: gede,
        minZoom: 13,
        maxZoom: 15,
        tileCount: 93,
        sizeEstMb: 6.5,
      ),
    ];
    final c = container();
    await settle();
    final rec = c.read(offlineProvider.notifier);
    expect(c.read(offlineProvider).regions.single.status, OfflineStatus.notOnPhone);

    unawaited(rec.downloadAgain(records.rows.single));
    await settle();
    engine.downloads['x']!.completeError(Exception('network down'));
    await settle();
    expect(c.read(offlineProvider).regions.single.status, OfflineStatus.failed);
    expect(c.read(offlineProvider).error, contains('network down'));

    unawaited(rec.downloadAgain(records.rows.single));
    await settle();
    engine.downloads['x']!.complete();
    await settle();
    expect(c.read(offlineProvider).regions.single.status, OfflineStatus.ready);

    await rec.delete(records.rows.single);
    expect(records.calls, ['delete:x']);
    expect(c.read(offlineProvider).records, isEmpty);
    expect(engine.stored0, isEmpty);
  });

  group('screens', () {
    testWidgets('the bar measures the frame and refuses an area too large for the plan', (tester) async {
      final c = container(plan: Plan.free);
      // A frame that covers the Gede box at zoom 13
      c
          .read(mapProjectionProvider.notifier)
          .set(
            (x, y) async =>
                (gede.west + (gede.east - gede.west) * x / 400, gede.north - (gede.north - gede.south) * y / 400),
          );
      c.read(mapZoomProvider.notifier).set(13);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: OfflineBar(frame: Rect.fromLTRB(0, 0, 400, 400)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Zoom 13–15 · 93 tiles · ≈ 6.51 MB of 1 MB'), findsOneWidget);
      expect(find.textContaining('Too large for your plan'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('offline-download'))).onPressed, isNull);

      // Map only, two levels deeper: ~1.86 MB, still too big for Free; zoomed in it fits
      await tester.tap(find.byKey(const Key('offline-satellite')));
      await tester.pumpAndSettle();
      expect(find.textContaining('≈ 1.86 MB'), findsOneWidget);
    });

    testWidgets('the list shows each area and what is on this phone', (tester) async {
      records.rows = [
        const OfflineRegionRecord(
          id: 'a',
          name: 'Gede',
          bounds: gede,
          minZoom: 13,
          maxZoom: 15,
          tileCount: 93,
          sizeEstMb: 6.51,
        ),
        const OfflineRegionRecord(
          id: 'b',
          name: 'Merbabu',
          bounds: gede,
          minZoom: 12,
          maxZoom: 14,
          tileCount: 22,
          sizeEstMb: 1.54,
        ),
      ];
      engine.stored0['a'] = 5 * 1024 * 1024;
      final c = container();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(onPressed: () => showOfflineSheet(context), child: const Text('go')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('2 of 3 maps · up to 10 MB each · 5.0 MB on this phone'), findsOneWidget);
      expect(find.text('On this phone · 5.0 MB'), findsOneWidget);
      expect(find.text('Not on this phone (saved in your account)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('offline-new')));
      await tester.pumpAndSettle();
      expect(c.read(offlineProvider).framing, isTrue);
    });
  });
}
