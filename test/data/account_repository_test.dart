import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:landscape360/data/account/account_repository.dart';
import 'package:landscape360/data/api/api_client.dart';
import 'package:landscape360/domain/account/account_request.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Same behaviour as src/lib/accountPassword.test.ts, loginHistory.ts and the web's
// loadUserProfile / account request form

class FakeBackend implements AccountBackend {
  User? user;
  final calls = <String>[];
  final rpcs = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic>? row;
  Object? profileError;
  String? wrongPasswordFor;
  bool rpcHangs = false;

  @override
  User? get currentUser => user;

  @override
  Future<void> signIn(String email, String password) async {
    calls.add('signIn:$email');
    if (password == wrongPasswordFor) throw const AuthException('Invalid login credentials');
  }

  @override
  Future<void> signOut({bool others = false}) async => calls.add(others ? 'signOut:others' : 'signOut');

  @override
  Future<void> rpc(String fn, Map<String, dynamic> params) async {
    rpcs.add((fn, params));
    calls.add('rpc:$fn');
    if (rpcHangs) await Completer<void>().future;
  }

  List<dynamic>? rows;

  @override
  Future<List<dynamic>?> rpcRows(String fn) async {
    calls.add('rows:$fn');
    return rows;
  }

  @override
  Future<Map<String, dynamic>?> profileRow(String userId) async {
    if (profileError != null) throw profileError!;
    return row;
  }

  @override
  Future<void> updatePassword(String password) async => calls.add('updatePassword');

  @override
  Future<void> updateDisplayName(String name) async => calls.add('updateDisplayName:$name');
}

class NoSession implements SessionSource {
  @override
  String? get accessToken => null;

  @override
  Future<String?> refresh() async => null;
}

User _user({String id = 'u1', String email = 'budi@example.com', Map<String, dynamic>? meta}) => User(
  id: id,
  appMetadata: const {},
  userMetadata: meta ?? {'display_name': 'Budi'},
  aud: 'authenticated',
  email: email,
  createdAt: '2026-01-01T00:00:00Z',
);

void main() {
  late FakeBackend backend;
  late List<http.Request> posted;
  late http.Response apiResponse;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    backend = FakeBackend();
    posted = [];
    apiResponse = http.Response('{"ok":true}', 201);
  });

  AccountRepository repo() => AccountRepository(
    backend: backend,
    api: ApiClient(
      baseUrl: 'https://landscape360.jcdigital.co.id',
      session: NoSession(),
      client: MockClient((req) async {
        posted.add(req);
        return apiResponse;
      }),
    ),
    prefs: SharedPreferencesAsync(),
    userAgent: 'test',
  );

  group('sign in / out', () {
    test('signs in with a normalized email and records the login', () async {
      await repo().signIn('  Budi@Example.com ', 'pass12345');
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls, ['signIn:budi@example.com', 'rpc:record_login']);
      expect(backend.rpcs.single.$2, {'p_user_agent': 'test'});
    });

    test('explains wrong credentials and skips empty fields', () async {
      backend.wrongPasswordFor = 'bad';
      await expectLater(
        repo().signIn('a@b.co', 'bad'),
        throwsA(isA<AccountException>().having((e) => e.message, 'message', 'Wrong email or password')),
      );
      await expectLater(repo().signIn('', ''), throwsA(isA<AccountException>()));
      expect(backend.rpcs, isEmpty);
    });

    test('records the logout before signing out, and never waits more than 2 s', () async {
      await repo().signOut();
      expect(backend.calls, ['rpc:record_logout', 'signOut']);

      backend
        ..calls.clear()
        ..rpcHangs = true;
      final watch = Stopwatch()..start();
      await repo().signOut();
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      expect(backend.calls.last, 'signOut');
    });
  });

  group('profile', () {
    test('is null when signed out', () async {
      expect(await repo().loadProfile(), isNull);
    });

    test('reads plan, role and S.O.S permission', () async {
      backend
        ..user = _user()
        ..row = {'status_subscribe': 'Pro', 'status_user': 'pengguna360', 'can_use_sos': true, 'phone': '0812'};
      final p = (await repo().loadProfile())!;
      expect(p.displayName, 'Budi');
      expect(p.plan, Plan.pro);
      expect(p.canUseSos, isTrue);
      expect(p.canRecordTracks, isFalse);
      expect(p.phone, '0812');
    });

    test('gives admins Enterprise, monitor and S.O.S whatever is stored', () async {
      backend
        ..user = _user()
        ..row = {'status_subscribe': 'Free', 'is_admin': true, 'can_use_sos': false};
      final p = (await repo().loadProfile())!;
      expect(
        (p.plan, p.role, p.canUseSos, p.canMonitor, p.storageLimitBytes),
        (Plan.enterprise, UserRole.monitor360, true, true, null),
      );
    });

    test('keeps the last known S.O.S permission while offline', () async {
      backend
        ..user = _user()
        ..row = {'status_subscribe': 'Free', 'can_use_sos': true};
      await repo().loadProfile();
      backend.profileError = Exception('No internet');
      expect((await repo().loadProfile())!.canUseSos, isTrue);

      // Revoked by the admin: the next successful load hides it again
      backend
        ..profileError = null
        ..row = {'status_subscribe': 'Free', 'can_use_sos': false};
      expect((await repo().loadProfile())!.canUseSos, isFalse);
      backend.profileError = Exception('No internet');
      expect((await repo().loadProfile())!.canUseSos, isFalse);
    });

    test('the cached permission belongs to one account only', () async {
      backend
        ..user = _user(id: 'u1')
        ..row = {'can_use_sos': true};
      await repo().loadProfile();
      backend
        ..user = _user(id: 'u2')
        ..profileError = Exception('offline');
      expect((await repo().loadProfile())!.canUseSos, isFalse);
    });

    test('unknown plan and role fall back to Free / pengguna360', () async {
      backend
        ..user = _user()
        ..row = {'status_subscribe': 'Ultimate', 'status_user': 'hacker'};
      final p = (await repo().loadProfile())!;
      expect((p.plan, p.role), (Plan.free, UserRole.pengguna360));
    });

    test('reads the storage usage like the web (bigint as text, unlimited as null)', () async {
      backend.rows = [
        {
          'tracks_bytes': 1024,
          'locations_bytes': '2048',
          'surveys_bytes': 0,
          'basemaps_bytes': 0,
          'used_bytes': 3072,
          'limit_bytes': 10485760,
        },
      ];
      final u = (await repo().loadStorageUsage())!;
      expect(backend.calls, ['rows:my_storage_usage']);
      expect((u.usedBytes, u.limitBytes, u.locations), (3072, 10485760, 2048));
      expect(u.breakdown.map((b) => b.$1), ['Tracks', 'Marked Locations', 'Surveys', 'Custom Basemaps']);
      expect(u.percent, closeTo(0.0293, 1e-4));

      backend.rows = [
        {'used_bytes': 5, 'limit_bytes': null},
      ];
      expect((await repo().loadStorageUsage())!.percent, isNull);
      backend.rows = [];
      expect(await repo().loadStorageUsage(), isNull);
    });

    test('edit profile writes the name and the contact through the RPC', () async {
      await repo().updateProfile(displayName: ' Budi S ', organization: ' Makopala ', phone: '0812-3456-7890');
      expect(backend.calls, ['updateDisplayName:Budi S', 'rpc:update_my_contact']);
      expect(backend.rpcs.single.$2, {'p_organization': 'Makopala', 'p_phone': '0812-3456-7890'});
      await expectLater(
        repo().updateProfile(displayName: 'B', organization: '', phone: '123'),
        throwsA(isA<AccountException>()),
      );
    });
  });

  group('changePassword', () {
    setUp(() => backend.user = _user(email: 'u@x.com'));

    test('checks the current password, sets the new one and signs out other devices', () async {
      await repo().changePassword(current: 'oldpass123', next: 'newpass123', confirm: 'newpass123');
      expect(backend.calls, ['signIn:u@x.com', 'updatePassword', 'signOut:others']);
    });

    test('does not change anything when the current password is wrong', () async {
      backend.wrongPasswordFor = 'wrong';
      await expectLater(
        repo().changePassword(current: 'wrong', next: 'newpass123', confirm: 'newpass123'),
        throwsA(isA<AccountException>().having((e) => e.message, 'message', 'Your current password is not correct')),
      );
      expect(backend.calls, isNot(contains('updatePassword')));
    });

    test('validates the form before calling the server', () async {
      await expectLater(
        repo().changePassword(current: 'oldpass123', next: 'short', confirm: 'short'),
        throwsA(isA<AccountException>()),
      );
      expect(backend.calls, isEmpty);
    });
  });

  group('request account', () {
    const valid = AccountRequestInput(
      email: ' Budi@Example.com ',
      fullName: 'Budi',
      organization: '',
      phone: '+62 812-3456-7890',
      message: 'Pendakian',
    );

    test('posts the same body as the web form, without a token', () async {
      await repo().requestAccount(valid);
      final req = posted.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/api/account-requests');
      expect(req.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(req.body), {
        'email': 'budi@example.com',
        'fullName': 'Budi',
        'organization': '',
        'phone': '+62 812-3456-7890',
        'message': 'Pendakian',
        'requestedPlan': 'Free',
        'website': '',
      });
    });

    test('validates like the server and shows its error text', () async {
      expect(accountRequestError(valid), isNull);
      expect(
        accountRequestError(
          const AccountRequestInput(email: 'x', fullName: 'B', organization: '', phone: '', message: 'm'),
        ),
        contains('email'),
      );
      expect(
        accountRequestError(
          const AccountRequestInput(email: 'a@b.co', fullName: 'B', organization: '', phone: '123', message: 'm'),
        ),
        contains('8 to 15 digits'),
      );
      expect(
        accountRequestError(
          const AccountRequestInput(email: 'a@b.co', fullName: 'B', organization: '', phone: '', message: ' '),
        ),
        isNotNull,
      );

      apiResponse = http.Response('{"error":"Too many requests"}', 429);
      await expectLater(
        repo().requestAccount(valid),
        throwsA(isA<AccountException>().having((e) => e.message, 'message', 'Too many requests')),
      );
    });
  });
}
