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

  /// How long trashed entries survive before they are purged automatically.
  static const trashRetention = Duration(days: 30);

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
      await _purgeExpired();
    } catch (_) {
      // Corrupt index → start empty rather than crash. Audio files survive.
    }
    await _purgeOrphanedAudio();
  }

  /// Deletes audio files that no entry points to — e.g. a recording whose app
  /// process died mid-way (killed, crashed) before an entry was ever created.
  Future<void> _purgeOrphanedAudio() async {
    final known = _entries.expand((e) => e.audioFileNames).toSet();
    final dir = Directory(audioDirPath);
    await for (final file in dir.list()) {
      if (file is! File) continue;
      final name = file.uri.pathSegments.last;
      if (!known.contains(name)) await file.delete();
    }
  }

  String get _indexPath => '${_docsDir.path}/$_indexFileName';
  String get audioDirPath => '${_docsDir.path}/$_audioDirName';
  String audioPath(String fileName) => '$audioDirPath/$fileName';

  /// Active (non-trashed) entries, newest first.
  List<JournalEntry> get entries =>
      List.unmodifiable(_entries.where((e) => e.deletedAt == null));

  /// Trashed entries, most recently deleted first.
  List<JournalEntry> get deletedEntries {
    final list = _entries.where((e) => e.deletedAt != null).toList()
      ..sort((a, b) => b.deletedAt!.compareTo(a.deletedAt!));
    return List.unmodifiable(list);
  }

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

  /// Soft-delete: move the entry to the trash. Audio is kept for restore.
  /// Sets [JournalEntry.deletedAt] synchronously (so [entries] hides it in the
  /// same frame) and returns the persistence future.
  Future<void> moveToTrash(JournalEntry entry) {
    entry.deletedAt = DateTime.now();
    return _persist();
  }

  /// Bring a trashed entry back into the active timeline.
  Future<void> restore(JournalEntry entry) async {
    entry.deletedAt = null;
    _sort();
    await _persist();
  }

  /// Permanently remove one entry (and its audio). Irreversible.
  Future<void> purge(JournalEntry entry) async {
    _entries.removeWhere((e) => e.id == entry.id);
    await _persist();
    await _deleteAudio(entry);
  }

  /// Permanently remove every trashed entry (and its audio). Irreversible.
  Future<void> emptyTrash() async {
    final trashed = _entries.where((e) => e.deletedAt != null).toList();
    _entries.removeWhere((e) => e.deletedAt != null);
    await _persist();
    for (final e in trashed) {
      await _deleteAudio(e);
    }
  }

  /// Purge trashed entries older than [trashRetention]. Called on load.
  Future<void> _purgeExpired() async {
    final cutoff = DateTime.now().subtract(trashRetention);
    bool expired(JournalEntry e) =>
        e.deletedAt != null && e.deletedAt!.isBefore(cutoff);
    final gone = _entries.where(expired).toList();
    if (gone.isEmpty) return;
    _entries.removeWhere(expired);
    await _persist();
    for (final e in gone) {
      await _deleteAudio(e);
    }
  }

  Future<void> _deleteAudio(JournalEntry entry) async {
    for (final name in entry.audioFileNames) {
      await deleteAudioFile(name);
    }
  }

  /// Discards all of the entry's audio files, keeping the entry (used when
  /// the user opts to drop audio after transcription, or when a newly
  /// recorded snippet's audio is folded into the transcript instead of being
  /// kept). The caller sets [JournalEntry.audioDeleted] / clears the list.
  Future<void> discardAudio(JournalEntry entry) => _deleteAudio(entry);

  /// Deletes a single standalone audio file by name.
  Future<void> deleteAudioFile(String fileName) async {
    final file = File(audioPath(fileName));
    if (await file.exists()) await file.delete();
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
}
