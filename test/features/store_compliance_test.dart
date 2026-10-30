import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/router.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/account/account_repository.dart';
import 'package:landscape360/data/api/api_client.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/sos/sos.dart' show emergencyContactsKey;
import 'package:landscape360/domain/tracks/recorded_track.dart';
import 'package:landscape360/domain/tracks/track_recorder_geo.dart';
import 'package:landscape360/features/basemaps/basemap_state.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import '../data/account_repository_test.dart' show FakeBackend, TokenSession;
import 'basemaps_test.dart' show MemoryFiles;
import 'track_recorder_panel_test.dart' show MemoryTrackStore;

// Store compliance: deleting the account in the app (two steps, the password again, the
// phone's data for that account removed), not offered to the admin, and the About page

AccountProfile _profile({bool admin = false}) => AccountProfile(
  userId: 'u1',
  email: 'budi@example.com',
  displayName: 'Budi',
  plan: Plan.pro,
  role: UserRole.pengguna360,
  isAdmin: admin,
  canUseSos: false,
);

RecordedTrack _track(String id, String user) => RecordedTrack(
  id: id,
  userId: user,
  name: id,
  mode: TrackMode.offline,
  status: TrackStatus.completed,
  startedAt: 1761600000000,
  elapsedMs: 1000,
  stats: const TrackStats(distanceM: 10, elevationGainM: 0),
  syncStatus: TrackSyncStatus.local,
  updatedAt: 1761600000000,
);

void main() {
  late FakeBackend backend;
  late MemoryTrackStore tracks;
  late MemoryFiles files;
  late List<http.Request> sent;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    PackageInfo.setMockInitialValues(
      appName: 'Landscape 360',
      packageName: 'id.co.jcdigital.landscape360',
      version: '3.3.0-dev',
      buildNumber: '7',
      buildSignature: '',
    );
    backend = FakeBackend()
      ..user = User(
        id: 'u1',
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        email: 'budi@example.com',
        createdAt: '2026-01-01T00:00:00Z',
      );
    tracks = MemoryTrackStore()
      ..tracks['mine'] = _track('mine', 'u1')
      ..tracks['other'] = _track('other', 'u2');
    files = MemoryFiles()..saved.add('b1');
    sent = [];
  });

  Future<void> pump(WidgetTester tester, {bool admin = false, String start = '/account'}) async {
    var signedIn = true;
    final router = buildRouter(isSignedIn: () => signedIn)..go(start);
    final repo = AccountRepository(
      backend: backend,
      api: ApiClient(
        baseUrl: 'https://landscape360.jcdigital.co.id',
        session: TokenSession(),
        client: MockClient((req) async {
          sent.add(req);
          signedIn = false;
          return http.Response('{"ok":true}', 200);
        }),
      ),
      prefs: SharedPreferencesAsync(),
      userAgent: 'test',
    );
    await tester.binding.setSurfaceSize(const Size(400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(
            const AppConfig(
              flavor: 'dev',
              supabaseUrl: 'https://x.supabase.co',
              supabaseAnonKey: 'sb_publishable_x',
              mapboxPublicToken: '',
              apiBaseUrl: 'https://landscape360.jcdigital.co.id',
            ),
          ),
          authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
          profileProvider.overrideWith((ref) async => _profile(admin: admin)),
          storageUsageProvider.overrideWith((ref) async => null),
          accountRepositoryProvider.overrideWithValue(repo),
          trackLocalStoreProvider.overrideWithValue(tracks),
          basemapFilesProvider.overrideWithValue(files),
        ],
        child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('two steps, the password and DELETE, then the phone forgets the account', (tester) async {
    await SharedPreferencesAsync().setString(emergencyContactsKey('u1'), '[]');
    await pump(tester);
    await tester.ensureVisible(find.byKey(const Key('delete-account')));
    await tester.tap(find.byKey(const Key('delete-account')));
    await tester.pumpAndSettle();
    expect(find.text('Delete your account?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-account-continue')));
    await tester.pumpAndSettle();

    // Nothing happens until both are filled in
    final confirm = find.byKey(const Key('delete-account-confirm'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('delete-password')), 'pass12345');
    await tester.enterText(find.byKey(const Key('delete-typed')), 'delete');
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull, reason: 'DELETE in capitals');
    await tester.enterText(find.byKey(const Key('delete-typed')), 'DELETE');
    await tester.pump();
    expect(sent, isEmpty);

    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(sent.single.method, 'DELETE');
    expect(backend.calls, containsAllInOrder(['signIn:budi@example.com', 'signOut']));
    expect(tracks.tracks.keys, ['other'], reason: "only this account's tracks");
    expect(await SharedPreferencesAsync().getString(emergencyContactsKey('u1')), isNull);
    expect(find.text('Your account has been deleted.'), findsOneWidget);
  });

  testWidgets('the admin account has no Delete account, here or in About', (tester) async {
    await pump(tester, admin: true);
    expect(find.byKey(const Key('delete-account')), findsNothing);
    expect(find.byKey(const Key('account-about')), findsOneWidget);
    await pump(tester, admin: true, start: '/about');
    expect(find.byKey(const Key('about-privacy')), findsOneWidget);
    expect(find.byKey(const Key('about-delete')), findsNothing);
  });

  testWidgets('About: version, legal pages and support', (tester) async {
    await pump(tester, start: '/about');
    expect(find.text('Version 3.3.0'), findsOneWidget, reason: 'the website\'s number, no build or flavour');
    expect(find.byKey(const Key('about-stores')), findsOneWidget);
    expect(find.text('Google Play'), findsOneWidget);
    expect(find.text('App Store'), findsOneWidget);
    for (final k in ['about-privacy', 'about-terms', 'about-delete', 'about-reviews', 'about-support']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
  });
}
