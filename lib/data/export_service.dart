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

  /// Builds a zip and hands it to the OS share sheet.
  Future<void> exportAndShare() async {
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

    await Share.shareXFiles(
      [XFile(zipPath)],
      subject: 'Mars Log Export',
    );
  }

  /// Lets the user pick a zip and merges its entries + audio into the journal.
  /// Returns the number of newly imported entries, or null if cancelled.
  Future<int?> importFromPicker() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (picked == null || picked.files.single.path == null) return null;

    final bytes = await File(picked.files.single.path!).readAsBytes();
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
