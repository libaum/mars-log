import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/domain/journal_entry.dart';

/// Zips the whole journal (`entries.json` + `audio/`) for backup, and restores
/// it again. Export/import is the app's only safety net against data loss.
class ExportService {
  final JournalRepository _repository;

  ExportService(this._repository);

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
    final audioDir = _repository.audioDir;
    if (await audioDir.exists()) {
      await encoder.addDirectory(audioDir, includeDirName: true);
    }
    await encoder.close();
    return zipPath;
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

  /// Lets the user pick a zip and merges its entries + audio into the journal.
  /// Returns the number of newly imported entries, or null if cancelled.
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
      if (!file.isFile) continue;
      final name = file.name.split('/').last;

      if (file.name.endsWith('entries.json')) {
        final list = jsonDecode(utf8.decode(file.content as List<int>))
            as List<dynamic>;
        imported = list
            .map((e) => JournalEntry.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
      } else if (name.isNotEmpty && file.name.contains('audio/')) {
        final out = File(_repository.audioPath(name));
        await out.writeAsBytes(file.content as List<int>);
      }
    }

    await _repository.mergeAll(imported);
    return _repository.entries.map((e) => e.id).toSet().difference(beforeIds).length;
  }
}
