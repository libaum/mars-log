import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/data/secure_storage_service.dart';
import 'package:mars_log/services/service_locator.dart';

/// Gates the app behind an optional PIN / biometric lock.
/// The journal is shown only when [lockedNotifier] is false.
class LockManager {
  final _storage = getIt<LocalStorageService>();
  final _secure = getIt<SecureStorageService>();
  final LocalAuthentication _auth = LocalAuthentication();

  final ValueNotifier<bool> lockedNotifier = ValueNotifier(false);

  bool get lockEnabled =>
      _storage.getPinEnabled() || _storage.getBiometricEnabled();
  bool get pinEnabled => _storage.getPinEnabled();
  bool get biometricEnabled => _storage.getBiometricEnabled();

  /// Called once at startup and whenever the app is resumed.
  void lockIfEnabled() {
    if (lockEnabled) lockedNotifier.value = true;
  }

  void unlock() => lockedNotifier.value = false;

  Future<bool> deviceSupportsBiometrics() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticateBiometric() async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Mars Log entsperren',
        options: const AuthenticationOptions(stickyAuth: true),
      );
      if (ok) unlock();
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<bool> verifyPin(String pin) async {
    final ok = await _secure.verifyPin(pin);
    if (ok) unlock();
    return ok;
  }
}
