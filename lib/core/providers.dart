import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/account/account_repository.dart';
import '../data/api/api_client.dart';
import '../domain/account/profile.dart';
import 'config/app_config.dart';

/// Overridden in main() with the validated build configuration
final appConfigProvider = Provider<AppConfig>((ref) => throw UnimplementedError('appConfigProvider'));

final supabaseClientProvider = Provider<SupabaseClient>((ref) => Supabase.instance.client);

class _SupabaseSession implements SessionSource {
  _SupabaseSession(this.client);

  final SupabaseClient client;

  @override
  String? get accessToken => client.auth.currentSession?.accessToken;

  @override
  Future<String?> refresh() async {
    try {
      return (await client.auth.refreshSession()).session?.accessToken;
    } on AuthException {
      return null;
    }
  }
}

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(
    baseUrl: ref.watch(appConfigProvider).apiBaseUrl,
    session: _SupabaseSession(ref.watch(supabaseClientProvider)),
  );
});

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  return AccountRepository(
    backend: SupabaseAccountBackend(ref.watch(supabaseClientProvider)),
    api: ref.watch(apiClientProvider),
    prefs: SharedPreferencesAsync(),
  );
});

/// Signed-in user id, updated on every sign-in / sign-out / token change
final authUserIdProvider = StreamProvider<String?>((ref) {
  final auth = ref.watch(supabaseClientProvider).auth;
  return auth.onAuthStateChange.map((s) => s.session?.user.id);
});

/// The signed-in account (null when signed out)
final profileProvider = FutureProvider<AccountProfile?>((ref) async {
  final userId = ref.watch(authUserIdProvider).value;
  if (userId == null) return null;
  return ref.watch(accountRepositoryProvider).loadProfile();
});
