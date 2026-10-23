import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_sync_flutter/mars_sync_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mars Log is never the first device — the key already exists — so German,
/// paste the key.
const logSyncStrings = SyncStrings.german(
  unpairBody: 'Entfernt Relay-Kopplung und Schlüssel von diesem Gerät. Die '
      'Einträge bleiben, wo sie sind — hier und auf dem Relay.',
);

/// The module's sync ledger, in this app's prefs. Mars Hub uses it too:
/// there every module shares one prefs file, so the log's keys carry `log_`
/// (the relay URL deliberately doesn't — see [SyncLedger]).
SyncLedger logLedger(SharedPreferences prefs) => SyncLedger(prefs, keyPrefix: 'log_');

/// The journal's purges go to the [SyncLedger] until they are pushed as
/// tombstones. Installed whether or not the device is paired: a purge made
/// while unpaired must still reach the other devices once it pairs again.
class SyncPurgeTrace implements PurgeTrace {
  final SyncLedger _ledger;

  SyncPurgeTrace(this._ledger);

  @override
  void recordPurged(Map<String, DateTime> stamps) => _ledger.recordPurged(stamps);

  /// Paired means URL, device token and key — a URL alone never completes a
  /// round, so deferring on it would keep the trash forever.
  @override
  bool get defersAutoPurge => _ledger.paired;
}
