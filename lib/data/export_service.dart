import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/location_history_repository.dart';
import 'package:mars_log/domain/day_location_point.dart';
import 'package:mars_log/domain/journal_entry.dart';

/// Zips the journal's `entries.json` (transcripts + metadata only, no audio —
/// keeps exports small and fast) and the background location history
/// (`location_history.json`) for backup, and restores both again.
///
/// The location history is in no other backup: it doesn't sync, and the
/// app opts out of Android's auto-backup to Google (`allowBackup="false"`).
class ExportService {
  final JournalRepository _repository;
  final LocationHistoryRepository _locations;

  ExportService(this._repository, this._locations);

  /// Builds the backup zip in the temp dir and returns its path.
  Future<String> _buildZip() async {
    final encoder = ZipFileEncoder();
    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().split('T').first;
    final zipPath = '${tmp.path}/mars_log_export_$stamp.zip';

    encoder.create(zipPath);
    final index = _repository.indexFile;
    if (await index.exists()) {
      await encoder.addFile(index, 'entries.json');
    }
    final locations = _locations.file;
    if (await locations.exists()) {
      await encoder.addFile(locations, 'location_history.json');
    }
    await encoder.close();
    return zipPath;
  }

  /// Builds a zip and returns its raw bytes — for callers that hand it to
  /// something other than a file_picker dialog (e.g. a SAF write into a
  /// user-chosen folder for the daily auto-backup).
  Future<Uint8List> buildZipBytes() async {
    final zipPath = await _buildZip();
    return File(zipPath).readAsBytes();
  }

  /// Builds a zip and hands it to the OS share sheet.
  Future<void> exportAndShare() async {
    final zipPath = await _buildZip();
    await Share.shareXFiles(
      [XFile(zipPath)],
      subject: 'Mars Log Export',
    );
  }

  /// Builds a zip and lets the user save it to a folder on the device.
  /// Returns the saved path, or null if the user cancelled.
  Future<String?> exportToDisk() async {
    final zipPath = await _buildZip();
    final bytes = await File(zipPath).readAsBytes();
    return FilePicker.platform.saveFile(
      dialogTitle: 'Save Mars Log Export',
      fileName: zipPath.split('/').last,
      bytes: bytes,
    );
  }

  /// Lets the user pick a zip and merges its entries (transcripts + metadata
  /// only) into the journal, and its location history into this device's
  /// (see [LocationHistoryRepository.mergeExported]).
  /// Imported entries never carry audio, even if the
  /// source export predates this and still contains an `audio/` folder — it
  /// is ignored. Returns the number of newly imported entries, or null if
  /// cancelled.
  Future<int?> importFromPicker() async {
    // FileType.any (not custom/zip): Android's extension filter greys out
    // our .zip on many devices. withData ensures we get bytes even for
    // content URIs (Downloads, Drive) that expose no filesystem path.
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked == null) return null;
    final file = picked.files.single;

    final bytes = file.bytes ??
        (file.path != null ? await File(file.path!).readAsBytes() : null);
    if (bytes == null) return null;
    final archive = ZipDecoder().decodeBytes(bytes);

    List<JournalEntry> imported = const [];
    final beforeIds = _repository.entries.map((e) => e.id).toSet();

    for (final file in archive) {
      if (!file.isFile || !file.name.endsWith('location_history.json')) continue;
      final map = jsonDecode(utf8.decode(file.content as List<int>))
          as Map<String, dynamic>;
      await _locations.mergeExported([
        for (final day in map.values)
          for (final p in day as List<dynamic>)
            DayLocationPoint.fromJson((p as Map).cast<String, dynamic>()),
      ]);
    }

    for (final file in archive) {
      if (!file.isFile || !file.name.endsWith('entries.json')) continue;
      final list = jsonDecode(utf8.decode(file.content as List<int>))
          as List<dynamic>;
      imported = list
          .map((e) => JournalEntry.fromJson((e as Map).cast<String, dynamic>()))
          .map((e) => e
            ..audioDeleted = true
            ..audioFileNames = [])
          .toList();
    }

    await _repository.mergeAll(imported);
    return _repository.entries.map((e) => e.id).toSet().difference(beforeIds).length;
  }
}
