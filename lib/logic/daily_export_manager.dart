import 'package:flutter/foundation.dart';
import 'package:mars_log/data/export_service.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/data/location_history_repository.dart';
import 'package:mars_log/logic/background_tasks.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:saf_util/saf_util.dart';
import 'package:workmanager/workmanager.dart';

const _taskUniqueName = 'mars_log_daily_export';

/// Prefix every backup this app writes carries. Pruning matches on it, so
/// nothing else in the user's folder is ever touched.
const _backupPrefix = 'mars_log_backup_';

/// How many daily backups to keep. One file per day, so this is also how far
/// back you can reach — long enough to notice something went wrong days after
/// the fact. The zips carry the audio too, so they grow with the journal —
/// seven of them is the price of the recordings being backed up at all.
const _keepBackups = 7;

/// Best-effort daily backup zip, written into the SAF folder the user picked
/// in Settings. Silent on any failure (permission revoked, folder deleted,
/// disk full) — a missed backup is unremarkable, tomorrow's run tries again.
Future<void> runDailyExport() async {
  try {
    final storage = await LocalStorageService.getInstance();
    final folderUri = storage.getDailyExportFolderUri();
    if (folderUri == null) return;

    // Read-only: the app may be running (and recording) in the other isolate.
    final repo = await JournalRepository.getInstance(readOnly: true);
    final locations = await LocationHistoryRepository.getInstance();
    final stamp = DateTime.now().toIso8601String().split('T').first;
    await ExportService(repo, locations)
        .exportTo(folderUri, '$_backupPrefix$stamp.zip', overwrite: true);

    await _pruneOldBackups(folderUri);
  } catch (_) {
    // Best-effort — never let a failed backup take down the background isolate.
  }
}

/// Deletes all but the newest [_keepBackups] backups, so the target folder
/// doesn't grow forever.
///
/// Runs *after* a successful write and swallows its own errors: failing to
/// tidy up must never cost the backup that was just made. Only files matching
/// this app's own naming pattern are considered — the folder is the user's
/// (quite possibly a synced one), and everything else in it is off limits.
Future<void> _pruneOldBackups(String folderUri) async {
  try {
    final backups = (await SafUtil().list(folderUri))
        .where((file) =>
            !file.isDir &&
            file.name.startsWith(_backupPrefix) &&
            file.name.endsWith('.zip'))
        .toList()
      // Names embed an ISO date, so lexicographic order is chronological.
      ..sort((a, b) => b.name.compareTo(a.name));

    for (final old in backups.skip(_keepBackups)) {
      await SafUtil().delete(old.uri, false);
    }
  } catch (_) {
    // Pruning is housekeeping; the backup itself already succeeded.
  }
}

/// Toggles a daily automatic backup into a folder the user picks once via
/// Android's Storage Access Framework (scoped storage means an arbitrary
/// path can't be written to without that one-time grant). Independent of the
/// manual "Export" button in Settings — same zip format, just on autopilot.
class DailyExportManager {
  final _storage = getIt<LocalStorageService>();

  final ValueNotifier<bool> enabledNotifier = ValueNotifier(false);
  final ValueNotifier<String?> folderNameNotifier = ValueNotifier(null);

  Future<void> init() async {
    enabledNotifier.value = _storage.getDailyExportEnabled();
    folderNameNotifier.value = _storage.getDailyExportFolderName();
    if (enabledNotifier.value) await _register();
  }

  /// Opens the SAF folder picker and persists the chosen folder. Returns
  /// false if the user cancelled.
  Future<bool> pickFolder() async {
    final dir = await SafUtil().pickDirectory(
      persistablePermission: true,
      writePermission: true,
    );
    if (dir == null) return false;
    await _storage.setDailyExportFolderUri(dir.uri);
    await _storage.setDailyExportFolderName(dir.name);
    folderNameNotifier.value = dir.name;
    return true;
  }

  /// Enables/disables the daily backup. Returns false if no folder has been
  /// picked yet — the toggle should then stay off.
  Future<bool> setEnabled(bool value) async {
    if (value && _storage.getDailyExportFolderUri() == null) return false;

    if (value) {
      await _register();
    } else {
      await Workmanager().cancelByUniqueName(_taskUniqueName);
    }
    enabledNotifier.value = value;
    await _storage.setDailyExportEnabled(value);
    return true;
  }

  Future<void> _register() async {
    await Workmanager().registerPeriodicTask(
      _taskUniqueName,
      kDailyExportTaskName,
      frequency: const Duration(hours: 24),
      constraints: Constraints(networkType: NetworkType.notRequired),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }
}
