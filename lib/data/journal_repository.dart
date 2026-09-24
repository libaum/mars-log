import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mars_log/domain/journal_entry.dart';

/// Where purges leave a trace, so the sync layer can still tell other devices
/// about entries that no longer exist here. Null on a device without sync —
/// then a purge is simply local.
abstract class PurgeTrace {
  /// [stamps]: id → the time the tombstone competes with in last-write-wins.
  /// Not necessarily now — see [JournalRepository._purgeExpired].
  void recordPurged(Map<String, DateTime> stamps);
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

  /// [stamp] picks each tombstone's last-write-wins time.
  void _tracePurge(
    Iterable<JournalEntry> gone,
    DateTime Function(JournalEntry e) stamp,
  ) {
    final trace = _purgeTrace;
    if (trace == null || gone.isEmpty) return;
    trace.recordPurged({for (final e in gone) e.id: stamp(e)});
  }

  /// The stored object for [entry]'s id. Callers hold entries across awaits
  /// — a dialog, a model call, a GPS fix — while a sync round may replace
  /// the stored object with a version edited elsewhere. Mutating and writing
  /// the held one would put stale fields back with a fresh stamp, and that
  /// stale version would then win everywhere. So every edit below works on
  /// the stored object, whatever the caller passes in.
  ///
  /// Null if the entry was purged meanwhile (here, or by a tombstone from
  /// another device). The edit is then dropped: writing the held object
  /// would bring the entry back with a fresh stamp, beating the purge.
  JournalEntry? _live(JournalEntry entry) => byId(entry.id);

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

  /// Stores [entry] as the new truth for its id. It must be the stored
  /// object itself (or a new id): passing a copy held from before a sync
  /// round would silently undo that round — the edit methods below resolve
  /// the stored object for exactly that reason.
  Future<void> upsert(JournalEntry entry) async {
    final i = _entries.indexWhere((e) => e.id == entry.id);
    assert(
      i < 0 || identical(_entries[i], entry),
      'upsert() with a stale JournalEntry ${entry.id}: re-read it with '
      'byId() after any await, or use edit()/setDay()',
    );
    _stamp(entry);
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
    final live = _live(entry);
    if (live == null) return Future.value();
    live.deletedAt = DateTime.now();
    _stamp(live);
    return _persist();
  }

  /// Bring a trashed entry back into the active timeline.
  Future<void> restore(JournalEntry entry) async {
    final live = _live(entry);
    if (live == null) return;
    live.deletedAt = null;
    _stamp(live);
    _sort();
    await _persist();
  }

  /// Permanently remove one entry (and its audio). Irreversible.
  Future<void> purge(JournalEntry entry) async {
    final live = _live(entry);
    if (live == null) return; // already gone, audio included
    // A user action: it is the newest intent, so it competes as "now".
    _tracePurge([live], (_) => DateTime.now());
    _entries.removeWhere((e) => e.id == live.id);
    await _persist();
    await _deleteAudio(live);
  }

  /// Permanently remove every trashed entry (and its audio). Irreversible.
  Future<void> emptyTrash() async {
    final trashed = _entries.where((e) => e.deletedAt != null).toList();
    final now = DateTime.now();
    _tracePurge(trashed, (_) => now);
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
    // Nobody pressed anything, so this tombstone must not compete as "now":
    // a restore made on another device on day 29 — which this device hasn't
    // pulled yet, because loading runs before the first sync — would lose to
    // it. It competes as one millisecond after the entry's last known
    // change: newer than the trashed version (so it propagates), older than
    // any later restore or edit elsewhere (so those win). Every device
    // computes the same stamp, so the duplicate tombstones agree.
    _tracePurge(gone, (e) => e.changedAt.add(const Duration(milliseconds: 1)));
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
  Future<void> discardAudio(JournalEntry entry) async {
    final live = _live(entry);
    if (live != null) await _deleteAudio(live);
  }

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
    final live = _live(entry);
    if (live == null) return;
    live.day = DateTime(day.year, day.month, day.day);
    await upsert(live);
  }

  /// Sets or clears the location label (also works on old entries).
  Future<void> setPlace(JournalEntry entry, String? place) =>
      edit(entry, place: place ?? '');

  /// Corrects the transcript — the permanent record — or the summary derived
  /// from it. Null leaves that field alone.
  Future<void> setText(
    JournalEntry entry, {
    String? transcript,
    String? summary,
  }) =>
      edit(entry, transcript: transcript, summary: summary);

  Future<void> setTags(JournalEntry entry, List<String> tags) =>
      edit(entry, tags: tags);

  /// Several field edits as **one** write: one stamp, one revision. An editor
  /// saving three fields through three calls would see the revision of the
  /// first write while the others are still pending, and read that half-done
  /// state back into its fields.
  ///
  /// Null leaves a field alone. [place] is trimmed and empty clears it;
  /// [tags] are trimmed and empty ones dropped.
  Future<void> edit(
    JournalEntry entry, {
    String? transcript,
    String? summary,
    String? place,
    List<String>? tags,
  }) async {
    final live = _live(entry);
    if (live == null) return;
    if (transcript != null) live.transcript = transcript;
    if (summary != null) live.summary = summary;
    if (place != null) {
      final trimmed = place.trim();
      live.place = trimmed.isEmpty ? null : trimmed;
    }
    if (tags != null) {
      live.tags = tags.map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    }
    await upsert(live);
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
  /// Audio is never carried by sync, only its metadata — see [_mergeAudio].
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
        _mergeAudio(local, incoming);
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

  /// Audio state belongs to the device that holds the files; sync carries it
  /// as metadata only, so an incoming version can be behind in either
  /// direction:
  ///
  /// - This device holds files the remote copy doesn't list (a recording
  ///   added here meanwhile): keep the local list, or the orphan sweep on the
  ///   next start deletes the new recording.
  /// - This device discarded its audio, the remote copy still lists it: stay
  ///   discarded (it only ever goes one way), or the entry points at files
  ///   that no longer exist.
  ///
  /// A device holding none of the files — the laptop — takes the remote list
  /// as it is; that's how it learns about a second recording.
  ///
  /// Synchronous file checks on purpose: [applySynced] must not yield between
  /// finding an entry's slot and replacing it.
  void _mergeAudio(JournalEntry local, JournalEntry incoming) {
    if (local.audioDeleted) incoming.audioDeleted = true;
    if (incoming.audioDeleted) {
      incoming.audioFileNames = [];
      return;
    }
    final holdsFiles =
        local.audioFileNames.any((f) => File(audioPath(f)).existsSync());
    if (holdsFiles) incoming.audioFileNames = local.audioFileNames;
  }

  File get indexFile => File(_indexPath);
}
