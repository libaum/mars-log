import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/location_history_repository.dart';
import 'package:mars_log/domain/day_location_point.dart';
import 'package:mars_log/domain/journal_entry.dart';

/// Zips the whole journal for backup, and restores it again:
///
/// - `entries.json` — transcripts and metadata (plus any index set aside as
///   unreadable, see [JournalRepository.corruptIndexFiles])
/// - `location_history.json` — the background location history, which
///   doesn't sync
/// - `audio/` — every recording an entry points to, trash included. Audio
///   syncs nowhere, so this is its only copy off the phone.
///
/// Zips get large with audio, so they are never held in memory: built as a
/// file in the temp dir, copied into the target folder through SAF, read
/// back as a stream on import.
class ExportService {
  final JournalRepository _repository;
  final LocationHistoryRepository _locations;

  ExportService(this._repository, this._locations);

  static const _mime = 'application/zip';
  static const _audioPrefix = 'audio/';

  /// Builds the backup zip in the temp dir and returns it. The caller deletes
  /// it once copied.
  Future<File> buildZipFile() async {
    final encoder = ZipFileEncoder();
    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().split('T').first;
    final zipPath = '${tmp.path}/mars_log_export_$stamp.zip';

    encoder.create(zipPath);
    final index = _repository.indexFile;
    if (await index.exists()) {
      await encoder.addFile(index, 'entries.json');
    }
    for (final corrupt in await _repository.corruptIndexFiles()) {
      await encoder.addFile(corrupt, corrupt.uri.pathSegments.last);
    }
    final locations = _locations.file;
    if (await locations.exists()) {
      await encoder.addFile(locations, 'location_history.json');
    }
    final audio = _repository.allEntries.expand((e) => e.audioFileNames).toSet();
    for (final name in audio) {
      final file = File(_repository.audioPath(name));
      // Stored, not deflated: m4a is compressed already.
      if (await file.exists()) {
        await encoder.addFile(file, '$_audioPrefix$name', ZipFileEncoder.STORE);
      }
    }
    await encoder.close();
    return File(zipPath);
  }

  /// Builds a zip and copies it into [treeUri] (a SAF folder) as [fileName].
  Future<void> exportTo(String treeUri, String fileName, {bool overwrite = false}) async {
    final zip = await buildZipFile();
    try {
      await SafStream().pasteLocalFile(zip.path, treeUri, fileName, _mime,
          overwrite: overwrite);
    } finally {
      try {
        await zip.delete();
      } catch (_) {}
    }
  }

  /// Lets the user pick a folder and saves a zip there. Returns the folder's
  /// name, or null if the user cancelled.
  Future<String?> exportToFolder() async {
    final dir = await SafUtil().pickDirectory(writePermission: true);
    if (dir == null) return null;
    final stamp = DateTime.now().toIso8601String().split('T').first;
    await exportTo(dir.uri, 'mars_log_export_$stamp.zip');
    return dir.name;
  }

  /// Lets the user pick a zip and merges it in: new entries (existing ids are
  /// left alone), the location history (see
  /// [LocationHistoryRepository.mergeExported]), and every recording an
  /// entry points to but this device doesn't hold — which also brings the
  /// audio back for entries a re-pair pulled from the relay. Returns the
  /// number of newly imported entries, or null if cancelled.
  Future<int?> importFromPicker() async {
    // FileType.any (not custom/zip): Android's extension filter greys out
    // our .zip on many devices. No withData: the zip may be hundreds of MB;
    // file_picker hands out a cached copy's path instead.
    final picked = await FilePicker.platform.pickFiles();
    final path = picked?.files.single.path;
    if (path == null) return null;
    return importZip(File(path));
  }

  /// [importFromPicker] without the picker.
  Future<int> importZip(File zip) async {
    final input = InputFileStream(zip.path);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      final beforeIds = _repository.entries.map((e) => e.id).toSet();

      final audioInZip = <String, ArchiveFile>{
        for (final f in archive)
          if (f.isFile && f.name.startsWith(_audioPrefix))
            f.name.substring(_audioPrefix.length): f,
      };

      for (final file in archive) {
        if (!file.isFile || file.name != 'location_history.json') continue;
        final map = jsonDecode(utf8.decode(file.content as List<int>))
            as Map<String, dynamic>;
        await _locations.mergeExported([
          for (final day in map.values)
            for (final p in day as List<dynamic>)
              DayLocationPoint.fromJson((p as Map).cast<String, dynamic>()),
        ]);
      }

      var imported = <JournalEntry>[];
      for (final file in archive) {
        if (!file.isFile || file.name != 'entries.json') continue;
        final list = jsonDecode(utf8.decode(file.content as List<int>))
            as List<dynamic>;
        imported = list
            .map((e) => JournalEntry.fromJson((e as Map).cast<String, dynamic>()))
            .map(_keepOnlyAudioIn(audioInZip.keys.toSet()))
            .toList();
      }

      // Files before entries: an entry never points at a file still missing.
      // Only what some entry (existing or imported) points to — anything else
      // would be swept as orphaned on the next start anyway.
      final wanted = {
        ..._repository.allEntries.expand((e) => e.audioFileNames),
        ...imported.expand((e) => e.audioFileNames),
      };
      for (final MapEntry(key: name, value: file) in audioInZip.entries) {
        if (!wanted.contains(name)) continue;
        final target = File(_repository.audioPath(name));
        if (await target.exists()) continue;
        final out = OutputFileStream(target.path);
        file.writeContent(out);
        await out.close();
      }

      await _repository.mergeAll(imported);
      return _repository.entries.map((e) => e.id).toSet().difference(beforeIds).length;
    } finally {
      await input.close();
    }
  }

  /// An imported entry keeps the recordings the zip carries. Exports from
  /// before audio was included carry none — such an entry comes in as
  /// "audio discarded", as it always did.
  static JournalEntry Function(JournalEntry) _keepOnlyAudioIn(Set<String> inZip) =>
      (e) {
        if (e.audioDeleted) return e..audioFileNames = [];
        final kept = e.audioFileNames.where(inZip.contains).toList();
        e.audioFileNames = kept;
        if (kept.isEmpty) e.audioDeleted = true;
        return e;
      };
}
