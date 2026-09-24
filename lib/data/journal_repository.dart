import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mars_log/domain/journal_entry.dart';

/// Where purges leave a trace, so the sync layer can still tell other devices
/// about entries that no longer exist here. Null on a device without sync —
/// then a purge is simply local.
abstract class PurgeTrace {
  void recordPurged(Set<String> ids);
}

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

  /// See [PurgeTrace]. Given at construction because the 30-day retention
  /// purge runs while loading — a trace installed afterwards would miss it.
  final PurgeTrace? _purgeTrace;

  /// Bumped after every write, including ones a sync round applied. Anything
  /// showing entries can listen here and stay correct without knowing who
  /// changed them — which is what lets a remote edit repaint the screen.
  final revision = ValueNotifier<int>(0);

  /// Every local mutation moves the sync clock. Done here rather than at each
  /// call site: every write in the app already funnels through this class, so
  /// a mutation added later cannot forget to stamp itself.
  void _stamp(JournalEntry entry) => entry.changedAt = DateTime.now();

  void _tracePurge(Iterable<JournalEntry> gone) {
    final trace = _purgeTrace;
    if (trace == null || gone.isEmpty) return;
    trace.recordPurged(gone.map((e) => e.id).toSet());
  }

  JournalRepository._(this._purgeTrace);

  /// [directory] defaults to the app documents dir — private on Android, but
  /// `~/Documents` on Linux, so the desktop hub passes its own.
  static Future<JournalRepository> getInstance({
    PurgeTrace? purgeTrace,
    Directory? directory,
  }) async {
    final repo = JournalRepository._(purgeTrace);
    await repo._load(directory);
    return repo;
  }

  Future<void> _load(Directory? directory) async {
    _docsDir = directory ?? await getApplicationDocumentsDirectory();
    await _docsDir.create(recursive: true);
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
    revision.value++;
  }

  Future<void> upsert(JournalEntry entry) async {
    _stamp(entry);
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
    _stamp(entry);
    return _persist();
  }

  /// Bring a trashed entry back into the active timeline.
  Future<void> restore(JournalEntry entry) async {
    entry.deletedAt = null;
    _stamp(entry);
    _sort();
    await _persist();
  }

  /// Permanently remove one entry (and its audio). Irreversible.
  Future<void> purge(JournalEntry entry) async {
    _tracePurge([entry]);
    _entries.removeWhere((e) => e.id == entry.id);
    await _persist();
    await _deleteAudio(entry);
  }

  /// Permanently remove every trashed entry (and its audio). Irreversible.
  Future<void> emptyTrash() async {
    final trashed = _entries.where((e) => e.deletedAt != null).toList();
    _tracePurge(trashed);
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
    // Both devices run the same 30-day rule and will each produce this
    // tombstone. Harmless: applying it twice is a no-op.
    _tracePurge(gone);
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
        // Stamped now, not with the stamp from the zip: importing *is* a
        // local change, and an old stamp would sit behind the sync
        // watermark and never be pushed.
        _stamp(entry);
        _entries.add(entry);
      }
    }
    _sort();
    await _persist();
  }

  /// Every entry, trashed included — what the sync layer walks.
  List<JournalEntry> get allEntries => List.unmodifiable(_entries);

  JournalEntry? byId(String id) {
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  // ── Edits that need no microphone, no GPS and no model ──────────────────
  // They live here rather than in JournalManager so the desktop hub can make
  // them too; JournalManager only adds its notifier refresh on top.

  /// Moves an entry to a different day (e.g. backdating). Re-sorts.
  Future<void> setDay(JournalEntry entry, DateTime day) async {
    entry.day = DateTime(day.year, day.month, day.day);
    await upsert(entry);
  }

  /// Sets or clears the location label (also works on old entries).
  Future<void> setPlace(JournalEntry entry, String? place) async {
    final trimmed = place?.trim();
    entry.place = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    await upsert(entry);
  }

  /// Corrects the transcript — the permanent record — or the summary derived
  /// from it. Null leaves that field alone.
  Future<void> setText(
    JournalEntry entry, {
    String? transcript,
    String? summary,
  }) async {
    if (transcript != null) entry.transcript = transcript;
    if (summary != null) entry.summary = summary;
    await upsert(entry);
  }

  Future<void> setTags(JournalEntry entry, List<String> tags) async {
    entry.tags = tags.map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    await upsert(entry);
  }

  /// Writes the outcome of a sync round: [upserts] replace or add entries by
  /// id exactly as given — their [JournalEntry.changedAt] is the remote
  /// device's, not now — and [removed] maps ids purged elsewhere to when that
  /// happened.
  ///
  /// Anything changed locally *after* the incoming stamp is left alone: the
  /// engine resolved conflicts against a snapshot from the start of its round,
  /// and the user may have typed something while the round was in flight.
  ///
  /// Audio is never carried by sync. An entry arriving from the phone lists
  /// [JournalEntry.audioFileNames] that simply do not exist here; playback
  /// checks the file, so the list stays as metadata and remains correct if
  /// the entry ever travels back.
  Future<void> applySynced(
    List<JournalEntry> upserts,
    Map<String, DateTime> removed,
  ) async {
    var changed = false;

    for (final incoming in upserts) {
      final i = _entries.indexWhere((e) => e.id == incoming.id);
      if (i >= 0) {
        final local = _entries[i];
        if (local.changedAt.isAfter(incoming.changedAt)) continue;
        // Our own push coming back: same stamp, same content. Rewriting it
        // would only churn the file and repaint the UI.
        if (local.changedAt.isAtSameMomentAs(incoming.changedAt) &&
            jsonEncode(local.toJson()) == jsonEncode(incoming.toJson())) {
          continue;
        }
        // Keep the audio this device actually holds: the remote copy has no
        // files, and its list would otherwise orphan them into deletion.
        if (local.audioFileNames.isNotEmpty && !incoming.audioDeleted) {
          incoming.audioFileNames = local.audioFileNames;
        }
        _entries[i] = incoming;
      } else {
        _entries.add(incoming);
      }
      changed = true;
    }

    final purged = <JournalEntry>[];
    for (final entry in removed.entries) {
      final i = _entries.indexWhere((e) => e.id == entry.key);
      if (i < 0) continue;
      if (_entries[i].changedAt.isAfter(entry.value)) continue;
      purged.add(_entries[i]);
      _entries.removeAt(i);
      changed = true;
    }

    if (!changed) return;
    _sort();
    await _persist();
    for (final e in purged) {
      await _deleteAudio(e);
    }
  }

  File get indexFile => File(_indexPath);
}
