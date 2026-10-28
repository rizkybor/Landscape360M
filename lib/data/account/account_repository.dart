import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/account/account_request.dart';
import '../../domain/account/account_rules.dart';
import '../../domain/account/profile.dart';
import '../api/api_client.dart';

/// The Supabase calls the account features need. The app uses [SupabaseAccountBackend];
/// tests use a fake.
abstract interface class AccountBackend {
  User? get currentUser;
  Future<void> signIn(String email, String password);
  Future<void> signOut({bool others = false});
  Future<void> rpc(String fn, Map<String, dynamic> params);
  Future<List<dynamic>?> rpcRows(String fn);
  Future<Map<String, dynamic>?> profileRow(String userId);
  Future<void> updatePassword(String password);
  Future<void> updateDisplayName(String name);
}

class SupabaseAccountBackend implements AccountBackend {
  SupabaseAccountBackend(this.client);

  final SupabaseClient client;

  @override
  User? get currentUser => client.auth.currentUser;

  @override
  Future<void> signIn(String email, String password) =>
      client.auth.signInWithPassword(email: email, password: password);

  @override
  Future<void> signOut({bool others = false}) =>
      client.auth.signOut(scope: others ? SignOutScope.others : SignOutScope.local);

  @override
  Future<void> rpc(String fn, Map<String, dynamic> params) => client.rpc<void>(fn, params: params);

  @override
  Future<List<dynamic>?> rpcRows(String fn) async => await client.rpc<dynamic>(fn) as List<dynamic>?;

  @override
  Future<Map<String, dynamic>?> profileRow(String userId) => client
      .from('profiles')
      .select('status_subscribe, status_user, is_admin, can_use_sos, organization, phone')
      .eq('id', userId)
      .maybeSingle();

  @override
  Future<void> updatePassword(String password) => client.auth.updateUser(UserAttributes(password: password));

  @override
  Future<void> updateDisplayName(String name) =>
      // display_name is the one name field; full_name kept in step for older web code
      client.auth.updateUser(UserAttributes(data: {'display_name': name, 'full_name': name}));
}

/// Plain-text error for the UI
class AccountException implements Exception {
  const AccountException(this.message);
  final String message;

  @override
  String toString() => message;
}

String _platformLabel() {
  try {
    if (Platform.isAndroid) return 'Landscape 360 app on Android';
    if (Platform.isIOS) return 'Landscape 360 app on iPhone';
  } on Object {
    // Platform is not available in some test environments
  }
  return 'Landscape 360 app';
}

class AccountRepository {
  AccountRepository({required this.backend, required this.api, required this.prefs, String? userAgent})
    : userAgent = userAgent ?? _platformLabel();

  final AccountBackend backend;
  final ApiClient api;
  final SharedPreferencesAsync prefs;
  final String userAgent;

  static String _sosKey(String userId) => 'l360-can-use-sos-$userId';
  static String _accessKey(String userId) => 'l360-access-$userId';

  // Plan, role and admin flag kept from the last successful load (no personal data), so
  // without signal an Enterprise account still records tracks and is not shown as Free
  static const _accessFields = ['status_subscribe', 'status_user', 'is_admin'];

  /// Signs in, then records the sign-in for the admin's login history (never blocks it)
  Future<void> signIn(String email, String password) async {
    final e = email.trim().toLowerCase();
    if (e.isEmpty || password.isEmpty) throw const AccountException('Enter your email and password');
    try {
      await backend.signIn(e, password);
    } on AuthException catch (err) {
      throw AccountException(
        RegExp('invalid login credentials', caseSensitive: false).hasMatch(err.message)
            ? 'Wrong email or password'
            : err.message,
      );
    }
    unawaited(backend.rpc('record_login', {'p_user_agent': userAgent}).then((_) {}, onError: (_) {}));
  }

  /// Records the sign-out (while the session is still valid, at most 2 s), then signs out
  Future<void> signOut() async {
    await backend
        .rpc('record_logout', {'p_user_agent': userAgent})
        .timeout(const Duration(seconds: 2))
        .then((_) {}, onError: (_) {});
    await backend.signOut();
  }

  /// The signed-in account, or null when signed out. Without signal the last known S.O.S
  /// permission is used.
  Future<AccountProfile?> loadProfile() async {
    final user = backend.currentUser;
    if (user == null) return null;
    Map<String, dynamic>? row;
    try {
      row = await backend.profileRow(user.id);
    } on Object {
      row = null;
    }
    final cachedSos = await prefs.getBool(_sosKey(user.id));
    if (row != null) {
      await prefs.setString(_accessKey(user.id), jsonEncode({for (final k in _accessFields) k: row[k]}));
    } else {
      // Offline: the last known plan, role and admin flag, with the last known S.O.S permission
      try {
        final cached = await prefs.getString(_accessKey(user.id));
        if (cached != null) row = {...jsonDecode(cached) as Map<String, dynamic>, 'can_use_sos': cachedSos ?? false};
      } on Object {
        // Unreadable cache: Free until the server answers
      }
    }
    final profile = AccountProfile.resolve(
      userId: user.id,
      email: user.email ?? '',
      displayName: accountDisplayName(user.userMetadata),
      row: row,
      cachedCanUseSos: cachedSos,
    );
    await prefs.setBool(_sosKey(user.id), profile.canUseSos);
    return profile;
  }

  /// Cloud storage used by the account and its plan limit
  Future<MyStorageUsage?> loadStorageUsage() async =>
      MyStorageUsage.fromRows(await backend.rpcRows('my_storage_usage'));

  /// Edit Profile: display name in the auth metadata, organization and phone through the
  /// update_my_contact RPC (users cannot write `profiles` directly)
  Future<void> updateProfile({required String displayName, required String organization, required String phone}) async {
    final name = displayName.trim();
    if (name.isEmpty) throw const AccountException('Enter your name');
    if (!isValidPhone(phone)) throw const AccountException('Phone number must have 8 to 15 digits');
    await backend.updateDisplayName(name);
    await backend.rpc('update_my_contact', {'p_organization': organization.trim(), 'p_phone': phone.trim()});
  }

  /// Changes the password after checking the current one (by signing in with it), so
  /// someone holding an unlocked phone cannot change it. Other devices are signed out.
  Future<void> changePassword({required String current, required String next, required String confirm}) async {
    final problem = passwordChangeError(current: current, next: next, confirm: confirm);
    if (problem != null) throw AccountException(problem);
    final email = backend.currentUser?.email;
    if (email == null) throw const AccountException('Not signed in');
    try {
      await backend.signIn(email, current);
    } on AuthException catch (err) {
      throw AccountException(
        RegExp('invalid login credentials', caseSensitive: false).hasMatch(err.message)
            ? 'Your current password is not correct'
            : err.message,
      );
    }
    await backend.updatePassword(next);
    await backend.signOut(others: true);
  }

  /// Deletes the signed-in account and everything in it (DELETE /api/account, required by
  /// Google Play and the App Store). The password is checked first, so someone holding an
  /// unlocked phone cannot delete the account. Signs out afterwards; the server refuses the
  /// admin account.
  Future<void> deleteAccount({required String password}) async {
    final user = backend.currentUser;
    if (user == null || user.email == null) throw const AccountException('Not signed in');
    if (password.isEmpty) throw const AccountException('Enter your password');
    try {
      await backend.signIn(user.email!, password);
    } on AuthException catch (err) {
      throw AccountException(
        RegExp('invalid login credentials', caseSensitive: false).hasMatch(err.message)
            ? 'Your password is not correct'
            : err.message,
      );
    }
    try {
      ApiClient.decode(await api.authed('DELETE', '/api/account'));
    } on ApiException catch (e) {
      throw AccountException(e.message);
    }
    for (final key in [_sosKey(user.id), _accessKey(user.id)]) {
      await prefs.remove(key);
    }
    try {
      await backend.signOut();
    } on Object {
      // The account is gone on the server; the session on the phone is dropped anyway
    }
  }

  /// Sends the public account request form
  Future<void> requestAccount(AccountRequestInput input) async {
    final problem = accountRequestError(input);
    if (problem != null) throw AccountException(problem);
    try {
      ApiClient.decode(await api.public('POST', '/api/account-requests', body: input.toJson()));
    } on ApiException catch (e) {
      throw AccountException(e.message);
    }
  }
}
