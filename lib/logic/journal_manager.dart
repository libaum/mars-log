import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/logic/analysis_task_service.dart';
import 'package:mars_log/logic/location_service.dart';
import 'package:mars_log/logic/recording_manager.dart';
import 'package:mars_log/services/service_locator.dart';

/// Core state manager for the journal. Coordinates recording → entry creation →
/// analysis, and exposes the live entry list to the UI. Analysis goes through
/// the [AnalysisEngine] — on-device Whisper + Gemini Nano, nothing leaves the
/// phone.
class JournalManager {
  final _repo = getIt<JournalRepository>();
  final _storage = getIt<LocalStorageService>();
  final _location = getIt<LocationService>();
  final _engine = getIt<AnalysisEngine>();
  final _task = getIt<AnalysisTaskService>();

  /// Ids of entries whose analysis is running right now, so [resumePending]
  /// doesn't start a second pass over one that is simply still working.
  final _inFlight = <String>{};

  /// Failed entries already retried once in this app session. Gemini Nano
  /// refuses to run while the app is in the background, so an entry recorded
  /// just before switching away fails — one automatic retry back in the
  /// foreground fixes that; a loop of them would not help.
  final _retried = <String>{};

  late final ValueNotifier<List<JournalEntry>> entriesNotifier;
  late final ValueNotifier<List<JournalEntry>> trashNotifier;

  JournalManager() {
    entriesNotifier = ValueNotifier(_repo.entries);
    trashNotifier = ValueNotifier(_repo.deletedEntries);
    // A sync round writes straight to the repository, so the screens would
    // otherwise keep showing the pre-sync list until the next local edit.
    _repo.revision.addListener(_refresh);
  }

  void _refresh() {
    entriesNotifier.value = _repo.entries;
    trashNotifier.value = _repo.deletedEntries;
  }

  // ── Analysis ──────────────────────────────────────────────────────────────
  //
  // Every path here waits seconds on the network (the model) or the GPS, and
  // a sync round may run meanwhile and replace the entry with a version
  // edited on the laptop — one edited *after* the analysis started; an older
  // one loses to the "analyzing" stamp by last-write-wins. So no path holds a
  // JournalEntry across an await: it keeps the id, re-reads the entry afterwards, and writes only what it
  // owns — see [_applyResult]. Writing the held object back would undo the
  // laptop's edit with a fresh stamp, and that stale version would then win
  // on every device.

  /// Creates a provisional (analyzing) entry immediately, then analyses it.
  Future<void> createFromAudio(RecordingResult rec) async {
    final entry = JournalEntry(
      id: rec.id,
      createdAt: rec.createdAt,
      day: DateTime(rec.createdAt.year, rec.createdAt.month, rec.createdAt.day),
      audioFileNames: [rec.fileName],
      status: EntryStatus.analyzing,
    );
    await _repo.upsert(entry);
    _refresh();
    await _attachLocation(entry.id);
    await _analyze(entry.id, _engine);
  }

  /// Best-effort: stamp the entry with where it was recorded. Silent on failure.
  Future<void> _attachLocation(String id) async {
    final placeBefore = _repo.byId(id)?.place;
    final loc = await _location.current();
    if (loc == null) return;
    final live = _repo.byId(id);
    // Gone, or given a place by hand while the GPS was searching — the
    // manual one is the newer intent.
    if (live == null || live.place != placeBefore) return;
    live
      ..latitude = loc.latitude
      ..longitude = loc.longitude
      ..place = loc.place;
    await _repo.upsert(live);
    _refresh();
  }

  /// Adds another recording to an existing entry instead of creating a
  /// separate one for the same day. Only the new snippet goes through Whisper
  /// for transcription — the existing transcript is already known and isn't
  /// re-transcribed — then summary/mood/tags are recomputed from the merged
  /// text. The recording is kept as its own audio file alongside the
  /// entry's other ones (unless the entry's audio was already discarded, in
  /// which case the new snippet's audio is dropped too, once transcribed).
  Future<void> appendRecording(JournalEntry entry, RecordingResult rec) async {
    final id = entry.id;
    final start = _repo.byId(id);
    // Purged (here or elsewhere) while recording: the recording must not be
    // lost, so it becomes an entry of its own.
    if (start == null) return createFromAudio(rec);
    // Trashed elsewhere while recording: a new recording is newer intent than
    // the trashing, so the entry comes back (as typing does in the hub).
    start
      ..deletedAt = null
      ..status = EntryStatus.analyzing
      ..errorMessage = null;
    await _repo.upsert(start);
    _refresh();

    final engine = _engine;
    var orphaned = false;
    _inFlight.add(id);
    try {
      await _task.run(() async {
        final partial = await engine
            .analyzeAudio([File(_repo.audioPath(rec.fileName))]);
        final live = _repo.byId(id);
        if (live == null) {
          orphaned = true;
          return;
        }
        // Appended to the transcript as stored *now*: a correction made on
        // the laptop while this snippet was transcribed stays.
        live.deletedAt = null; // same rule if it was trashed meanwhile
        live.transcript = [live.transcript, partial.transcript]
            .where((t) => t != null && t.isNotEmpty)
            .join('\n\n');
        final dropSnippet = live.audioDeleted;
        if (!dropSnippet) {
          live.audioFileNames = [...live.audioFileNames, rec.fileName];
        }
        // Written before the file is touched: no await between re-reading
        // [live] and writing it.
        await _repo.upsert(live);
        if (dropSnippet) await _repo.deleteAudioFile(rec.fileName);

        final before = _snapshot(live);
        final result = await engine.analyzeText(before.transcript!);
        await _applyResult(id, before, result, engine.modelName,
            withTranscript: false);
      });
    } catch (e) {
      await _markFailed(id, e);
    } finally {
      _inFlight.remove(id);
    }
    _refresh();
    if (orphaned) await createFromAudio(rec);
  }

  /// Re-runs analysis on an existing entry; audio + previous data are kept
  /// until the new result overwrites them.
  Future<void> reanalyze(JournalEntry entry) async {
    final live = _repo.byId(entry.id);
    if (live == null) return;
    live
      ..status = EntryStatus.analyzing
      ..errorMessage = null;
    await _repo.upsert(live);
    _refresh();
    await _analyze(live.id, _engine);
  }

  Future<void> _analyze(String id, AnalysisEngine engine) async {
    final start = _repo.byId(id);
    if (start == null) return;
    final before = _snapshot(start);
    _inFlight.add(id);
    try {
      await _task.run(() async {
        // Once the audio is gone, the transcript is the only source to work
        // from.
        final result = before.audioDeleted
            ? await engine.analyzeText(before.transcript ?? '')
            : await engine.analyzeAudio(
                before.audioFileNames
                    .map((f) => File(_repo.audioPath(f)))
                    .toList(),
              );
        await _applyResult(id, before, result, engine.modelName,
            withTranscript: true);
      });
    } catch (e) {
      await _markFailed(id, e);
    } finally {
      _inFlight.remove(id);
    }
    _refresh();
  }

  /// Writes an analysis result onto the entry *as stored now*. Field by
  /// field, a value is only written if the field still holds what it held in
  /// [before] — when the analysis started. A correction made by hand in the
  /// meantime (here or on the laptop) is newer intent than an automatic
  /// result and stays. Status and model metadata are the analysis' own and
  /// always written.
  Future<void> _applyResult(
    String id,
    JournalEntry before,
    AnalysisResult result,
    String model, {
    required bool withTranscript,
  }) async {
    final live = _repo.byId(id);
    if (live == null) return; // purged meanwhile: nothing left to annotate
    void put<T>(T Function(JournalEntry e) field, void Function(T v) write, T value) {
      if (_same(field(live), field(before))) write(value);
    }

    if (withTranscript) {
      put<String?>((e) => e.transcript, (v) => live.transcript = v, result.transcript);
    }
    put<String?>((e) => e.summary, (v) => live.summary = v, result.summary);
    put<String?>((e) => e.moodLabel, (v) => live.moodLabel = v, result.moodLabel);
    put<double?>((e) => e.moodScore, (v) => live.moodScore = v, result.moodScore);
    put<Map<String, int>?>((e) => e.dimensions, (v) => live.dimensions = v, result.dimensions);
    put<List<String>>((e) => e.tags, (v) => live.tags = v, result.tags);
    live
      ..analysisModel = model
      ..analysisVersion = kAnalysisVersion
      ..errorMessage = null
      ..status = EntryStatus.ready;
    final discard = _takeAudioIfDiscarding(live);
    await _repo.upsert(live);
    // Files go after the write: no await between re-reading [live] and
    // writing it. A crash in between leaves orphans the startup sweep removes.
    for (final f in discard) {
      await _repo.deleteAudioFile(f);
    }
  }

  Future<void> _markFailed(String id, Object error) async {
    final live = _repo.byId(id);
    if (live == null) return;
    live
      ..status = EntryStatus.failed
      ..errorMessage = error.toString();
    await _repo.upsert(live);
  }

  /// A detached copy to compare against after an await.
  static JournalEntry _snapshot(JournalEntry e) =>
      JournalEntry.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);

  static bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

  /// Second line of defence behind the foreground service: if the process was
  /// killed (or frozen hard enough to kill the request) mid-analysis, the entry
  /// is still sitting in `entries.json` as `analyzing` — or as `failed`
  /// because Nano refused to run in the background. Called on app start and whenever the app comes back to
  /// the foreground; picks those up and runs them again.
  Future<void> resumePending() async {
    for (final entry in _repo.entries) {
      if (_inFlight.contains(entry.id)) continue;
      if (entry.status == EntryStatus.analyzing) {
        await _analyze(entry.id, _engine);
      } else if (entry.status == EntryStatus.failed && _retried.add(entry.id)) {
        // On-device: a retry costs nothing but a few seconds.
        await _analyze(entry.id, _engine);
      }
    }
  }

  /// If the "delete audio after transcription" setting is on, marks the
  /// audio discarded now that a transcript exists and returns the files the
  /// caller deletes once the entry is written. Synchronous on purpose.
  List<String> _takeAudioIfDiscarding(JournalEntry entry) {
    if (entry.audioDeleted) return const [];
    if (!_storage.getDeleteAudioAfterTranscription()) return const [];
    final files = entry.audioFileNames;
    entry
      ..audioDeleted = true
      ..audioFileNames = [];
    return files;
  }

  /// Soft-delete: moves an entry to the trash (recoverable). Marks it deleted
  /// synchronously and refreshes now, so a Dismissible sees the item gone in
  /// the same frame it dismisses it.
  Future<void> delete(JournalEntry entry) async {
    final done = _repo.moveToTrash(entry);
    _refresh();
    await done;
  }

  /// Brings a trashed entry back into the active timeline.
  Future<void> restore(JournalEntry entry) async {
    await _repo.restore(entry);
    _refresh();
  }

  /// Permanently removes a single trashed entry (and its audio). Irreversible.
  Future<void> purge(JournalEntry entry) async {
    await _repo.purge(entry);
    _refresh();
  }

  /// Permanently empties the trash. Irreversible.
  Future<void> emptyTrash({Set<String>? only}) async {
    await _repo.emptyTrash(only: only);
    _refresh();
  }

  /// Moves an entry to a different day (e.g. backdating). Re-sorts the timeline.
  Future<void> setDay(JournalEntry entry, DateTime day) async {
    await _repo.setDay(entry, day);
    _refresh();
  }

  /// Sets or clears the entry's location label (also works on old entries).
  Future<void> setPlace(JournalEntry entry, String? place) async {
    await _repo.setPlace(entry, place);
    _refresh();
  }
}
