import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Compile-time fallback key, supplied via
/// `--dart-define-from-file=env.json` (or `--dart-define=GEMINI_API_KEY=...`).
/// Empty when not provided, so the Settings key is used instead.
const _envApiKey = String.fromEnvironment('GEMINI_API_KEY');

/// Encrypted storage for sensitive values: the Gemini API key and the PIN hash.
class SecureStorageService {
  static const _keyApiKey = 'gemini_api_key';
  static const _keyPinHash = 'pin_hash';

  final FlutterSecureStorage _storage;

  SecureStorageService()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        );

  /// Prefers a key set in Settings; falls back to the compile-time [_envApiKey].
  Future<String?> getApiKey() async {
    final stored = await _storage.read(key: _keyApiKey);
    if (stored != null && stored.isNotEmpty) return stored;
    return _envApiKey.isNotEmpty ? _envApiKey : null;
  }
  Future<void> setApiKey(String key) =>
      _storage.write(key: _keyApiKey, value: key.trim());

  Future<bool> hasPin() async => (await _storage.read(key: _keyPinHash)) != null;

  Future<void> setPin(String pin) =>
      _storage.write(key: _keyPinHash, value: _hash(pin));

  Future<void> clearPin() => _storage.delete(key: _keyPinHash);

  Future<bool> verifyPin(String pin) async {
    final stored = await _storage.read(key: _keyPinHash);
    return stored != null && stored == _hash(pin);
  }

  String _hash(String pin) => sha256.convert(utf8.encode(pin)).toString();
}
