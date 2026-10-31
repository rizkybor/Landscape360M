import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers.dart';
import '../../data/account/account_repository.dart';
import '../../data/account/biometric_login.dart';

// Sign in with Face ID (or Touch ID / fingerprint) on phones that have it. After signing in
// with the password the app offers it once per account; it can be switched on and off in
// User Account. The saved login is replaced when the password is changed here, and removed
// when it no longer works, when it is switched off, or when the account is deleted.

final biometricGateProvider = Provider<BiometricGate>((ref) => LocalAuthGate());
final savedLoginsProvider = Provider<SavedLogins>((ref) => KeychainSavedLogins());
final biometricPrefsProvider = Provider<SharedPreferencesAsync>((ref) => SharedPreferencesAsync());

class BiometricState {
  const BiometricState({this.kind, this.email, this.ready = false});

  /// The biometric this phone can use, or null (then nothing is offered)
  final BiometricKind? kind;

  /// The account saved for it, or null when it is off
  final String? email;
  final bool ready;

  bool get available => kind != null;
  bool get enabled => kind != null && email != null;
  String get label => kind == null ? 'Face ID' : biometricLabel(kind!);
}

final biometricProvider = NotifierProvider<BiometricController, BiometricState>(BiometricController.new);

class BiometricController extends Notifier<BiometricState> {
  @override
  BiometricState build() {
    unawaited(Future(refresh));
    return const BiometricState();
  }

  BiometricGate get _gate => ref.read(biometricGateProvider);
  SavedLogins get _saved => ref.read(savedLoginsProvider);

  Future<void> refresh() async {
    if (!ref.mounted) return;
    final kind = await _gate.available();
    if (!ref.mounted) return;
    final saved = kind == null ? null : await _saved.read();
    if (ref.mounted) state = BiometricState(kind: kind, email: saved?.email, ready: true);
  }

  static String _askedKey(String email) => 'l360-biometric-asked-${email.trim().toLowerCase()}';

  /// Whether to offer it after a password sign-in: available, not on for this account, and
  /// not offered to this account before
  Future<bool> shouldOffer(String email) async {
    if (!state.available) await refresh();
    if (!state.available || state.email?.toLowerCase() == email.trim().toLowerCase()) return false;
    return !(await ref.read(biometricPrefsProvider).getBool(_askedKey(email)) ?? false);
  }

  Future<void> markOffered(String email) => ref.read(biometricPrefsProvider).setBool(_askedKey(email), true);

  /// Switches it on for this account after the face or finger is checked; false if not
  Future<bool> enable(String email, String password) async {
    if (!state.available) return false;
    if (!await _gate.check('Use ${state.label} to sign in to Landscape 360')) return false;
    final e = email.trim().toLowerCase();
    await _saved.write((email: e, password: password));
    state = BiometricState(kind: state.kind, email: e, ready: true);
    return true;
  }

  Future<void> disable() async {
    await _saved.clear();
    state = BiometricState(kind: state.kind, ready: true);
  }

  /// The password changed here: the saved one follows, so it keeps working
  Future<void> passwordChanged(String email, String password) async {
    if (state.email != email.trim().toLowerCase()) return;
    await _saved.write((email: state.email!, password: password));
  }

  /// Signs in with the saved login after the face or finger is checked. Returns false when
  /// it was cancelled; throws [AccountException] when the server refused (the saved login is
  /// then removed: the password was changed elsewhere)
  Future<bool> signIn() async {
    final saved = await _saved.read();
    if (saved == null || !state.available) {
      await refresh();
      return false;
    }
    if (!await _gate.check('Sign in to Landscape 360 as ${saved.email}')) return false;
    try {
      await ref.read(accountRepositoryProvider).signIn(saved.email, saved.password);
      return true;
    } on AccountException catch (e) {
      if (e.message == 'Wrong email or password') {
        await disable();
        throw AccountException(
          'Your password has changed. Sign in with your password, then switch ${state.label} on again.',
        );
      }
      rethrow;
    }
  }
}
