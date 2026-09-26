import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypted storage for sensitive values: the cloud providers' API keys
/// (the cloud analysis options) and the PIN hash.
class SecureStorageService {
  static String _apiKeyName(String provider) => '${provider}_api_key';
  static const _keyPinHash = 'pin_hash';

  final FlutterSecureStorage _storage;

  SecureStorageService()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        );

  /// [provider]: an AnalysisProvider name — `gemini`, `mistral`.
  Future<String?> getApiKey(String provider) =>
      _storage.read(key: _apiKeyName(provider));

  Future<void> setApiKey(String provider, String key) => key.trim().isEmpty
      ? _storage.delete(key: _apiKeyName(provider))
      : _storage.write(key: _apiKeyName(provider), value: key.trim());

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
