import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_sync_flutter/mars_sync_flutter.dart';

/// Mars Log is never the first device — the key already exists — so German,
/// paste the key.
const logSyncStrings = SyncStrings.german(
  unpairBody: 'Entfernt Relay-Kopplung und Schlüssel von diesem Gerät. Die '
      'Einträge bleiben, wo sie sind — hier und auf dem Relay.',
);

/// The pairing's non-secret half, in this app's prefs. Mars Hub uses it too:
/// the relay URL key is shared with the other modules, the rest is prefixed.
class LogPairingPrefs implements PairingPrefs {
  final LocalStorageService _storage;

  LogPairingPrefs(this._storage);

  @override
  String? get serverUrl => _storage.getSyncServerUrl();

  @override
  Future<void> setServerUrl(String? url) => _storage.setSyncServerUrl(url);

  @override
  DateTime? get lastSyncedAt => _storage.getSyncLastSyncedAt();

  @override
  Future<void> setLastSyncedAt(DateTime? at) => _storage.setSyncLastSyncedAt(at);

  @override
  Future<void> clearPullWatermark() =>
      _storage.setSyncPullWatermark(seq: null, relayId: null);

  /// The 30-day purge decides at load, synchronously, whether a sync partner
  /// may still need the trash (see SyncPurgeTrace).
  @override
  Future<void> setPaired(bool paired) => _storage.setSyncPaired(paired);
}
