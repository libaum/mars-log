import 'dart:convert';

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
  static const _keyMonthReviewPrefix = 'month_review_';
  static const _keyLocationTrackingEnabled = 'location_tracking_enabled';
  static const _keyDailyExportEnabled = 'daily_export_enabled';
  static const _keyDailyExportFolderUri = 'daily_export_folder_uri';
  static const _keyDailyExportFolderName = 'daily_export_folder_name';
  // Sync keys come in two kinds, and the difference matters in Mars Hub,
  // where every module shares one prefs file with mars_thoughts:
  //
  // - The relay URL belongs to the *device*: same name as mars_thoughts, so
  //   Mars Hub pairs once and every module follows.
  // - Watermarks and the purge trace belong to the *module*: prefixed, or
  //   the modules would advance each other's watermarks and push each
  //   other's tombstones. (On the phone the apps have separate prefs; the
  //   prefix just costs nothing there.)
  static const _keySyncServerUrl = 'sync_server_url';
  static const _keySyncPaired = 'log_sync_paired';
  static const _keySyncPurged = 'log_sync_purged';
  static const _keySyncLastSyncedAt = 'log_sync_last_synced_at';
  static const _keySyncLastSeenSeq = 'log_sync_last_seen_seq';
  // Value keeps the old "hub" name: paired devices already store it
  // (docs/adr/0001-relay-rename-keeps-hub-id-on-the-wire.md at the Mars root).
  static const _keySyncLastSeenRelayId = 'log_sync_last_seen_hub_id';

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

  /// Cached AI monthly recap text, keyed by "yyyy-M". Regenerated on demand
  /// only (see StatsScreen) — this just avoids re-fetching when switching
  /// months back and forth.
  String? getMonthReview(String monthKey) =>
      _prefs.getString('$_keyMonthReviewPrefix$monthKey');
  Future<void> setMonthReview(String monthKey, String text) =>
      _prefs.setString('$_keyMonthReviewPrefix$monthKey', text);

  /// When to ask for the self-rating: kRatedAfter (default) or
  /// kRatedBefore the recording.
  String getSelfRatingTiming() => _prefs.getString('self_rating_timing') ?? 'after';
  Future<void> setSelfRatingTiming(String timing) =>
      _prefs.setString('self_rating_timing', timing);

  /// The Gemini models — Settings → Modell. Null: the default
  /// (kDefaultTranscriptionModel / kDefaultAnalysisModel).
  String? getTranscriptionModel() => _prefs.getString('gemini_transcription_model');
  Future<void> setTranscriptionModel(String? id) => (id ?? '').trim().isEmpty
      ? _prefs.remove('gemini_transcription_model')
      : _prefs.setString('gemini_transcription_model', id!.trim());

  String? getAnalysisModel() => _prefs.getString('gemini_analysis_model');
  Future<void> setAnalysisModel(String? id) => (id ?? '').trim().isEmpty
      ? _prefs.remove('gemini_analysis_model')
      : _prefs.setString('gemini_analysis_model', id!.trim());

  /// Background location tracking: a few GPS fixes a day, independent of
  /// journal entries (see [LocationTrackingManager]).
  bool getLocationTrackingEnabled() =>
      _prefs.getBool(_keyLocationTrackingEnabled) ?? false;
  Future<void> setLocationTrackingEnabled(bool v) =>
      _prefs.setBool(_keyLocationTrackingEnabled, v);

  /// Daily automatic backup into a user-chosen (SAF) folder — see
  /// [DailyExportManager]. The URI is the persisted SAF tree permission; the
  /// name is cached separately so Settings can show it without resolving the
  /// URI again.
  bool getDailyExportEnabled() =>
      _prefs.getBool(_keyDailyExportEnabled) ?? false;
  Future<void> setDailyExportEnabled(bool v) =>
      _prefs.setBool(_keyDailyExportEnabled, v);

  String? getDailyExportFolderUri() =>
      _prefs.getString(_keyDailyExportFolderUri);
  Future<void> setDailyExportFolderUri(String? v) => v == null
      ? _prefs.remove(_keyDailyExportFolderUri)
      : _prefs.setString(_keyDailyExportFolderUri, v);

  String? getDailyExportFolderName() =>
      _prefs.getString(_keyDailyExportFolderName);
  Future<void> setDailyExportFolderName(String? v) => v == null
      ? _prefs.remove(_keyDailyExportFolderName)
      : _prefs.setString(_keyDailyExportFolderName, v);

  // ── Sync ─────────────────────────────────────────────────────────────────

  /// Purged entries whose tombstone hasn't been pushed yet. Once an entry is
  /// purged it is gone from the index, so this is the only trace the sync
  /// layer has left to tell other devices to drop their copy. Pruned after
  /// a successful push.
  Map<String, PurgeMark> getSyncPurged() {
    final json = _prefs.getString(_keySyncPurged);
    if (json == null) return {};
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return map.map((id, v) {
        DateTime at(Object? ms) => DateTime.fromMillisecondsSinceEpoch(ms as int);
        // A bare number is the one-time format from before stamp and
        // recording time were split.
        return MapEntry(
          id,
          v is List
              ? PurgeMark(stamp: at(v[0]), recorded: at(v[1]))
              : PurgeMark(stamp: at(v), recorded: at(v)),
        );
      });
    } catch (_) {
      return {};
    }
  }

  Future<void> setSyncPurged(Map<String, PurgeMark> purged) async {
    final json = jsonEncode(purged.map((id, m) => MapEntry(id, [
          m.stamp.millisecondsSinceEpoch,
          m.recorded.millisecondsSinceEpoch,
        ])));
    await _prefs.setString(_keySyncPurged, json);
  }

  String? getSyncServerUrl() => _prefs.getString(_keySyncServerUrl);

  Future<void> setSyncServerUrl(String? url) async {
    if (url == null) {
      await _prefs.remove(_keySyncServerUrl);
    } else {
      await _prefs.setString(_keySyncServerUrl, url);
    }
  }

  /// Whether the last pairing rebuild found URL, device token and key all
  /// present — mirrored here because those secrets are only readable async,
  /// and the journal decides on its 30-day purge synchronously at load.
  /// Null on a device that hasn't run a rebuild since this flag existed.
  bool? getSyncPaired() => _prefs.getBool(_keySyncPaired);

  Future<void> setSyncPaired(bool paired) => _prefs.setBool(_keySyncPaired, paired);

  DateTime? getSyncLastSyncedAt() {
    final ms = _prefs.getInt(_keySyncLastSyncedAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setSyncLastSyncedAt(DateTime? at) async {
    if (at == null) {
      await _prefs.remove(_keySyncLastSyncedAt);
    } else {
      await _prefs.setInt(_keySyncLastSyncedAt, at.millisecondsSinceEpoch);
    }
  }

  /// Relay sequence number up to which this device has pulled, and which relay
  /// instance that number belongs to. Independent of [getSyncLastSyncedAt],
  /// which is the *push* watermark on the local clock.
  int? getSyncLastSeenSeq() => _prefs.getInt(_keySyncLastSeenSeq);

  String? getSyncLastSeenRelayId() => _prefs.getString(_keySyncLastSeenRelayId);

  Future<void> setSyncPullWatermark({
    required int? seq,
    required String? relayId,
  }) async {
    if (seq == null || relayId == null) {
      await _prefs.remove(_keySyncLastSeenSeq);
      await _prefs.remove(_keySyncLastSeenRelayId);
    } else {
      await _prefs.setInt(_keySyncLastSeenSeq, seq);
      await _prefs.setString(_keySyncLastSeenRelayId, relayId);
    }
  }
}

/// A purge waiting to be pushed as a tombstone.
///
/// [stamp] is the time the tombstone competes with in last-write-wins;
/// [recorded] is when this device made it. They differ for the automatic
/// 30-day purge, whose stamp lies in the past on purpose. The push watermark
/// is compared against [recorded] — against [stamp], such a tombstone would
/// sit behind the watermark from birth and never be pushed.
class PurgeMark {
  final DateTime stamp;
  final DateTime recorded;
  const PurgeMark({required this.stamp, required this.recorded});
}
