import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:mars_log/domain/journal_entry.dart';

/// Owns the on-disk journal: `entries.json` (the index) and the `audio/` folder.
///
/// The entry list is held in memory and written back on every mutation, so the
/// whole journal is a single directory that can be zipped for export.
class JournalRepository {
  static const _indexFileName = 'entries.json';
  static const _audioDirName = 'audio';

  late final Directory _docsDir;
  final List<JournalEntry> _entries = [];

  JournalRepository._();

  static Future<JournalRepository> getInstance() async {
    final repo = JournalRepository._();
    await repo._load();
    return repo;
  }

  Future<void> _load() async {
    _docsDir = await getApplicationDocumentsDirectory();
    await Directory(audioDirPath).create(recursive: true);

    final file = File(_indexPath);
    if (!await file.exists()) return;
    try {
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      _entries
        ..clear()
        ..addAll(list.map((e) =>
            JournalEntry.fromJson((e as Map).cast<String, dynamic>())));
      _sort();
    } catch (_) {
      // Corrupt index → start empty rather than crash. Audio files survive.
    }
  }

  String get _indexPath => '${_docsDir.path}/$_indexFileName';
  String get audioDirPath => '${_docsDir.path}/$_audioDirName';
  String audioPath(String fileName) => '$audioDirPath/$fileName';

  /// Newest first.
  List<JournalEntry> get entries => List.unmodifiable(_entries);

  void _sort() => _entries.sort((a, b) {
        final byDay = b.day.compareTo(a.day);
        return byDay != 0 ? byDay : b.createdAt.compareTo(a.createdAt);
      });

  Future<void> _persist() async {
    final json = jsonEncode(_entries.map((e) => e.toJson()).toList());
    await File(_indexPath).writeAsString(json);
  }

  Future<void> upsert(JournalEntry entry) async {
    final i = _entries.indexWhere((e) => e.id == entry.id);
    if (i >= 0) {
      _entries[i] = entry;
    } else {
      _entries.add(entry);
    }
    _sort();
    await _persist();
  }

  Future<void> delete(JournalEntry entry) async {
    _entries.removeWhere((e) => e.id == entry.id);
    await _persist();
    final audio = File(audioPath(entry.audioFileName));
    if (await audio.exists()) await audio.delete();
  }

  /// Merge imported entries (dedupe by id); does not remove existing ones.
  Future<void> mergeAll(List<JournalEntry> imported) async {
    for (final entry in imported) {
      if (_entries.every((e) => e.id != entry.id)) {
        _entries.add(entry);
      }
    }
    _sort();
    await _persist();
  }

  File get indexFile => File(_indexPath);
  Directory get audioDir => Directory(audioDirPath);
}
