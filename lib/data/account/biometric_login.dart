import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

// Sign in with Face ID / Touch ID / fingerprint, on phones that have it. The email and
// password are kept in the Keychain (Android Keystore) of this phone only, readable only
// while the phone has a passcode, and only after the face or finger is checked.

enum BiometricKind { face, fingerprint }

/// What the phone calls it: Face ID and Touch ID on iPhone
String biometricLabel(BiometricKind kind, {bool? ios}) =>
    switch ((kind, ios ?? defaultTargetPlatform == TargetPlatform.iOS)) {
      (BiometricKind.face, true) => 'Face ID',
      (BiometricKind.fingerprint, true) => 'Touch ID',
      (BiometricKind.face, false) => 'face unlock',
      (BiometricKind.fingerprint, false) => 'fingerprint',
    };

abstract interface class BiometricGate {
  /// The biometric this phone can use now (set up and allowed), or null
  Future<BiometricKind?> available();

  /// Asks for the face or finger; false when it was cancelled or not recognised
  Future<bool> check(String reason);
}

class LocalAuthGate implements BiometricGate {
  final _auth = LocalAuthentication();

  @override
  Future<BiometricKind?> available() async {
    try {
      if (!await _auth.isDeviceSupported() || !await _auth.canCheckBiometrics) return null;
      final kinds = await _auth.getAvailableBiometrics();
      if (kinds.contains(BiometricType.face)) return BiometricKind.face;
      if (kinds.contains(BiometricType.fingerprint)) return BiometricKind.fingerprint;
      // Android reports "strong" / "weak" without saying which sensor
      if (kinds.contains(BiometricType.strong)) return BiometricKind.fingerprint;
      return null;
    } on Exception {
      // No plugin (tests) or the phone refused: not offered
      return null;
    }
  }

  @override
  Future<bool> check(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: true, persistAcrossBackgrounding: true);
    } on Exception {
      return false;
    }
  }
}

typedef SavedLogin = ({String email, String password});

abstract interface class SavedLogins {
  Future<SavedLogin?> read();
  Future<void> write(SavedLogin login);
  Future<void> clear();
}

class KeychainSavedLogins implements SavedLogins {
  KeychainSavedLogins({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Only on this phone (never in a backup or on another device), and gone if the
            // phone's passcode is removed
            iOptions: IOSOptions(accessibility: KeychainAccessibility.passcode),
          );

  static const _key = 'l360-biometric-login';
  final FlutterSecureStorage _storage;

  @override
  Future<SavedLogin?> read() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (email: j['email'] as String, password: j['password'] as String);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(SavedLogin login) =>
      _storage.write(key: _key, value: jsonEncode({'email': login.email, 'password': login.password}));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
