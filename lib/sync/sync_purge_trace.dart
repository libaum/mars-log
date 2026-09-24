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

  @override
  bool get defersAutoPurge => _storage.getSyncServerUrl() != null;
}
