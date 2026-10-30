import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/data/classic/classic_links.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/classic/classic_drawing.dart';
import 'package:landscape360/domain/classic/classic_nav.dart';
import 'package:landscape360/domain/classic/field_work.dart';
import 'package:landscape360/domain/geo/spherical.dart' show turfBearing;
import 'package:landscape360/domain/share/share_location.dart';
import 'package:landscape360/features/classic/classic_state.dart';
import 'package:landscape360/features/map/shared_links.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

// Classic: Field Works per mode and their plan limits, the order of the steps, picking on the
// map, remembering everything on the phone, and a shared Field Work kept up to date

class FakeClassicLinks implements ClassicLinks {
  final saves = <(String?, String, Map<String, Object>)>[];
  final revoked = <String>[];
  ViewedFieldWork? shared;
  String nextToken = '0123456789abcdef0123456789abcdef';

  @override
  Future<String> save({
    required String? token,
    required ClassicMode mode,
    required String name,
    required FieldWorkData data,
    required String declination,
  }) async {
    saves.add((token, name, {...data.toJson(), 'declination': declination}));
    return token ?? nextToken;
  }

  @override
  Future<void> revoke(String token) async => revoked.add(token);

  @override
  Future<ViewedFieldWork?> open(String token) async => shared;
}

AccountProfile _profile(Plan plan) => AccountProfile(
  userId: 'u1',
  email: 'u@x.id',
  displayName: 'U',
  plan: plan,
  role: UserRole.pengguna360,
  isAdmin: false,
  canUseSos: false,
);

void main() {
  late FakeClassicLinks links;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    links = FakeClassicLinks();
  });

  Future<void> settle([int ms = 40]) => Future<void>.delayed(Duration(milliseconds: ms));

  Future<ProviderContainer> container({Plan? plan}) async {
    final c = ProviderContainer(
      overrides: [
        classicLinksProvider.overrideWithValue(links),
        classicShareDelayProvider.overrideWithValue(const Duration(milliseconds: 20)),
        authUserIdProvider.overrideWith((ref) => Stream.value(plan == null ? null : 'u1')),
        profileProvider.overrideWith((ref) async => plan == null ? null : _profile(plan)),
      ],
    );
    addTearDown(c.dispose);
    c
      ..listen(classicProvider, (_, _) {})
      ..listen(profileProvider, (_, _) {})
      ..listen(authUserIdProvider, (_, _) {});
    await settle();
    return c;
  }

  test('Field Works per mode: Free and guests 1, Pro 5, Enterprise 10, admin no limit', () async {
    expect(
      [
        fieldWorkLimit(hasUser: false, subscriptionStatus: 'Enterprise', isAdmin: false),
        fieldWorkLimit(hasUser: true, subscriptionStatus: 'Free', isAdmin: false),
        fieldWorkLimit(hasUser: true, subscriptionStatus: 'Pro', isAdmin: false),
        fieldWorkLimit(hasUser: true, subscriptionStatus: 'Enterprise', isAdmin: false),
        fieldWorkLimit(hasUser: true, subscriptionStatus: 'Free', isAdmin: true),
      ],
      [1, 1, 5, 10, null],
    );
    final guest = await container();
    guest.read(classicProvider.notifier).addFieldWork();
    expect(guest.read(classicProvider).modeFieldWorks, hasLength(1));

    final pro = await container(plan: Plan.pro);
    final ctl = pro.read(classicProvider.notifier);
    for (var i = 0; i < 6; i++) {
      ctl.addFieldWork();
    }
    expect(
      [for (final f in pro.read(classicProvider).modeFieldWorks) f.name],
      ['Field Work 1', 'Field Work 2', 'Field Work 3', 'Field Work 4', 'Field Work 5'],
    );
    // Each mode keeps its own
    ctl.setMode(ClassicMode.intersection);
    expect(pro.read(classicProvider).modeFieldWorks, hasLength(1));
  });

  test('working in one Field Work leaves the others; rename, delete, the last is only cleared', () async {
    final c = await container(plan: Plan.pro);
    final ctl = c.read(classicProvider.notifier)..setAzimuth(0, '60');
    final first = c.read(classicProvider).fieldWork.id;
    ctl.addFieldWork();
    expect(c.read(classicProvider).data.sightings.first.azimuth, '', reason: 'a new one starts empty');
    ctl.selectFieldWork(first);
    expect(c.read(classicProvider).data.sightings.first.azimuth, '60');

    ctl.renameFieldWork(first, '  Gunung Gede latihan 1 with a name far too long to keep  ');
    expect(c.read(classicProvider).fieldWork.name, hasLength(40));
    ctl.renameFieldWork(first, '   ');
    expect(c.read(classicProvider).fieldWork.name, startsWith('Gunung Gede'), reason: 'blank keeps the old name');

    await ctl.deleteFieldWork(first);
    expect(c.read(classicProvider).modeFieldWorks.single.name, 'Field Work 2');
    ctl.setAzimuth(0, '10');
    await ctl.deleteFieldWork(c.read(classicProvider).fieldWork.id);
    expect(c.read(classicProvider).modeFieldWorks, hasLength(1));
    expect(c.read(classicProvider).data.sightings.first.azimuth, '', reason: 'cleared, not removed');
  });

  test('steps open in order; Pick on map sets the position; 2 to 6 sightings', () async {
    final c = await container();
    final ctl = c.read(classicProvider.notifier)..setMode(ClassicMode.intersection);
    expect(c.read(classicProvider).solution.sightings.first.azOpen, isFalse, reason: 'no position yet');
    ctl
      ..startPicking(0)
      ..placePicked((110.43, -7.46));
    final s = c.read(classicProvider);
    expect(s.picking, isNull);
    expect(s.data.sightings.first.point.lat.toJson(), {'d': '7', 'm': '27', 's': '36'});
    expect(s.data.sightings.first.point.south, isTrue);
    expect(s.solution.sightings.first.azOpen, isTrue);
    expect(s.solution.sightings[1].open, isFalse, reason: 'B waits for A');

    ctl
      ..setAzimuth(0, '45')
      ..checkAzimuth(0)
      ..setBack(0, '225')
      ..checkBack(0);
    expect(c.read(classicProvider).solution.sightings.first.complete, isTrue);
    expect(c.read(classicProvider).solution.sightings[1].open, isTrue);

    for (var i = 0; i < 6; i++) {
      ctl.addSighting();
    }
    expect(c.read(classicProvider).data.sightings, hasLength(maxSightings));
    ctl.setLineLength('0:main', 1200);
    for (var i = 0; i < 6; i++) {
      ctl.removeSighting(2);
    }
    expect(c.read(classicProvider).data.sightings, hasLength(minSightings));
    expect(c.read(classicProvider).data.lineLengths, isEmpty, reason: 'letters moved: hand-set lengths reset');

    ctl
      ..startPicking(pickOrigin)
      ..setMode(ClassicMode.resection);
    expect(c.read(classicProvider).picking, isNull, reason: 'switching mode cancels a pick');
  });

  test('remembered on the phone, in the web format', () async {
    final c = await container();
    c.read(classicProvider.notifier)
      ..setDeclination('0.8')
      ..setAzimuth(0, '120');
    await settle(400);
    final raw = jsonDecode((await SharedPreferencesAsync().getString(classicPrefsKey))!) as Map<String, dynamic>;
    expect(raw['declination'], '0.8');
    final saved = ((raw['fieldWorks'] as Map)['resection'] as List).single as Map;
    expect(((saved['sightings'] as List).first as Map)['azimuth'], '120');

    final again = await container();
    expect(again.read(classicProvider).declination, '0.8');
    expect(again.read(classicProvider).data.sightings.first.azimuth, '120');
  });

  test('sharing: signed in only; the link follows every change; stop turns it off', () async {
    final guest = await container();
    await guest.read(classicProvider.notifier).startSharing();
    expect(links.saves, isEmpty);

    final c = await container(plan: Plan.free);
    final ctl = c.read(classicProvider.notifier);
    await ctl.startSharing();
    expect(c.read(classicProvider).fieldWork.shareToken, links.nextToken);
    expect(c.read(classicProvider).shareStatus, ShareStatus.saved);

    ctl
      ..setAzimuth(0, '6')
      ..setAzimuth(0, '60');
    await settle(80);
    expect(links.saves, hasLength(2), reason: 'one save after typing stops');
    expect(links.saves.last.$1, links.nextToken);
    expect(((links.saves.last.$3['sightings']! as List).first as Map)['azimuth'], '60');

    await ctl.stopSharing();
    expect(links.revoked, [links.nextToken]);
    expect(c.read(classicProvider).fieldWork.shareToken, isNull);
  });

  test('a shared Field Work opens read only, beside my own', () async {
    final c = await container();
    c
        .read(classicProvider.notifier)
        .view(
          ViewedFieldWork(
            token: 't',
            mode: ClassicMode.intersection,
            name: 'Latihan Merbabu',
            data: FieldWorkData.fromJson({
              'sightings': [
                {
                  'point': PointInputJson.at(110.43, -7.46),
                  'azimuth': '45',
                  'back': '225',
                  'azChecks': 1,
                  'backChecks': 1,
                },
                {
                  'point': PointInputJson.at(110.45, -7.46),
                  'azimuth': '315',
                  'back': '135',
                  'azChecks': 1,
                  'backChecks': 1,
                },
              ],
            }),
            declination: '0',
            updatedAt: DateTime(2026, 10, 30),
          ),
        );
    final s = c.read(classicProvider);
    expect((s.panelOpen, s.mode), (true, ClassicMode.resection), reason: 'my own mode is untouched');
    expect(s.solution.fix, isNotNull);
    c.read(classicProvider.notifier).closeViewing();
    expect(c.read(classicProvider).solution.fix, isNull);
  });

  test('the map: a line per bearing as typed, X where the azimuths cross, lengths dragged on the line', () async {
    final c = await container();
    final ctl = c.read(classicProvider.notifier)
      ..setMode(ClassicMode.intersection)
      ..setSightingPoint(0, PointInput.of((110.43, -7.46)))
      ..setAzimuth(0, '45');
    var s = c.read(classicProvider);
    var d = ClassicDrawing.of(s.solution, s.mode, s.data.lineLengths);
    expect([for (final l in d.lines) (l.key, l.text)], [('0:main', 'Az 45°')]);
    expect(d.crossing, isNull);

    ctl
      ..checkAzimuth(0)
      ..setBack(0, '225')
      ..setSightingPoint(1, PointInput.of((110.45, -7.46)))
      ..setAzimuth(1, '315');
    s = c.read(classicProvider);
    expect(s.solution.sightings[1].open, isFalse, reason: 'A not checked yet');
    ctl.checkBack(0);
    s = c.read(classicProvider);
    d = ClassicDrawing.of(s.solution, s.mode, s.data.lineLengths);
    expect(d.crossing, isNotNull, reason: 'the crossing shows as soon as both azimuths are typed');
    expect(d.checked, isFalse);
    // Intersection lines run past the crossing: about 2.2 times as far
    final a = d.lines.firstWhere((l) => l.key == '0:main');
    expect(a.length, closeTo(bearingTo(a.from, d.crossing!.point).distance * 2.2, 1));
    expect(d.lines.firstWhere((l) => l.key == '0:back').length, closeTo(a.length * 0.6, 1));

    // Dragging the end sideways keeps the direction: only the length along the line counts
    final dragged = draggedLength(a, (110.4425, -7.4525));
    ctl.setLineLength(a.key, dragged);
    s = c.read(classicProvider);
    d = ClassicDrawing.of(s.solution, s.mode, s.data.lineLengths);
    final moved = d.lines.firstWhere((l) => l.key == '0:main');
    expect(moved.length, dragged);
    expect(turfBearing(moved.from, moved.end), closeTo(45, 1e-6));
    expect(draggedLength(a, a.from), 50, reason: 'never shorter than 50 m');
  });

  test('a ?classic= link opens the shared Field Work read only; a turned-off one says so', () async {
    expect(
      IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/?classic=${'a' * 32}')),
      isA<ClassicLink>(),
    );
    expect(IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/?classic=nope')), isNull);
    expect(classicLinkUrl('t'), 'https://landscape360.jcdigital.co.id/?classic=t');
    expect(
      buildClassicShareText(name: 'FW', mode: 'intersection', url: 'u'),
      '🧭 FW (Intersection practice)\nOpen on Landscape 360 (no sign-in needed): u',
    );

    final c = await container();
    c.listen(sharedLinkProvider, (_, _) {});
    links.shared = ViewedFieldWork(
      token: 't',
      mode: ClassicMode.resection,
      name: 'Latihan',
      data: const FieldWorkData(),
      declination: '0',
      updatedAt: DateTime(2026, 10, 30),
    );
    await c.read(sharedLinkProvider.notifier).open(ClassicLink('a' * 32));
    expect(c.read(classicProvider).viewing?.name, 'Latihan');
    expect(c.read(classicProvider).panelOpen, isTrue);
    expect(c.read(sharedLinkProvider), isNull, reason: 'the panel shows it, no card');

    links.shared = null;
    await c.read(sharedLinkProvider.notifier).open(ClassicLink('b' * 32));
    expect((c.read(sharedLinkProvider)! as SharedClassic).status, LinkStatus.gone);
  });
}

extension PointInputJson on PointInput {
  static Map<String, Object> at(double lng, double lat) => PointInput.of((lng, lat)).toJson();
}
