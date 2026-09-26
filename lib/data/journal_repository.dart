import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mars_log/domain/analysis_basis.dart';
import 'package:mars_log/domain/journal_entry.dart';

/// Where purges leave a trace, so the sync layer can still tell other devices
/// about entries that no longer exist here. Null on a device without sync —
/// then a purge is simply local.
abstract class PurgeTrace {
  /// [stamps]: id → the time the tombstone competes with in last-write-wins.
  /// Not necessarily now — see [JournalRepository._purgeExpired].
  void recordPurged(Map<String, DateTime> stamps);

  /// True while the device is paired. The 30-day purge then waits for
  /// [JournalRepository.purgeExpired] after a completed sync round instead of
  /// running at load: a restore made on another device must arrive before
  /// this device deletes the entry's audio, which no backup holds.
  bool get defersAutoPurge;
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

  JournalRepository._(this._purgeTrace, this._readOnly, this._autoPurge);

  /// Whether this device runs the 30-day purge at all. Only the device that
  /// holds the recordings does (the phone); the desktop hub waits for its
  /// tombstones. That keeps the hub's trash as the place to undo a lost
  /// entry after a hub restore — see ARCHITECTURE.md §7, recovery step 6.
  final bool _autoPurge;

  /// A snapshot for reading only (the background export), never written.
  final bool _readOnly;

  /// [directory] defaults to the app documents dir — private on Android, but
  /// `~/Documents` on Linux, so the desktop hub passes its own.
  ///
  /// [readOnly]: for a second instance next to the app's own — the daily
  /// export in its background isolate. Loading then changes nothing on disk:
  /// no 30-day purge (it would have no purge trace and could race the app's
  /// own writes) and no orphan sweep (it would delete a recording the app is
  /// writing right now, which no entry points to yet).
  static Future<JournalRepository> getInstance({
    PurgeTrace? purgeTrace,
    Directory? directory,
    bool readOnly = false,
    bool autoPurge = true,
  }) async {
    final repo = JournalRepository._(purgeTrace, readOnly, autoPurge);
    await repo._load(directory);
    return repo;
  }

  Future<void> _load(Directory? directory) async {
    _docsDir = directory ?? await getApplicationDocumentsDirectory();
    await _docsDir.create(recursive: true);
    await Directory(audioDirPath).create(recursive: true);

    if (_readOnly) {
      await _readIndex();
      return;
    }
    final file = File(_indexPath);
    if (await file.exists() && !await _readIndex()) {
      // Corrupt index (or one this build can't read) → start empty rather
      // than crash, but set the file aside first: the next write would
      // overwrite the only copy of every transcript.
      try {
        await file.rename(
            '$_indexPath$_corruptSuffix${DateTime.now().millisecondsSinceEpoch}');
      } on FileSystemException {
        return; // couldn't set it aside — at least spare the audio this run
      }
    }
    corruptIndex.value = (await corruptIndexFiles()).isNotEmpty;
    if (!(_purgeTrace?.defersAutoPurge ?? false)) await purgeExpired();
    // With an index set aside, every recording of its entries looks
    // orphaned — and no backup holds audio. Keep them until the user
    // discards the old index ([discardCorruptIndexes]).
    if (!corruptIndex.value) await _purgeOrphanedAudio();
  }

  static const _corruptSuffix = '.corrupt-';

  /// True while an unreadable index is set aside next to the journal. The
  /// orphan sweep pauses meanwhile; settings shows it.
  final corruptIndex = ValueNotifier<bool>(false);

  /// Indexes set aside because they couldn't be read. The export zips them
  /// along, so the daily backups keep them after the local copy is gone.
  Future<List<File>> corruptIndexFiles() async => [
        await for (final f in _docsDir.list())
          if (f is File &&
              f.uri.pathSegments.last.startsWith('$_indexFileName$_corruptSuffix'))
            f,
      ];

  /// Deletes the set-aside indexes. The next start sweeps orphaned audio
  /// again, which includes every recording of their entries.
  Future<void> discardCorruptIndexes() async {
    for (final f in await corruptIndexFiles()) {
      await f.delete();
    }
    corruptIndex.value = false;
  }

  /// False if the index exists but can't be read.
  Future<bool> _readIndex() async {
    final file = File(_indexPath);
    if (!await file.exists()) return true;
    try {
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      _entries
        ..clear()
        ..addAll(list.map((e) =>
            JournalEntry.fromJson((e as Map).cast<String, dynamic>())));
      _sort();
      return true;
    } catch (_) {
      _entries.clear();
      return false;
    }
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

  /// Writes run one after another, each taking the list as it is *when it
  /// runs* — so the last write always holds the newest state, even when a
  /// sync apply and an analysis persist at the same time. Each goes to a
  /// temp file first and is renamed over the index: a crash mid-write leaves
  /// the previous index, never half of one.
  Future<void> _writes = Future.value();

  Future<void> _persist() {
    assert(!_readOnly, 'a read-only JournalRepository must not write');
    final done = _writes.then((_) async {
      final json = jsonEncode(_entries.map((e) => e.toJson()).toList());
      final tmp = File('$_indexPath.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(_indexPath);
    });
    _writes = done.catchError((_) {});
    return done.then((_) => revision.value++);
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
  ///
  /// [only]: the ids the user was shown when confirming. A sync round may
  /// trash more entries while the dialog is open; those were never seen and
  /// stay. Ids restored meanwhile stay too — they are no longer trashed.
  Future<void> emptyTrash({Set<String>? only}) async {
    bool doomed(JournalEntry e) =>
        e.deletedAt != null && (only == null || only.contains(e.id));
    final trashed = _entries.where(doomed).toList();
    if (trashed.isEmpty) return;
    final now = DateTime.now();
    _tracePurge(trashed, (_) => now);
    _entries.removeWhere(doomed);
    await _persist();
    for (final e in trashed) {
      await _deleteAudio(e);
    }
  }

  /// Purges trashed entries older than [trashRetention]. At load on an unpaired device; on a paired one
  /// after each completed sync round (see [PurgeTrace.defersAutoPurge]).
  Future<void> purgeExpired() async {
    if (_autoPurge) await _purgeExpired();
  }

  Future<void> _purgeExpired() async {
    final cutoff = DateTime.now().subtract(trashRetention);
    bool expired(JournalEntry e) =>
        e.deletedAt != null && e.deletedAt!.isBefore(cutoff);
    final gone = _entries.where(expired).toList();
    if (gone.isEmpty) return;
    // Nobody pressed anything, so this tombstone must not compete as "now":
    // a restore made on another device on day 29 that this device hasn't
    // pulled yet would lose to it (a paired device runs this only after a
    // pull, but a restore may still land on the hub a second later). It
    // competes as one millisecond after the entry's last known change: newer than the trashed version (so it propagates), older than
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
    if (summary != null) {
      live.summary = summary;
      // The human's now: travels with the entry, no analysis overwrites it.
      live.summaryByHand = true;
    }
    if (place != null) {
      final trimmed = place.trim();
      live.place = trimmed.isEmpty ? null : trimmed;
    }
    if (tags != null) {
      live.tags = tags.map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
      live.tagsByHand = true;
    }
    await upsert(live);
  }

  /// Writes [result] as the analysis of the transcript with [basis] — the
  /// laptop's way in (the phone goes through JournalManager). Only onto the
  /// entry as stored now, and only if its transcript is still the one that
  /// was analysed; returns false otherwise (gone, or corrected meanwhile —
  /// the caller analyses again). Summary / tags edited by hand stay.
  Future<bool> writeAnalysis(
    String id,
    AnalysisResult result, {
    required String model,
    required int version,
    required String source,
    required String basis,
  }) async {
    final live = byId(id);
    if (live == null || transcriptBasis(live.transcript) != basis) return false;
    if (!live.summaryByHand) live.summary = result.summary;
    if (!live.tagsByHand) live.tags = result.tags;
    live
      ..moodLabel = result.moodLabel
      ..moodScore = result.moodScore
      ..dimensions = result.dimensions
      ..analysisModel = model
      ..analysisVersion = version
      ..analysisSource = source
      ..analysisBasis = basis;
    // Failed where it was recorded, analysed here: fine here. Local only —
    // status is the entry item's.
    if (live.status == EntryStatus.failed) {
      live
        ..status = EntryStatus.ready
        ..errorMessage = null;
    }
    await saveAnalysis(live, entryChanged: false);
    return true;
  }

  /// Stores an analysis the caller wrote onto [entry] — the stored object,
  /// re-read after any await, as for [upsert]. Stamps the analysis item's
  /// clock ([JournalEntry.analysisChangedAt]); the entry item's only if
  /// [entryChanged] (the phone also flips `status`, which is the entry's).
  Future<void> saveAnalysis(JournalEntry entry, {required bool entryChanged}) async {
    final i = _entries.indexWhere((e) => e.id == entry.id);
    assert(
      i >= 0 && identical(_entries[i], entry),
      'saveAnalysis() needs the stored JournalEntry ${entry.id}',
    );
    if (i < 0) return;
    entry.analysisChangedAt = DateTime.now();
    if (entryChanged) _stamp(entry);
    await _persist();
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
    Map<String, DateTime> removed, {
    List<SyncedAnalysis> analyses = const [],
  }) async {
    var changed = false;

    for (final incoming in upserts) {
      final i = _entries.indexWhere((e) => e.id == incoming.id);
      if (i >= 0) {
        final local = _entries[i];
        if (local.changedAt.isAfter(incoming.changedAt)) continue;
        // Our own push coming back: same stamp, same content. Rewriting it
        // would only churn the file and repaint the UI.
        if (local.changedAt.isAtSameMomentAs(incoming.changedAt) &&
            jsonEncode(local.toEntryItemJson()) ==
                jsonEncode(incoming.toEntryItemJson())) {
          continue;
        }
        _mergeAudio(local, incoming);
        _keepAnalysis(local, incoming);
        _entries[i] = incoming;
      } else {
        _entries.add(incoming);
      }
      changed = true;
    }

    // After the entries: an analysis item may arrive in the same round as
    // the entry it belongs to.
    for (final a in analyses) {
      final e = byId(a.entryId);
      if (e == null) continue; // purged here — nothing to annotate
      final local = e.analysisChangedAt;
      if (local != null && local.isAfter(a.changedAt)) continue;
      if (local != null &&
          local.isAtSameMomentAs(a.changedAt) &&
          jsonEncode(e.toAnalysisItemJson()) == jsonEncode(a.json)) {
        continue;
      }
      e
        ..takeAnalysisFrom(a.json)
        ..analysisChangedAt = a.changedAt;
      // An entry whose own analysis failed has one now. Local only: status is
      // the entry item's, and the device that failed pushes its own state.
      if (e.status == EntryStatus.failed) {
        e
          ..status = EntryStatus.ready
          ..errorMessage = null;
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

  /// An incoming entry item carries no analysis ([JournalEntry.toEntryItemJson])
  /// — that is its own item with its own clock. Keep the analysis this device
  /// holds; a summary / tags edited by hand come with the entry and win.
  ///
  /// An item from before the split does carry an analysis; it is kept here
  /// too, and [applySynced] then applies the one [JournalSyncRepository]
  /// split off it by the analysis clock like any other.
  void _keepAnalysis(JournalEntry local, JournalEntry incoming) {
    final summary = incoming.summary;
    final tags = incoming.tags;
    incoming
      ..summary = local.summary
      ..moodLabel = local.moodLabel
      ..moodScore = local.moodScore
      ..dimensions = local.dimensions
      ..tags = local.tags
      ..analysisModel = local.analysisModel
      ..analysisVersion = local.analysisVersion
      ..analysisChangedAt = local.analysisChangedAt
      ..analysisSource = local.analysisSource
      ..analysisBasis = local.analysisBasis;
    if (incoming.summaryByHand) incoming.summary = summary;
    if (incoming.tagsByHand) incoming.tags = tags;
    // The sending device's analysis failed, but this one holds an analysis of
    // exactly this transcript (e.g. the laptop's) — the entry is fine here.
    if (incoming.status == EntryStatus.failed &&
        incoming.analysisBasis != null &&
        incoming.analysisBasis == transcriptBasis(incoming.transcript)) {
      incoming
        ..status = EntryStatus.ready
        ..errorMessage = null;
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

/// An analysis item as it arrived from the hub — see [JournalEntry.toAnalysisItemJson].
class SyncedAnalysis {
  final String entryId;
  final DateTime changedAt;
  final Map<String, dynamic> json;
  const SyncedAnalysis(this.entryId, this.changedAt, this.json);
}
