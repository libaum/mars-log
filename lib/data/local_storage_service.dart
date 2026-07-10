import 'package:shared_preferences/shared_preferences.dart';

/// Thin wrapper around SharedPreferences for non-sensitive app settings.
/// Sensitive values (API key, PIN) live in [SecureStorageService] instead.
class LocalStorageService {
  static const _keyThemeIsDark = 'theme_is_dark';
  static const _keyPinEnabled = 'pin_enabled';
  static const _keyBiometricEnabled = 'biometric_enabled';
  static const _keyAnalysisVersion = 'analysis_version';

  final SharedPreferences _prefs;

  LocalStorageService._(this._prefs);

  static Future<LocalStorageService> getInstance() async {
    final prefs = await SharedPreferences.getInstance();
    return LocalStorageService._(prefs);
  }

  /// Theme mode (null → follow system)
  bool? getThemeIsDark() => _prefs.getBool(_keyThemeIsDark);
  Future<void> setThemeIsDark(bool isDark) =>
      _prefs.setBool(_keyThemeIsDark, isDark);

  /// Lock settings
  bool getPinEnabled() => _prefs.getBool(_keyPinEnabled) ?? false;
  Future<void> setPinEnabled(bool v) => _prefs.setBool(_keyPinEnabled, v);

  bool getBiometricEnabled() => _prefs.getBool(_keyBiometricEnabled) ?? false;
  Future<void> setBiometricEnabled(bool v) =>
      _prefs.setBool(_keyBiometricEnabled, v);

  /// Analysis prompt version last used (for future batch re-analysis)
  int getAnalysisVersion() => _prefs.getInt(_keyAnalysisVersion) ?? 0;
  Future<void> setAnalysisVersion(int v) =>
      _prefs.setInt(_keyAnalysisVersion, v);
}
