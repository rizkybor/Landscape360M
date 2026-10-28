import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/basemaps/custom_basemaps.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/map/offline_regions.dart';
import 'package:landscape360/features/basemaps/basemap_sheet.dart';
import 'package:landscape360/features/basemaps/basemap_state.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

// Custom basemaps: who sees them, switching on (the picture comes to the phone), opacity
// kept on the phone, delete, and the sheet

const _box = OfflineBounds(west: 106.97, south: -6.80, east: 107.00, north: -6.77);

class FakeBasemaps implements BasemapBackend {
  List<CustomBasemap> rows = [];
  final calls = <String>[];
  bool failSwitch = false;

  @override
  Future<List<CustomBasemap>> list(String userId) async => rows;

  @override
  Future<void> setActive(String id, bool active) async {
    if (failSwitch) throw Exception('offline');
    calls.add('active:$id:$active');
  }

  @override
  Future<void> delete(CustomBasemap b) async => calls.add('delete:${b.id}');

  @override
  Future<Uint8List> download(String filePath) async {
    calls.add('download:$filePath');
    return Uint8List.fromList([1, 2, 3]);
  }
}

class MemoryFiles implements BasemapFiles {
  final saved = <String>{};

  @override
  Future<File?> get(String id) async => saved.contains(id) ? File('/phone/$id.png') : null;

  @override
  Future<File> save(String id, Uint8List bytes) async {
    saved.add(id);
    return File('/phone/$id.png');
  }

  @override
  Future<void> remove(String id) async => saved.remove(id);
}

CustomBasemap map(String id, {bool active = false, OfflineBounds? bounds = _box}) =>
    CustomBasemap(id: id, name: 'Peta $id', filePath: 'u1/$id.png', fileSize: 1200000, bounds: bounds, active: active);

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
  late FakeBasemaps cloud;
  late MemoryFiles files;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    cloud = FakeBasemaps();
    files = MemoryFiles();
  });

  ProviderContainer container({Plan plan = Plan.enterprise, bool admin = false}) {
    final c = ProviderContainer(
      overrides: [
        basemapBackendProvider.overrideWithValue(cloud),
        basemapFilesProvider.overrideWithValue(files),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith((ref) async => _profile(plan, admin: admin)),
        appConfigProvider.overrideWithValue(
          const AppConfig(
            flavor: 'dev',
            supabaseUrl: 'https://x.supabase.co',
            supabaseAnonKey: 'sb_publishable_x',
            mapboxPublicToken: '',
            apiBaseUrl: 'https://landscape360.jcdigital.co.id',
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    c
      ..listen(basemapsProvider, (_, _) {})
      ..listen(profileProvider, (_, _) {})
      ..listen(fitPointsProvider, (_, _) {});
    return c;
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  test('Enterprise and admin only (can_upload_custom_basemaps)', () async {
    final pro = container(plan: Plan.pro);
    final ent = container();
    final admin = container(plan: Plan.free, admin: true);
    await settle();
    expect([pro, ent, admin].map((c) => c.read(basemapsProvider.notifier).canUse), [false, true, true]);
  });

  test('only switched-on basemaps come to the phone, once', () async {
    cloud.rows = [map('a', active: true), map('b')];
    final c = container();
    await settle();
    expect(cloud.calls, ['download:u1/a.png']);
    expect(c.read(basemapsProvider).files, {'a': '/phone/a.png'});

    await c.read(basemapsProvider.notifier).setActive('b', true);
    expect(cloud.calls, ['download:u1/a.png', 'active:b:true', 'download:u1/b.png']);
    await c.read(basemapsProvider.notifier).refresh();
    expect(cloud.calls.where((x) => x.startsWith('download')), hasLength(2), reason: 'already on the phone');
  });

  test('a switch that fails goes back and says so', () async {
    cloud
      ..rows = [map('a')]
      ..failSwitch = true;
    final c = container();
    await settle();
    await c.read(basemapsProvider.notifier).setActive('a', true);
    expect(c.read(basemapsProvider).basemaps.single.active, isFalse);
    expect(c.read(basemapsProvider).error, contains('Could not switch'));
  });

  test('opacity is kept on the phone per account; delete removes the picture too', () async {
    cloud.rows = [map('a', active: true)];
    final c = container();
    await settle();
    c.read(basemapsProvider.notifier).setOpacity('a', 0.4);
    await settle();
    expect(await SharedPreferencesAsync().getString('l360-basemap-opacity-u1'), '{"a":0.4}');

    final again = container();
    await settle();
    expect(again.read(basemapsProvider).opacityOf('a'), 0.4);

    await c.read(basemapsProvider.notifier).delete(c.read(basemapsProvider).basemaps.single);
    expect(cloud.calls.last, 'delete:a');
    expect(files.saved, isEmpty);
    expect(c.read(basemapsProvider).basemaps, isEmpty);
  });

  test('a row reads like the web', () {
    final b = CustomBasemap.fromRow({
      'id': 'x',
      'name': 'Peta',
      'file_path': 'u1/p.png',
      'file_size': 2048,
      'bounds': {'north': -6.7, 'south': -6.8, 'east': 107, 'west': 106.9},
      'is_active': true,
    });
    expect((b.bounds!.west, b.bounds!.north, b.active), (106.9, -6.7, true));
    expect(CustomBasemap.fromRow({'id': 'y', 'name': 'n', 'file_path': 'p', 'bounds': null}).bounds, isNull);
  });

  group('sheet', () {
    Future<ProviderContainer> pump(WidgetTester tester, {Plan plan = Plan.enterprise}) async {
      final c = container(plan: plan);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(onPressed: () => showBasemapSheet(context), child: const Text('go')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('Pro sees the lock', (tester) async {
      await pump(tester, plan: Plan.pro);
      expect(find.textContaining('available for Enterprise accounts'), findsOneWidget);
    });

    testWidgets('switch, opacity and zoom', (tester) async {
      cloud.rows = [map('a'), map('b', active: true)];
      final c = await pump(tester);
      expect(find.text('Storage 2.3 MB of 5.0 MB'), findsOneWidget);
      expect(find.text('1.1 MB · on this phone'), findsOneWidget);
      expect(find.byKey(const Key('basemap-opacity-a')), findsNothing, reason: 'only for switched-on');

      await tester.tap(find.byKey(const Key('basemap-switch-a')));
      await tester.pumpAndSettle();
      expect(cloud.calls, contains('active:a:true'));
      expect(find.byKey(const Key('basemap-opacity-a')), findsOneWidget);

      await tester.tap(find.byKey(const Key('basemap-zoom-b')));
      await tester.pumpAndSettle();
      expect(c.read(fitPointsProvider), [(106.97, -6.80), (107.00, -6.77)]);
    });
  });
}
