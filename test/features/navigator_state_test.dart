import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/data/survey/survey_repository.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/survey/survey_model.dart';
import 'package:landscape360/domain/survey/survey_utils.dart';
import 'package:landscape360/features/navigator/navigator_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

// The Navigator's saving rules, same as useSurveyStore on the web (and its tests)

class FakeSurveys implements SurveyBackend {
  final rows = <String, (String, List<SurveyGroup>)>{};
  final calls = <String>[];
  bool offline = false;
  int _n = 0;

  @override
  Future<List<SavedSurvey>> list(String userId) async {
    calls.add('list');
    if (offline) throw Exception('offline');
    return [for (final e in rows.entries) SavedSurvey(id: e.key, name: e.value.$1, updatedAt: '')];
  }

  @override
  Future<(String, List<SurveyGroup>)> load(String id) async {
    calls.add('load:$id');
    if (offline) throw Exception('offline');
    return rows[id]!;
  }

  @override
  Future<SavedSurvey> save({
    required String userId,
    String? id,
    required String name,
    required List<SurveyGroup> groups,
  }) async {
    calls.add(id == null ? 'insert:$name' : 'update:$id');
    if (offline) throw Exception('offline');
    final key = id ?? 'row${++_n}';
    rows[key] = (name, groups);
    return SavedSurvey(id: key, name: name, updatedAt: '2026-10-29T00:00:00Z');
  }

  @override
  Future<void> delete(String id, String userId) async {
    calls.add('delete:$id');
    rows.remove(id);
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

Future<double> _flat(double lng, double lat) async => 100;

void main() {
  late FakeSurveys backend;
  late StreamController<String?> auth;

  ProviderContainer container({Plan plan = Plan.free, bool admin = false}) {
    final c = ProviderContainer(
      overrides: [
        surveyBackendProvider.overrideWithValue(backend),
        authUserIdProvider.overrideWith((ref) => auth.stream),
        profileProvider.overrideWith((ref) async => _profile(plan, admin: admin)),
      ],
    );
    addTearDown(c.dispose);
    c.listen(navigatorProvider, (_, _) {}); // keep it alive
    c.listen(profileProvider, (_, _) {});
    return c;
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    backend = FakeSurveys();
    auth = StreamController<String?>.broadcast();
    addTearDown(auth.close);
  });

  test('signed out: points stay on the phone, nothing goes to the cloud', () async {
    final c = container();
    auth.add(null);
    await settle();
    final nav = c.read(navigatorProvider.notifier)..open();
    await nav.addPointAt(106.8, -6.2, _flat);
    await nav.saveNow();
    expect(c.read(navigatorProvider).doc.groups.single.points.single.elevation, 100);
    expect(backend.calls.where((x) => x.startsWith('insert') || x.startsWith('update')), isEmpty);
  });

  test('signed in: the first save inserts, later edits update the same survey', () async {
    final c = container(plan: Plan.pro);
    auth.add('u1');
    await settle();
    final nav = c.read(navigatorProvider.notifier)..open();
    await nav.addPointAt(106.8, -6.2, _flat);
    await nav.saveNow();
    expect(backend.calls, contains('insert:Survey 1'));
    final id = c.read(navigatorProvider).currentSurveyId!;
    await nav.addPointAt(106.801, -6.2, _flat);
    await nav.saveNow();
    expect(backend.calls.last, 'update:$id');
    expect(c.read(navigatorProvider).dirty, isFalse);
    expect(c.read(navigatorProvider).saved.first.id, id);
  });

  test('edits are saved automatically shortly after, several edits in one save', () async {
    final c = container(plan: Plan.pro);
    auth.add('u1');
    await settle();
    final nav = c.read(navigatorProvider.notifier)..open();
    await nav.addPointAt(106.8, -6.2, _flat);
    await nav.addPointAt(106.801, -6.2, _flat);
    await nav.addPointAt(106.802, -6.2, _flat);
    expect(backend.calls.where((x) => x.startsWith('insert')), isEmpty);
    await Future<void>.delayed(NavigatorController.saveDelay + const Duration(milliseconds: 100));
    expect(backend.calls.where((x) => x.startsWith('insert')), hasLength(1));
    expect(backend.rows.values.single.$2.single.points, hasLength(3));
  });

  test('Free limit (2): a new survey is refused without calling the server', () async {
    backend.rows['a'] = ('A', const []);
    backend.rows['b'] = ('B', const []);
    final c = container();
    auth.add('u1');
    await settle();
    final nav = c.read(navigatorProvider.notifier)..open();
    await nav.addPointAt(106.8, -6.2, _flat);
    backend.calls.clear();
    await nav.saveNow();
    expect(c.read(navigatorProvider).error, 'Survey limit reached for "Free plan" (max : 2).');
    expect(backend.calls, isEmpty);
  });

  test('an existing survey still saves when the limit is reached; admins count as Enterprise', () async {
    backend.rows['a'] = ('A', const []);
    backend.rows['b'] = ('B', const []);
    final c = container();
    auth.add('u1');
    await settle();
    final nav = c.read(navigatorProvider.notifier);
    await nav.loadSurvey('a');
    await nav.addPointAt(106.8, -6.2, _flat);
    await nav.saveNow();
    expect(backend.calls.last, 'update:a');

    final admin = container(plan: Plan.free, admin: true);
    auth.add('u1');
    await settle();
    final a = admin.read(navigatorProvider.notifier)..newSurvey();
    admin.read(navigatorProvider.notifier).open();
    await a.addPointAt(1, 1, _flat);
    await a.saveNow();
    expect(admin.read(navigatorProvider).error, isNull);
  });

  test('offline: kept as not synced, sent with the next save', () async {
    final c = container(plan: Plan.pro);
    auth.add('u1');
    await settle();
    final nav = c.read(navigatorProvider.notifier)..open();
    backend.offline = true;
    await nav.addPointAt(106.8, -6.2, _flat);
    await nav.saveNow();
    expect((c.read(navigatorProvider).dirty, c.read(navigatorProvider).error), (true, null));
    backend.offline = false;
    await nav.saveNow();
    expect((c.read(navigatorProvider).dirty, backend.rows.length), (false, 1));
  });

  test('opening a survey replaces the drawing; deleting the open one keeps it as new', () async {
    backend.rows['s1'] = (
      'Gede',
      surveyFromJson([
        {
          'id': 'g',
          'name': 'Gede',
          'color': '#FFD700',
          'points': [
            {'id': 'p', 'lng': 106.98, 'lat': -6.79, 'elevation': 2958},
          ],
        },
      ]),
    );
    final c = container(plan: Plan.pro);
    auth.add('u1');
    await settle();
    final nav = c.read(navigatorProvider.notifier);
    final doc = await nav.loadSurvey('s1');
    expect(doc!.bounds, ((106.98, -6.79), (106.98, -6.79)));
    expect((c.read(navigatorProvider).enabled, c.read(navigatorProvider).currentSurveyId), (true, 's1'));
    await nav.deleteSurvey('s1');
    expect((c.read(navigatorProvider).currentSurveyId, c.read(navigatorProvider).doc.groups.length), (null, 1));
    expect(backend.rows, isEmpty);
  });

  test('the survey and the straight mode survive closing the app', () async {
    final c = container(plan: Plan.pro);
    auth.add(null);
    await settle();
    final nav = c.read(navigatorProvider.notifier)
      ..open()
      ..setStraight(true)
      ..setAngleStep(45);
    await nav.addPointAt(106.8, -6.2, _flat);
    await settle();
    c.dispose();

    final again = ProviderContainer(
      overrides: [
        surveyBackendProvider.overrideWithValue(backend),
        authUserIdProvider.overrideWith((ref) => Stream.value(null)),
      ],
    );
    addTearDown(again.dispose);
    again.listen(navigatorProvider, (_, _) {});
    await settle();
    final s = again.read(navigatorProvider);
    expect((s.straight, s.angleStep, s.doc.groups.single.points.length), (true, 45, 1));
  });

  test('signing out clears the survey from the phone', () async {
    final c = container(plan: Plan.pro);
    auth.add('u1');
    await settle();
    final nav = c.read(navigatorProvider.notifier)..open();
    await nav.addPointAt(106.8, -6.2, _flat);
    auth.add(null);
    await settle();
    expect(c.read(navigatorProvider).doc.groups, isEmpty);
    expect(await SharedPreferencesAsync().getString('l360-survey-store'), isNot(contains('106.8')));
  });

  test('straight mode snaps and sharpens; tiny handles are removed', () async {
    final c = container();
    auth.add(null);
    await settle();
    final nav = c.read(navigatorProvider.notifier)
      ..open()
      ..setStraight(true)
      ..setAngleStep(90);
    await nav.addPointAt(106.75, -6.235, _flat);
    await nav.addPointAt(106.75, -6.234, _flat);
    await nav.addPointAt(106.751, -6.2338, _flat);
    final pts = c.read(navigatorProvider).doc.groups.single.points;
    expect(pts[1].corner, PointCorner.sharp);
    expect(pts[2].lat, closeTo(-6.234, 1e-6));
    final g = c.read(navigatorProvider).doc.groups.single;
    nav.setHandle(g.id, pts[0].id, const SurveyHandle(east: 0.1, north: 0.1));
    expect(c.read(navigatorProvider).doc.groups.single.points.first.handle, isNull);
  });

  test('opening a survey never saves an empty one to the cloud', () async {
    backend.rows['s1'] = ('Gede', const []);
    final c = container(plan: Plan.pro);
    auth.add('u1');
    await settle();
    await c.read(navigatorProvider.notifier).loadSurvey('s1');
    expect(backend.calls.where((x) => x.startsWith('insert')), isEmpty);
  });

  test('quick taps keep their order even when the first elevation is slower', () async {
    final c = container();
    auth.add(null);
    await settle();
    final nav = c.read(navigatorProvider.notifier)
      ..open()
      ..setStraight(true)
      ..setAngleStep(90);
    await nav.addPointAt(106.75, -6.235, _flat);
    // The first of two quick taps answers its elevation later than the second
    Future<double> slow(double lng, double lat) => Future.delayed(const Duration(milliseconds: 60), () => 1);
    Future<double> fast(double lng, double lat) async => 2;
    final a = nav.addPointAt(106.75, -6.234, slow);
    final b = nav.addPointAt(106.751, -6.2338, fast);
    await Future.wait([a, b]);
    final pts = c.read(navigatorProvider).doc.groups.single.points;
    expect(pts.map((p) => p.elevation), [100, 1, 2]);
    // The third point snapped against the second (a right turn), so its latitude is the second's
    expect(pts[2].lat, closeTo(-6.234, 1e-6));
  });

  test('taps do nothing while the Navigator is closed', () async {
    final c = container();
    await c.read(navigatorProvider.notifier).addPointAt(1, 1, _flat);
    expect(c.read(navigatorProvider).doc.groups, isEmpty);
  });
}
