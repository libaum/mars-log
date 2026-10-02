import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/domain/analysis_basis.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/people_aliases.dart';
import 'package:mars_log/logic/analysis_task_service.dart';
import 'package:mars_log/logic/location_service.dart';
import 'package:mars_log/logic/recording_manager.dart';
import 'package:mars_log/services/service_locator.dart';

/// Core state manager for the journal. Coordinates recording → entry creation →
/// transcription → analysis → people, and exposes the live entry list to the
/// UI. The work goes through the [AnalysisEngine] — Gemini: the recording and
/// the transcript go to Google's API (paid tier).
class JournalManager {
  final _repo = getIt<JournalRepository>();
  final _storage = getIt<LocalStorageService>();
  final _location = getIt<LocationService>();
  final _engine = getIt<AnalysisEngine>();
  final _task = getIt<AnalysisTaskService>();

  /// Ids of entries whose analysis is running right now, so [resumePending]
  /// doesn't start a second pass over one that is simply still working.
  final _inFlight = <String>{};

  /// Failed entries already retried once in this app session — the
  /// process killed mid-analysis, an error that might not repeat: one
  /// automatic retry fixes that; a loop of them would not help.
  final _retried = <String>{};

  /// Failed tries in a row per pending entry, for the backoff — in memory:
  /// after a restart an entry is simply tried again at once.
  final _attempts = <String, int>{};
  Timer? _retryTimer;

  /// When each pending entry is tried next, for the UI.
  final retryAt = ValueNotifier<Map<String, DateTime>>(const {});

  /// What each running entry is doing right now — transcribing a long
  /// recording takes a while, the analysis seconds, and the UI tells them
  /// apart. In memory only: after a restart [phaseOf] infers it.
  final phases = ValueNotifier<Map<String, AnalysisPhase>>(const {});

  void _setPhase(String id, AnalysisPhase? phase) {
    if (phases.value[id] == phase) return;
    final next = Map.of(phases.value);
    if (phase == null) {
      next.remove(id);
    } else {
      next[id] = phase;
    }
    phases.value = Map.unmodifiable(next);
  }

  /// The status line of a pending entry: why it waits, and until when.
  String pendingText(JournalEntry e) {
    final why = e.errorMessage ?? 'Wartet auf Netz';
    final at = retryAt.value[e.id];
    if (at == null) return why;
    String two(int n) => n.toString().padLeft(2, '0');
    return '$why · nächster Versuch ${two(at.hour)}:${two(at.minute)}';
  }

  /// The phase of an entry still being worked on; null if it isn't.
  AnalysisPhase? phaseOf(JournalEntry e) {
    if (e.status != EntryStatus.analyzing) return null;
    return phases.value[e.id] ??
        ((e.transcript ?? '').trim().isEmpty || e.untranscribed.isNotEmpty
            ? AnalysisPhase.transcribing
            : AnalysisPhase.analyzing);
  }

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

  /// A rating given before the recording started ("before" setting), for
  /// the entry the next recording creates.
  SelfRating? ratingForNextRecording;

  /// Creates a provisional (analyzing) entry immediately, then processes it.
  /// The entry is in the repository when this returns its future — before
  /// any await — so a rating can be set on it right away.
  Future<void> createFromAudio(RecordingResult rec) async {
    final rating = ratingForNextRecording;
    ratingForNextRecording = null;
    final entry = JournalEntry(
      id: rec.id,
      createdAt: rec.createdAt,
      day: DateTime(rec.createdAt.year, rec.createdAt.month, rec.createdAt.day),
      audioFileNames: [rec.fileName],
      untranscribed: [rec.fileName],
      status: EntryStatus.analyzing,
      selfValence: rating?.valence,
      selfArousal: rating?.arousal,
      selfRatedAt: rating == null ? null : DateTime.now(),
      selfRatingTiming: rating == null ? null : kRatedBefore,
    );
    await _repo.upsert(entry);
    _refresh();
    await _attachLocation(entry.id);
    await _process(entry.id);
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
  /// separate one for the same day. Only the new recording is transcribed —
  /// its words are appended to the transcript — then summary/mood/tags and
  /// people are recomputed from the merged text. The recording is listed on
  /// the entry right away, so it survives a failed or postponed
  /// transcription (if the entry's audio was discarded, it is dropped again
  /// once transcribed).
  Future<void> appendRecording(JournalEntry entry, RecordingResult rec) async {
    final start = _repo.byId(entry.id);
    // Purged (here or elsewhere) while recording: the recording must not be
    // lost, so it becomes an entry of its own.
    if (start == null) return createFromAudio(rec);
    // Trashed elsewhere while recording: a new recording is newer intent than
    // the trashing, so the entry comes back (as typing does in the hub).
    start
      ..deletedAt = null
      ..audioFileNames = [...start.audioFileNames, rec.fileName]
      ..untranscribed = [...start.untranscribed, rec.fileName]
      ..status = EntryStatus.analyzing
      ..errorMessage = null;
    await _repo.upsert(start);
    _refresh();
    await _process(start.id);
    // Purged elsewhere meanwhile: the repository kept the recording as an
    // entry of its own (applySynced) — finish that one.
    if (_repo.byId(start.id) == null && _repo.byId(rec.id) != null) {
      await _process(rec.id);
    }
  }

  /// Re-runs the analysis (and the people) of an existing entry from its
  /// transcript. [retranscribe]: transcribe the audio again first (for a
  /// bad transcript); an entry without a transcript is always transcribed.
  /// Previous data stays until the new result replaces it.
  Future<void> reanalyze(JournalEntry entry, {bool retranscribe = false}) async {
    final live = _repo.byId(entry.id);
    if (live == null) return;
    live
      ..status = EntryStatus.analyzing
      ..errorMessage = null;
    await _repo.upsert(live);
    _refresh();
    await _process(
      live.id,
      retranscribe: retranscribe || _lacksTranscript(live),
      asked: true,
    );
  }

  /// No transcript, and no recording waiting for one: the audio has to be
  /// transcribed from scratch (a transcription that failed before Gemini).
  static bool _lacksTranscript(JournalEntry e) =>
      (e.transcript ?? '').trim().isEmpty && e.untranscribed.isEmpty;

  /// Brings an entry as far as it can go, step by step — transcript,
  /// analysis, people — skipping every step whose result is already there.
  /// A step that fails for a passing reason (no connection, rate limit)
  /// parks the entry as [EntryStatus.pending]; the next try picks it up at
  /// that step.
  ///
  /// [retranscribe]: transcribe all of the entry's audio again and replace
  /// the transcript. [asked]: started by hand ("Neu analysieren") — the
  /// analysis and the people run again even if they look current.
  Future<void> _process(
    String id, {
    bool retranscribe = false,
    bool asked = false,
  }) async {
    final start = _repo.byId(id);
    if (start == null) return;
    // What the entry held when the work started: whether a new transcript
    // may replace the stored one (not if corrected meanwhile).
    final before = _snapshot(start);
    final engine = _engine;
    _inFlight.add(id);
    try {
      await _task.run(() async {
        var transcribed = false;
        if (retranscribe && !before.audioDeleted && before.audioFileNames.isNotEmpty) {
          _setPhase(id, AnalysisPhase.transcribing);
          final transcript = await engine.transcribe(_files(before.audioFileNames));
          // Before the transcript is stored: the write repaints the list.
          _setPhase(id, AnalysisPhase.analyzing);
          final live = _repo.byId(id);
          if (live == null) return;
          // A transcript corrected by hand meanwhile wins, and is what gets
          // analysed.
          if (_same(live.transcript, before.transcript)) {
            live
              ..transcript = transcript
              ..transcriptionModel = engine.transcriptionModel;
          }
          live.untranscribed = const [];
          await _repo.upsert(live);
          _refresh();
          transcribed = true;
        } else if (before.untranscribed.isNotEmpty) {
          final waiting = before.untranscribed;
          _setPhase(id, AnalysisPhase.transcribing);
          final words = await engine.transcribe(_files(waiting));
          _setPhase(id, AnalysisPhase.analyzing);
          final live = _repo.byId(id);
          if (live == null) return;
          // Appended to the transcript as stored *now*: a correction made on
          // the laptop meanwhile stays. Kept right away, so a failure after
          // it never costs the transcript.
          live
            ..deletedAt = null // a recording brings a trashed entry back
            ..transcript = [live.transcript, words]
                .where((t) => t != null && t.trim().isNotEmpty)
                .join('\n\n')
            ..transcriptionModel = engine.transcriptionModel
            ..untranscribed = [
              for (final f in live.untranscribed)
                if (!waiting.contains(f)) f,
            ];
          final drop = live.audioDeleted ? waiting : const <String>[];
          if (drop.isNotEmpty) {
            live.audioFileNames = [
              for (final f in live.audioFileNames)
                if (!drop.contains(f)) f,
            ];
          }
          // Written before the files are touched: no await between
          // re-reading [live] and writing it.
          await _repo.upsert(live);
          for (final f in drop) {
            await _repo.deleteAudioFile(f);
          }
          _refresh();
          transcribed = true;
        }

        final current = _repo.byId(id);
        if (current == null) return;
        final text = current.transcript ?? '';
        _setPhase(id, AnalysisPhase.analyzing);
        var analysed = false;
        if (asked ||
            transcribed ||
            current.analysisBasis != transcriptBasis(text) ||
            current.moodScore == null) {
          final result = await engine.analyzeText(text);
          await _applyResult(id, result, engine.modelName, analyzedText: text);
          analysed = true;
        }
        final now = _repo.byId(id);
        if (now == null) return;
        if (analysed || (now.peopleVersion ?? 0) < kPeopleVersion) {
          await _extractPeople(id, text, engine);
        }
        await _markReady(id);
      });
      _attempts.remove(id);
      _setRetryAt(id, null);
    } catch (e) {
      if (e is AnalysisException && e.transient) {
        await _markPending(id, e);
      } else {
        await _markFailed(id, e);
      }
    } finally {
      _inFlight.remove(id);
      _setPhase(id, null);
    }
    _refresh();
  }

  List<File> _files(List<String> names) =>
      names.map((f) => File(_repo.audioPath(f))).toList();

  /// Writes an analysis result onto the entry *as stored now*, as the
  /// analysis of [analyzedText]. A title / summary / tags edited by hand
  /// meanwhile (here or on the laptop) are newer intent than an automatic
  /// result and stay ([JournalEntry.summaryByHand]).
  Future<void> _applyResult(
    String id,
    AnalysisResult result,
    String model, {
    required String analyzedText,
  }) async {
    final live = _repo.byId(id);
    if (live == null) return; // purged meanwhile: nothing left to annotate
    if (!live.titleByHand && result.title.isNotEmpty) live.title = result.title;
    if (!live.summaryByHand) live.summary = result.summary;
    if (!live.tagsByHand) live.tags = result.tags;
    live
      ..moodLabel = result.moodLabel
      ..moodScore = result.moodScore
      ..dimensions = result.dimensions
      ..analysisModel = result.model ?? model
      ..analysisVersion = kAnalysisVersion
      ..analysisSource = result.source ?? AnalysisSource.cloud
      ..analysisBasis = transcriptBasis(analyzedText);
    await _repo.saveAnalysis(live, entryChanged: false);
  }

  /// Extracts the people of [text] — the entry's transcript — and stores
  /// them as the entry's extracted names. The corrections made by hand
  /// ([JournalEntry.peopleAdded] / [JournalEntry.peopleRemoved]) aren't
  /// touched, so they survive every extraction. Where the model matched a
  /// spelling to a known person, the aliases learn it.
  Future<void> _extractPeople(String id, String text, AnalysisEngine engine) async {
    final known = knownPeople(
      _repo.entries.where((e) => e.id != id),
      _repo.aliases,
    );
    final result = await engine.extractPeople(text, known);
    final live = _repo.byId(id);
    // Gone, or the transcript changed meanwhile: these people are of a text
    // that no longer is the entry's; the next pass extracts again.
    if (live == null || !_same(live.transcript ?? '', text)) return;
    live
      ..people = result.names
      ..peopleModel = result.model
      ..peopleVersion = kPeopleVersion;
    await _repo.saveAnalysis(live, entryChanged: false);
    final learned = _repo.aliases.learn(result.mentions, known.map((k) => k.name));
    if (!identical(learned, _repo.aliases)) await _repo.writeAliases(learned);
  }

  Future<void> _markReady(String id) async {
    final live = _repo.byId(id);
    if (live == null) return;
    live
      ..errorMessage = null
      ..status = EntryStatus.ready;
    final discard = live.untranscribed.isEmpty ? _takeAudioIfDiscarding(live) : const <String>[];
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

  /// Parks the entry until the next try — by the backoff timer, a
  /// connection coming back, or the app coming to the foreground.
  Future<void> _markPending(String id, AnalysisException error) async {
    final live = _repo.byId(id);
    if (live == null) return;
    live
      ..status = EntryStatus.pending
      ..errorMessage = error.offline ? null : error.message;
    await _repo.upsert(live);
    final n = _attempts[id] = (_attempts[id] ?? 0) + 1;
    final delay = retryDelay(n);
    _setRetryAt(id, DateTime.now().add(delay));
    _armRetryTimer();
  }

  /// 30 s, 1, 2, 4 … minutes, at most half an hour.
  static Duration retryDelay(int attempt) =>
      Duration(seconds: min(30 * (1 << min(attempt - 1, 6)), 30 * 60));

  void _setRetryAt(String id, DateTime? at) {
    if (retryAt.value[id] == at) return;
    final next = Map.of(retryAt.value);
    if (at == null) {
      next.remove(id);
    } else {
      next[id] = at;
    }
    retryAt.value = Map.unmodifiable(next);
  }

  void _armRetryTimer() {
    _retryTimer?.cancel();
    if (retryAt.value.isEmpty) return;
    final next = retryAt.value.values.reduce((a, b) => a.isBefore(b) ? a : b);
    var wait = next.difference(DateTime.now());
    if (wait.isNegative) wait = Duration.zero;
    _retryTimer = Timer(wait, resumePending);
  }

  /// A detached copy to compare against after an await.
  static JournalEntry _snapshot(JournalEntry e) =>
      JournalEntry.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);

  static bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

  /// Picks up every entry with work left: `analyzing` ones a killed process
  /// left behind, `pending` ones whose next try is due, and each `failed`
  /// one once per app session. Called on app start, on every resume, when
  /// the connection comes back and by the backoff timer.
  ///
  /// [now]: don't wait for the backoff — the connection just came back, or
  /// the user opened the app; a short wait starts over from there.
  Future<void> resumePending({bool now = false}) async {
    if (now) {
      _attempts.clear();
      retryAt.value = const {};
    }
    final at = DateTime.now();
    for (final entry in _repo.entries) {
      if (_inFlight.contains(entry.id)) continue;
      final due = switch (entry.status) {
        EntryStatus.analyzing => true,
        EntryStatus.pending => !(retryAt.value[entry.id]?.isAfter(at) ?? false),
        EntryStatus.failed => _retried.add(entry.id),
        EntryStatus.ready => false,
      };
      if (due) await _process(entry.id, retranscribe: _lacksTranscript(entry));
    }
    _armRetryTimer();
  }

  /// Tries every failed entry again — after a new API key or model was set.
  Future<void> retryFailed() {
    _retried.clear();
    return resumePending(now: true);
  }

  // ── People backfill ───────────────────────────────────────────────────────

  /// Progress of [backfillPeople] while it runs; null otherwise.
  final backfill = ValueNotifier<BackfillProgress?>(null);

  /// Entries whose people come from an older extraction (or none).
  int get peopleBackfillDue => _repo.entries.where(_needsPeople).length;

  static bool _needsPeople(JournalEntry e) =>
      (e.transcript ?? '').trim().isNotEmpty && (e.peopleVersion ?? 0) < kPeopleVersion;

  /// Extracts the people of every entry with the current extraction — the
  /// same call new entries go through, so old and new are comparable. Only
  /// entries from an older (or no) extraction, unless [all]. Idempotent:
  /// each entry's extracted names are replaced, never appended to, and the
  /// corrections made by hand stay. An entry that fails keeps its old
  /// names and is picked up by the next run; no connection stops the run.
  Future<BackfillProgress> backfillPeople({bool all = false}) async {
    final running = backfill.value;
    if (running != null) return running;
    final ids = [
      for (final e in _repo.entries)
        if (all ? (e.transcript ?? '').trim().isNotEmpty : _needsPeople(e)) e.id,
    ];
    var progress = BackfillProgress(total: ids.length);
    backfill.value = progress;
    final engine = _engine;
    try {
      await _task.run(() async {
        for (final id in ids) {
          final entry = _repo.byId(id);
          if (entry == null || _inFlight.contains(id)) {
            progress = progress.next();
            backfill.value = progress;
            continue;
          }
          _inFlight.add(id);
          try {
            await _extractPeople(id, entry.transcript ?? '', engine);
            progress = progress.next();
          } on AnalysisException catch (e) {
            debugPrint('People backfill: $id: $e');
            progress = progress.next(failed: true, error: e.message);
            if (e.offline) break;
          } catch (e) {
            debugPrint('People backfill: $id: $e');
            progress = progress.next(failed: true, error: '$e');
          } finally {
            _inFlight.remove(id);
          }
          backfill.value = progress;
          _refresh();
        }
      });
    } finally {
      backfill.value = null;
      _refresh();
    }
    return progress;
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

  /// Sets the entry's self-rating. [timing] only for a first rating: a
  /// rating changed later keeps when it was first asked.
  Future<void> setSelfRating(String id, SelfRating rating, {String timing = kRatedAfter}) async {
    final live = _repo.byId(id);
    if (live == null) return;
    live
      ..selfValence = rating.valence
      ..selfArousal = rating.arousal
      ..selfRatedAt = DateTime.now()
      ..selfRatingTiming ??= timing;
    await _repo.upsert(live);
    _refresh();
  }

  // ── People by hand ────────────────────────────────────────────────────────
  //
  // Corrections live in the entry's override lists, never in the extracted
  // names, so no later extraction undoes them — see effectivePeople.

  /// Removes [person] (as shown) from the entry. Returns the override lists
  /// as they were, for [restorePeople] (undo).
  Future<PeopleOverrides?> removePerson(String id, String person) async {
    final live = _repo.byId(id);
    if (live == null) return null;
    final before = (added: live.peopleAdded, removed: live.peopleRemoved);
    final aliases = _repo.aliases;
    final key = aliases.canonical(person).toLowerCase();
    bool isThem(String name) => aliases.canonical(name).toLowerCase() == key;
    final extracted = [for (final p in live.people ?? const <String>[]) if (isThem(p)) p];
    live.peopleAdded = [for (final p in live.peopleAdded) if (!isThem(p)) p];
    if (extracted.isNotEmpty) {
      // The spellings as extracted and the name as shown: whichever a later
      // extraction writes, the person stays removed.
      final tombstones = {...live.peopleRemoved, ...extracted, aliases.canonical(person)};
      live.peopleRemoved = tombstones.toList();
    }
    await _repo.upsert(live);
    _refresh();
    return before;
  }

  /// Adds [person] to the entry by hand — or brings back one removed by hand.
  Future<PeopleOverrides?> addPerson(String id, String person) async {
    final name = person.trim();
    final live = _repo.byId(id);
    if (live == null || name.isEmpty) return null;
    final before = (added: live.peopleAdded, removed: live.peopleRemoved);
    final aliases = _repo.aliases;
    final key = aliases.canonical(name).toLowerCase();
    live.peopleRemoved = [
      for (final r in live.peopleRemoved)
        if (aliases.canonical(r).toLowerCase() != key) r,
    ];
    final shown = effectivePeople(live, aliases).map((p) => p.toLowerCase());
    if (!shown.contains(key)) live.peopleAdded = [...live.peopleAdded, name];
    await _repo.upsert(live);
    _refresh();
    return before;
  }

  /// Puts the entry's override lists back as they were (undo).
  Future<void> restorePeople(String id, PeopleOverrides before) async {
    final live = _repo.byId(id);
    if (live == null) return;
    live
      ..peopleAdded = before.added
      ..peopleRemoved = before.removed;
    await _repo.upsert(live);
    _refresh();
  }

  /// Sets or clears the entry's location label (also works on old entries).
  Future<void> setPlace(JournalEntry entry, String? place) async {
    await _repo.setPlace(entry, place);
    _refresh();
  }
}

/// An entry's corrections by hand, as they were before an edit.
typedef PeopleOverrides = ({List<String> added, List<String> removed});

/// What a running entry is doing: transcription, then the analysis.
enum AnalysisPhase { transcribing, analyzing }

/// How far [JournalManager.backfillPeople] got.
class BackfillProgress {
  final int total;
  final int done;
  final int failed;
  final String? lastError;
  const BackfillProgress({required this.total, this.done = 0, this.failed = 0, this.lastError});

  BackfillProgress next({bool failed = false, String? error}) => BackfillProgress(
        total: total,
        done: done + 1,
        failed: this.failed + (failed ? 1 : 0),
        lastError: error ?? lastError,
      );
}
