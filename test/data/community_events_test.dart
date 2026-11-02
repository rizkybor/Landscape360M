import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/data/community/community_events_repository.dart';
import 'package:landscape360/data/community/community_repository.dart';
import 'package:landscape360/data/tracks/gps_source.dart';
import 'package:landscape360/domain/community/community_events.dart';
import 'package:landscape360/features/community/community_live_state.dart';
import 'package:landscape360/features/community/community_state.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart' show gpsSourceProvider, onlineProvider;
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../domain/community_events_test.dart' show eventRow;
import '../domain/sos_test.dart' show MemoryStorage;
import '../features/track_recorder_state_test.dart' show FakeGps;
import 'community_repository_test.dart' show FakeCommunity;

// Club events over their RPCs, the positions kept on the phone and sent in batches, and live
// sharing: what is kept, sending, stopping by itself, one event at a time, and carrying on after
// the app restarts

const eventId = 'e1e1e1e1-0000-4000-8000-000000000001';
const clubId = '11111111-2222-4333-8444-555555555555';

LivePoint point(int minute) =>
    LivePoint(lat: -6.7, lng: 106.9, battery: 80, recordedAt: DateTime.utc(2026, 11, 9, 1, minute));

GpsFix fix(DateTime at, {double lat = -6.7, double lng = 106.9}) =>
    GpsFix(lat: lat, lng: lng, alt: 2400, accuracy: 8, speed: 1.1, timestamp: at.millisecondsSinceEpoch);

void main() {
  late FakeCommunity backend;

  setUp(() {
    backend = FakeCommunity()..answers['report_community_live'] = true;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
  });

  group('repository', () {
    test('events: list, one, save, cancel, delete', () async {
      final repo = CommunityEventsRepository(backend);
      backend
        ..answers['community_events'] = [
          {'id': eventId, 'title': 'T', 'state': 'planned', 'going_count': 1},
        ]
        ..answers['community_event'] = [eventRow()]
        ..answers['save_community_event'] = eventId;
      expect((await repo.events(clubId, past: true)).single.id, eventId);
      expect(backend.params('community_events'), {'p_club_id': clubId, 'p_past': true});
      expect((await repo.event(eventId))!.clubName, 'Mapala UI');
      backend.answers['community_event'] = <Object>[];
      expect(await repo.event(eventId), isNull);
      final id = await repo.save(
        clubId,
        null,
        EventInput(
          title: ' Traverse ',
          startsAt: DateTime.utc(2026, 11, 8, 22),
          endsAt: DateTime.utc(2026, 11, 9, 10),
          meetingName: 'Basecamp',
          meetingLat: -6.74,
          meetingLng: 106.99,
          routeItemId: 'i1',
          quota: 12,
          needsApproval: true,
        ),
      );
      expect(id, eventId);
      expect(backend.params('save_community_event'), {
        'p_club_id': clubId,
        'p_id': null,
        'p_title': 'Traverse',
        'p_description': null,
        'p_starts_at': '2026-11-08T22:00:00.000Z',
        'p_ends_at': '2026-11-09T10:00:00.000Z',
        'p_meeting_name': 'Basecamp',
        'p_meeting_lat': -6.74,
        'p_meeting_lng': 106.99,
        'p_route_item_id': 'i1',
        'p_quota': 12,
        'p_needs_approval': true,
      });
      await repo.cancel(eventId);
      expect(backend.params('cancel_community_event'), {'p_id': eventId});
      await repo.delete(eventId);
      expect(backend.params('delete_community_event'), {'p_id': eventId});
    });

    test('participants, decisions and the checklist', () async {
      final repo = CommunityEventsRepository(backend);
      backend
        ..answers['join_community_event'] = 'pending'
        ..answers['community_event_participants'] = [
          {'user_id': 'u2', 'name': 'Rina', 'status': 'going', 'sharing': true, 'last_seen_at': null},
        ]
        ..answers['community_event_checklist'] = [
          {'id': 'c1', 'label': 'Headlamp', 'checked': true, 'checked_count': 4},
        ]
        ..answers['add_community_event_checklist_item'] = 'c2'
        ..answers['toggle_community_event_check'] = false;
      expect(await repo.join(eventId, emergencyName: ' Ibu ', emergencyPhone: ''), ParticipantStatus.pending);
      expect(backend.params('join_community_event'), {
        'p_id': eventId,
        'p_emergency_name': 'Ibu',
        'p_emergency_phone': null,
      });
      await repo.leave(eventId);
      expect(backend.params('leave_community_event'), {'p_id': eventId});
      await repo.decide(eventId, 'u2', going: false);
      expect(backend.params('decide_community_event_participant'), {
        'p_id': eventId,
        'p_user_id': 'u2',
        'p_status': 'declined',
      });
      expect((await repo.participants(eventId)).single.sharing, isTrue);
      expect((await repo.checklist(eventId)).single.checkedCount, 4);
      expect(await repo.addChecklistItem(eventId, ' Raincoat '), 'c2');
      expect(backend.params('add_community_event_checklist_item'), {'p_id': eventId, 'p_label': 'Raincoat'});
      expect(await repo.toggleCheck('c1'), isFalse);
      expect(backend.params('toggle_community_event_check'), {'p_item_id': 'c1'});
      await repo.deleteChecklistItem('c1');
      expect(backend.params('delete_community_event_checklist_item'), {'p_item_id': 'c1'});
    });

    test('live: start, report, stop, latest, trail', () async {
      final repo = CommunityEventsRepository(backend);
      backend
        ..answers['community_live_latest'] = [
          {'user_id': 'u2', 'name': 'Rina', 'lat': 1, 'lng': 2, 'recorded_at': '2026-11-09T01:00:00Z', 'is_me': false},
        ]
        ..answers['community_live_trail'] = [
          {'lat': 1, 'lng': 2, 'altitude_m': 3, 'recorded_at': '2026-11-09T01:00:00Z'},
        ];
      await repo.startLive(eventId);
      expect(backend.params('start_community_live'), {'p_id': eventId});
      expect(await repo.reportLive(eventId, [point(1)]), isTrue);
      expect(backend.params('report_community_live'), {
        'p_id': eventId,
        'p_points': [point(1).toJson()],
      });
      backend.answers['report_community_live'] = false;
      expect(await repo.reportLive(eventId, [point(2)]), isFalse);
      await repo.stopLive(eventId);
      expect(backend.params('stop_community_live'), {'p_id': eventId});
      expect((await repo.liveLatest(eventId)).single.name, 'Rina');
      expect((await repo.liveTrail(eventId, 'u2')).single.altitudeM, 3);
      expect(backend.params('community_live_trail'), {'p_id': eventId, 'p_user_id': 'u2'});
    });
  });

  group('positions kept on the phone', () {
    LiveSession session() => LiveSession(
      eventId: eventId,
      userId: 'u1',
      title: 'Traverse',
      clubName: 'Mapala UI',
      endsAt: DateTime.utc(2026, 11, 9, 10),
    );

    test('kept across restarts and sent in batches of 500, oldest first', () async {
      final storage = MemoryStorage();
      final buffer = LiveBuffer(storage);
      await buffer.write(session());
      for (var i = 0; i < 1203; i++) {
        await buffer.add(LivePoint(lat: 0, lng: 0, recordedAt: DateTime.utc(2026).add(Duration(minutes: i))));
      }
      // Another instance (the app started again) reads the same queue
      final again = LiveBuffer(storage);
      expect((await again.read())!.pending, hasLength(1203));
      final sizes = <int>[];
      final keep = await again.flush((id, batch) async {
        expect(id, eventId);
        sizes.add(batch.length);
        return true;
      });
      expect(keep, isTrue);
      expect(sizes, [500, 500, 203]);
      expect((await again.read())!.pending, isEmpty);
    });

    test('a batch that fails stays; positions taken meanwhile wait their turn', () async {
      final buffer = LiveBuffer(MemoryStorage());
      await buffer.write(session());
      await buffer.add(point(1));
      await buffer.add(point(2));
      await expectLater(
        buffer.flush((_, _) async => throw const CommunityException('x', offline: true)),
        throwsA(isA<CommunityException>()),
      );
      expect((await buffer.read())!.pending, hasLength(2));
      final sent = <DateTime>[];
      final keep = await buffer.flush((_, batch) async {
        sent.addAll(batch.map((p) => p.recordedAt));
        if (sent.length == 2) await buffer.add(point(3));
        return false;
      });
      expect(keep, isFalse, reason: 'the server said to stop');
      expect(sent, [point(1).recordedAt, point(2).recordedAt, point(3).recordedAt]);
      expect((await buffer.read())!.pending, isEmpty);
    });

    test('the phone keeps at most 5000; nothing without a session', () async {
      final buffer = LiveBuffer(MemoryStorage());
      expect(await buffer.add(point(1)), isNull);
      await buffer.write(session());
      for (var i = 0; i < LiveBuffer.maxPending + 3; i++) {
        await buffer.add(LivePoint(lat: 0, lng: 0, recordedAt: DateTime.utc(2026).add(Duration(seconds: i))));
      }
      final s = (await buffer.read())!;
      expect(s.pending.length, LiveBuffer.maxPending);
      expect(s.pending.first.recordedAt, DateTime.utc(2026).add(const Duration(seconds: 3)), reason: 'the oldest go');
    });
  });

  group('live sharing', () {
    late FakeGps gps;
    late DateTime now;
    var online = true;

    setUp(() {
      gps = FakeGps();
      now = DateTime.utc(2026, 11, 9, 1);
      online = true;
    });

    Future<ProviderContainer> container() async {
      final c = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          communityBackendProvider.overrideWithValue(backend),
          authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
          onlineProvider.overrideWith((ref) => Stream.value(online)),
          gpsSourceProvider.overrideWithValue(gps),
          communityBatteryProvider.overrideWithValue(() async => 77),
          communityClockProvider.overrideWithValue(() => now),
        ],
      );
      addTearDown(c.dispose);
      c
        ..listen(communityLiveProvider, (_, _) {})
        ..listen(onlineProvider, (_, _) {});
      await c.read(authUserIdProvider.future);
      await c.read(onlineProvider.future);
      await pumpEventQueue();
      return c;
    }

    final event = CommunityEvent.fromRow(eventRow());

    test('starts, keeps a fix every 2 minutes or 50 m, sends them with the battery', () async {
      final c = await container();
      expect(await c.read(communityLiveProvider.notifier).start(event), isNull);
      expect(backend.names, contains('start_community_live'));
      final live = c.read(communityLiveProvider);
      expect((live.on, live.clubName, live.endsAt), (true, 'Mapala UI', DateTime.utc(2026, 11, 9, 10)));
      expect(gps.watching, isTrue);
      final t0 = DateTime.utc(2026, 11, 9, 1);
      gps.controller!
        ..add(fix(t0))
        ..add(fix(t0.add(const Duration(seconds: 30)), lat: -6.7001)) // 11 m: not kept
        ..add(fix(t0.add(const Duration(seconds: 40)), lat: -6.7006)); // 67 m: kept
      await pumpEventQueue();
      expect(c.read(communityLiveProvider).pending, 2);
      await c.read(communityLiveProvider.notifier).flush();
      final sent = backend.params('report_community_live')['p_points'] as List;
      expect(sent, hasLength(2));
      expect((sent.first as Map)['battery'], 77);
      expect((sent.last as Map)['lat'], -6.7006);
      expect(c.read(communityLiveProvider).pending, 0);
    });

    test('the server says stop: sharing ends with a message', () async {
      final c = await container();
      await c.read(communityLiveProvider.notifier).start(event);
      gps.controller!.add(fix(now));
      await pumpEventQueue();
      backend.answers['report_community_live'] = false;
      await c.read(communityLiveProvider.notifier).flush();
      final live = c.read(communityLiveProvider);
      expect(live.on, isFalse);
      expect(live.endedMessage, startsWith('Sharing stopped'));
      expect(gps.watching, isFalse);
    });

    test('Stop sends what is left, then tells the server', () async {
      final c = await container();
      await c.read(communityLiveProvider.notifier).start(event);
      gps.controller!.add(fix(now));
      await pumpEventQueue();
      await c.read(communityLiveProvider.notifier).stop();
      expect(backend.names.where((n) => n.contains('live')).toList(), [
        'start_community_live',
        'report_community_live',
        'stop_community_live',
      ]);
      expect(c.read(communityLiveProvider).on, isFalse);
      expect(await c.read(liveBufferProvider).read(), isNull);
    });

    test('one event at a time: starting another stops the first', () async {
      final c = await container();
      await c.read(communityLiveProvider.notifier).start(event);
      final other = CommunityEvent.fromRow({...eventRow(), 'id': 'e2', 'title': 'Other'});
      await c.read(communityLiveProvider.notifier).start(other);
      expect(backend.calls.where((x) => x.$1 == 'stop_community_live').single.$2, {'p_id': eventId});
      expect(backend.params('start_community_live'), {'p_id': 'e2'});
      expect(c.read(communityLiveProvider).title, 'Other');
    });

    test('without signal the positions wait, also through a restart, and go when it is back', () async {
      final c = await container();
      await c.read(communityLiveProvider.notifier).start(event);
      backend.offline = true;
      gps.controller!.add(fix(now));
      await pumpEventQueue();
      await c.read(communityLiveProvider.notifier).flush();
      expect(c.read(communityLiveProvider).pending, 1);
      c.dispose();
      expect(gps.watching, isFalse);

      // The app starts again before the event ends: sharing carries on and sends what waited
      backend.offline = false;
      final again = await container();
      await pumpEventQueue();
      expect(again.read(communityLiveProvider).on, isTrue);
      expect(gps.watching, isTrue);
      expect(backend.calls.where((x) => x.$1 == 'start_community_live'), hasLength(1), reason: 'not started again');
      expect(backend.calls.where((x) => x.$1 == 'report_community_live'), hasLength(1));
      expect(again.read(communityLiveProvider).pending, 0);
    });

    test('started again after the event ended: only the last positions go out', () async {
      final first = await container();
      await first.read(communityLiveProvider.notifier).start(event);
      backend.offline = true;
      gps.controller!.add(fix(now));
      await pumpEventQueue();
      first.dispose();
      backend.offline = false;
      now = DateTime.utc(2026, 11, 9, 12); // after the end
      final again = await container();
      await pumpEventQueue();
      expect(again.read(communityLiveProvider).on, isFalse);
      expect(backend.calls.where((x) => x.$1 == 'report_community_live'), hasLength(1));
      expect(await again.read(liveBufferProvider).read(), isNull);
    });

    test('no location permission: not started', () async {
      final c = await container();
      gps.accessResult = GpsAccess.servicesOff;
      expect(await c.read(communityLiveProvider.notifier).start(event), contains('Location Services'));
      expect(backend.names, isNot(contains('start_community_live')));
    });
  });
}
