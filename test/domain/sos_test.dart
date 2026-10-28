import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/sos/sos.dart';
import 'package:landscape360/domain/sos/sos_outbox.dart';

// Same cases as src/lib/sos.test.ts and src/lib/sosAlerts.test.ts (web)

final fix = SosFix(
  lat: -6.78991,
  lng: 106.9832,
  accuracy: 8.4,
  elevation: 2958.2,
  time: DateTime(2026, 10, 25, 14, 3).millisecondsSinceEpoch,
);

class MemoryStorage implements OutboxStorage {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

SosReport report({SosStatus status = SosStatus.active, bool noFix = false}) => SosReport(
  clientId: '11111111-1111-4111-8111-111111111111',
  startedAt: '2026-10-25T01:00:00.000Z',
  status: status,
  message: '  kaki terkilir  ',
  fix: noFix
      ? null
      : SosFix(
          lat: -6.78991,
          lng: 106.9832,
          accuracy: 8,
          elevation: 2100,
          time: DateTime.parse('2026-10-25T01:00:30Z').millisecondsSinceEpoch,
        ),
  battery: 42,
);

void main() {
  group('S.O.S message', () {
    test('includes the coordinates in DMS and decimal, elevation, accuracy, time and a map link', () {
      final msg = buildSosMessage('Budi S.', fix);
      expect(msg, contains('Budi S. butuh bantuan / needs help.'));
      expect(msg, matches(RegExp(r'''6°47'23\.\d+" S 106°58'59\.\d+" E \(-6\.78991, 106\.98320\)''')));
      expect(msg, contains('elev 2958 m, ±8 m, 25/10 14:03.'));
      expect(msg, contains('https://maps.google.com/?q=-6.78991,106.98320'));
    });

    test('says when there is no GPS fix yet', () {
      expect(buildSosMessage('', null), matches(RegExp('A Landscape 360 user butuh bantuan.*no GPS fix yet')));
    });
  });

  test('smsUrl puts the body after "?" on Android and "&" on iOS, numbers comma separated', () {
    expect(
      smsUrl(['0812-3456-7890', '+62 811 222 333'], 'Help me', ios: false),
      'sms:081234567890,+62811222333?body=Help%20me',
    );
    expect(smsUrl(['0812-3456-7890'], 'Help me', ios: true), 'sms:081234567890&body=Help%20me');
  });

  group('emergency contacts', () {
    test('survive encoding, and malformed storage is ignored', () {
      const list = [EmergencyContact(name: 'Ibu', phone: '0812345678')];
      expect(decodeEmergencyContacts(encodeEmergencyContacts(list)), list);
      expect(decodeEmergencyContacts(null), isEmpty);
      expect(decodeEmergencyContacts('not json'), isEmpty);
      expect(decodeEmergencyContacts('[{"name":1,"phone":"x"},{"name":"A","phone":"1"}]'), [
        const EmergencyContact(name: 'A', phone: '1'),
      ]);
      expect(emergencyContactsKey('u1'), isNot(emergencyContactsKey('u2')));
    });

    test('validates a new contact', () {
      const list = [EmergencyContact(name: 'Ibu', phone: '0812-345-678')];
      expect(emergencyContactError(const EmergencyContact(name: '', phone: '0812345678'), []), contains('name'));
      expect(emergencyContactError(const EmergencyContact(name: 'X', phone: '123'), []), contains('8 to 15 digits'));
      expect(
        emergencyContactError(const EmergencyContact(name: 'Ayah', phone: '0812345678'), list),
        contains('already'),
      );
      expect(
        emergencyContactError(const EmergencyContact(name: 'Ayah', phone: '0811111111'), List.filled(5, list[0])),
        contains('At most 5'),
      );
      expect(emergencyContactError(const EmergencyContact(name: 'Ayah', phone: '0811111111'), list), isNull);
    });
  });

  test('SOS light pattern is dot dot dot, dash dash dash, dot dot dot', () {
    expect(sosLightPattern.map((p) => p.$1 > 300 ? '-' : '.').join(), '...---...');
  });

  group('S.O.S outbox', () {
    late MemoryStorage storage;
    late List<Map<String, dynamic>> sent;
    late Object? failWith;

    SosOutbox outbox() => SosOutbox(
      storage: storage,
      send: (r) async {
        if (failWith != null) throw failWith!;
        sent.add(r.toRpcParams());
      },
    );

    setUp(() {
      storage = MemoryStorage();
      sent = [];
      failWith = null;
    });

    test('sends the message, full location, battery and times', () async {
      final box = outbox();
      expect(await box.queue(report()), isTrue);
      expect(sent.single, {
        'p_client_id': '11111111-1111-4111-8111-111111111111',
        'p_started_at': '2026-10-25T01:00:00.000Z',
        'p_status': 'active',
        'p_message': 'kaki terkilir',
        'p_lat': -6.78991,
        'p_lng': 106.9832,
        'p_accuracy': 8.0,
        'p_elevation': 2100.0,
        'p_battery': 42,
        'p_located_at': '2026-10-25T01:00:30.000Z',
      });
      expect(await box.pending(), isEmpty);
    });

    test('keeps the latest report without signal and sends it when back online', () async {
      final box = outbox();
      failWith = Exception('Failed to fetch');
      await expectLater(box.queue(report()), throwsException);
      await expectLater(box.queue(report(status: SosStatus.resolved, noFix: true)), throwsException);
      final pending = await box.pending();
      expect(pending, hasLength(1));
      expect(pending.single.status, SosStatus.resolved);

      // Survives the app being closed: a new outbox on the same storage still has it
      failWith = null;
      final reopened = outbox();
      expect(await reopened.flush(), isTrue);
      expect(sent.last, containsPair('p_status', 'resolved'));
      expect(sent.last, containsPair('p_lat', null));
      expect(sent.last, containsPair('p_located_at', null));
      expect(await reopened.pending(), isEmpty);
    });

    test('keeps a newer report that arrived while the older one was being sent', () async {
      final gate = Completer<void>();
      var calls = 0;
      final box = SosOutbox(
        storage: storage,
        send: (r) async {
          calls++;
          if (calls == 1) await gate.future;
          sent.add(r.toRpcParams());
        },
      );
      final first = box.queue(report());
      await Future<void>.delayed(Duration.zero);
      // A newer report for the same S.O.S is stored while the first send is in flight
      final second = box.queue(report(status: SosStatus.resolved));
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      expect(await first, isFalse);
      expect(await second, isFalse); // joined the running flush
      expect((await box.pending()).single.status, SosStatus.resolved);
      expect(await box.flush(), isTrue);
      expect(sent.last['p_status'], 'resolved');
    });

    test('explains a missing migration', () {
      expect(
        sosReportErrorMessage('Could not find the function public.sos_report', 'PGRST202'),
        contains('20261024000015'),
      );
      expect(sosReportErrorMessage('Failed to fetch', null), 'Failed to fetch');
    });
  });
}
