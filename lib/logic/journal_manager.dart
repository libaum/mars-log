import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/domain/analysis_basis.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/logic/analysis_task_service.dart';
import 'package:mars_log/logic/location_service.dart';
import 'package:mars_log/logic/recording_manager.dart';
import 'package:mars_log/services/service_locator.dart';

/// Core state manager for the journal. Coordinates recording → entry creation →
/// analysis, and exposes the live entry list to the UI. Analysis goes through
/// the [AnalysisEngine] — on-device Whisper + Gemma, nothing leaves the
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

  /// Failed entries already retried once in this app session — a model
  /// download cut off, the process killed mid-analysis: one automatic retry
  /// fixes that; a loop of them would not help.
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
        final partial =
            await engine.transcribe([File(_repo.audioPath(rec.fileName))]);
        final live = _repo.byId(id);
        if (live == null) {
          orphaned = true;
          return;
        }
        // Appended to the transcript as stored *now*: a correction made on
        // the laptop while this snippet was transcribed stays.
        live.deletedAt = null; // same rule if it was trashed meanwhile
        live.transcript = [live.transcript, partial]
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

        final text = live.transcript!;
        final result = await engine.analyzeText(text);
        await _applyResult(id, result, engine.modelName, analyzedText: text);
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

  /// [retranscribe]: run Whisper over the audio again. False when the entry
  /// already has a transcript from an earlier pass whose analysis failed —
  /// then only the analysis is repeated.
  Future<void> _analyze(
    String id,
    AnalysisEngine engine, {
    bool retranscribe = true,
  }) async {
    final start = _repo.byId(id);
    if (start == null) return;
    // What the entry held when the analysis started: whether Whisper's
    // transcript may replace the stored one (not if corrected meanwhile).
    final before = _snapshot(start);
    _inFlight.add(id);
    try {
      await _task.run(() async {
        var text = before.transcript ?? '';
        // Once the audio is gone, the transcript is the only source to work
        // from.
        if (!before.audioDeleted && retranscribe) {
          final transcript = await engine.transcribe(
            before.audioFileNames.map((f) => File(_repo.audioPath(f))).toList(),
          );
          // Kept right away: Whisper took its time, and if the analysis
          // after it fails (model not downloaded yet, process killed), the
          // transcript must not be lost with it. A transcript corrected by
          // hand meanwhile wins, and is what gets analysed.
          final live = _repo.byId(id);
          if (live == null) return;
          if (_same(live.transcript, before.transcript)) {
            live.transcript = transcript;
            await _repo.upsert(live);
            _refresh();
          }
          text = _repo.byId(id)?.transcript ?? transcript;
        }
        final result = await engine.analyzeText(text);
        await _applyResult(id, result, engine.modelName, analyzedText: text);
      });
    } catch (e) {
      await _markFailed(id, e);
    } finally {
      _inFlight.remove(id);
    }
    _refresh();
  }

  /// Writes an analysis result onto the entry *as stored now*, as the
  /// analysis of [analyzedText] by whichever engine answered (on-device
  /// pre-analysis or Gemini — see [AnalysisResult.source]).
  ///
  /// - A summary / tags edited by hand meanwhile (here or on the laptop) are
  ///   newer intent than an automatic result and stay ([JournalEntry.summaryByHand]).
  /// - If the laptop's analysis of exactly this transcript arrived meanwhile,
  ///   it is the better one and stays; only the entry's status moves on.
  Future<void> _applyResult(
    String id,
    AnalysisResult result,
    String model, {
    required String analyzedText,
  }) async {
    final live = _repo.byId(id);
    if (live == null) return; // purged meanwhile: nothing left to annotate
    final basis = transcriptBasis(analyzedText);
    final laptopHasIt =
        live.analysisSource == AnalysisSource.laptop && live.analysisBasis == basis;
    if (!laptopHasIt) {
      if (!live.titleByHand && result.title.isNotEmpty) live.title = result.title;
      if (!live.summaryByHand) live.summary = result.summary;
      if (!live.tagsByHand) live.tags = result.tags;
      live
        ..moodLabel = result.moodLabel
        ..moodScore = result.moodScore
        ..dimensions = result.dimensions
        ..analysisModel = result.model ?? model
        ..analysisVersion = kAnalysisVersion
        ..analysisSource = result.source ?? AnalysisSource.phone
        ..analysisBasis = basis;
    }
    live
      ..errorMessage = null
      ..status = EntryStatus.ready;
    final discard = _takeAudioIfDiscarding(live);
    // Status is the entry item's, the result the analysis item's: both clocks.
    if (laptopHasIt) {
      await _repo.upsert(live);
    } else {
      await _repo.saveAnalysis(live, entryChanged: true);
    }
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
  /// is still sitting in `entries.json` as `analyzing` — or as `failed`.
  /// Called on app start and whenever the app comes back to the foreground;
  /// picks those up and runs them again.
  Future<void> resumePending() async {
    for (final entry in _repo.entries) {
      if (_inFlight.contains(entry.id)) continue;
      if (entry.status == EntryStatus.analyzing) {
        await _analyze(entry.id, _engine);
      } else if (entry.status == EntryStatus.failed && _retried.add(entry.id)) {
        // On-device: a retry costs nothing but a few seconds. A transcript
        // that survived the failure is reused — only the analysis failed.
        final hasTranscript = (entry.transcript ?? '').trim().isNotEmpty;
        await _analyze(entry.id, _engine, retranscribe: !hasTranscript);
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
