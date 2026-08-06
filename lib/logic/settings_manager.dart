import 'package:flutter/foundation.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/data/secure_storage_service.dart';
import 'package:mars_log/services/service_locator.dart';

/// Holds user-facing settings: Gemini API key and the lock (PIN / biometric)
/// toggles. Sensitive values are delegated to [SecureStorageService].
class SettingsManager {
  final _storage = getIt<LocalStorageService>();
  final _secure = getIt<SecureStorageService>();

  late final ValueNotifier<bool> pinEnabledNotifier;
  late final ValueNotifier<bool> biometricEnabledNotifier;
  late final ValueNotifier<String> analysisEngineNotifier;
  final ValueNotifier<bool> hasApiKeyNotifier = ValueNotifier(false);

  SettingsManager() {
    pinEnabledNotifier = ValueNotifier(_storage.getPinEnabled());
    biometricEnabledNotifier = ValueNotifier(_storage.getBiometricEnabled());
    analysisEngineNotifier = ValueNotifier(_storage.getAnalysisEngine());
    _initApiKey();
  }

  Future<void> _initApiKey() async {
    final key = await _secure.getApiKey();
    hasApiKeyNotifier.value = key != null && key.isNotEmpty;
  }

  Future<String?> getApiKey() => _secure.getApiKey();

  Future<void> setApiKey(String key) async {
    await _secure.setApiKey(key);
    hasApiKeyNotifier.value = key.trim().isNotEmpty;
  }

  Future<void> setPin(String pin) async {
    await _secure.setPin(pin);
    await _storage.setPinEnabled(true);
    pinEnabledNotifier.value = true;
  }

  Future<void> disablePin() async {
    await _secure.clearPin();
    await _storage.setPinEnabled(false);
    pinEnabledNotifier.value = false;
  }

  Future<void> setBiometricEnabled(bool v) async {
    await _storage.setBiometricEnabled(v);
    biometricEnabledNotifier.value = v;
  }

  Future<void> setAnalysisEngine(String v) async {
    await _storage.setAnalysisEngine(v);
    analysisEngineNotifier.value = v;
  }
}
