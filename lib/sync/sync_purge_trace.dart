import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/local_storage_service.dart';

/// Remembers purged entry ids in prefs until [JournalSyncRepository] has
/// pushed them as tombstones. Installed whether or not the device is paired:
/// a purge made while unpaired must still reach the other devices once it
/// pairs again. The map is tiny (id + timestamp) and pruned after each push.
class SyncPurgeTrace implements PurgeTrace {
  final LocalStorageService _storage;

  SyncPurgeTrace(this._storage);

  @override
  void recordPurged(Map<String, DateTime> stamps) {
    final purged = _storage.getSyncPurged();
    final now = DateTime.now();
    stamps.forEach((id, stamp) {
      purged[id] = PurgeMark(stamp: stamp, recorded: now);
    });
    // Fire-and-forget like every other prefs write in the app: the in-memory
    // prefs cache updates synchronously, so the next round sees it.
    _storage.setSyncPurged(purged);
  }

  /// Paired means URL, device token and key — a URL alone never completes a
  /// round, so deferring on it would keep the trash forever. Before the first
  /// rebuild after an update the flag is missing; fall back to the URL then,
  /// so a paired phone doesn't purge at load ahead of its first round.
  @override
  bool get defersAutoPurge =>
      _storage.getSyncPaired() ?? _storage.getSyncServerUrl() != null;
}
