import 'package:shared_preferences/shared_preferences.dart';

/// Thin wrapper around SharedPreferences for non-sensitive app settings.
/// Sensitive values (API key, PIN) live in [SecureStorageService] instead.
class LocalStorageService {
  static const _keyThemeIsDark = 'theme_is_dark';
  static const _keyPinEnabled = 'pin_enabled';
  static const _keyBiometricEnabled = 'biometric_enabled';
  static const _keyAnalysisVersion = 'analysis_version';
  static const _keyReminderEnabled = 'reminder_enabled';
  static const _keyReminderMinutes = 'reminder_minutes';
  static const _keyDeleteAudioAfterTranscription =
      'delete_audio_after_transcription';

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

  /// Evening reminder: on/off and time-of-day as minutes past midnight
  /// (defaults to 21:00 = 1260).
  bool getReminderEnabled() => _prefs.getBool(_keyReminderEnabled) ?? false;
  Future<void> setReminderEnabled(bool v) =>
      _prefs.setBool(_keyReminderEnabled, v);

  int getReminderMinutes() => _prefs.getInt(_keyReminderMinutes) ?? 21 * 60;
  Future<void> setReminderMinutes(int v) =>
      _prefs.setInt(_keyReminderMinutes, v);

  /// When on, an entry's audio is discarded once it has been transcribed
  /// (status `ready`). The transcript then becomes the sole source of truth.
  bool getDeleteAudioAfterTranscription() =>
      _prefs.getBool(_keyDeleteAudioAfterTranscription) ?? false;
  Future<void> setDeleteAudioAfterTranscription(bool v) =>
      _prefs.setBool(_keyDeleteAudioAfterTranscription, v);
}
