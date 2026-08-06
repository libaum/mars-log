import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/data/gemini_service.dart' show kAnalysisVersion;
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/data/on_device_analysis_service.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/logic/location_service.dart';
import 'package:mars_log/logic/recording_manager.dart';
import 'package:mars_log/services/service_locator.dart';

/// Core state manager for the journal. Coordinates recording → entry creation →
/// analysis, and exposes the live entry list to the UI. Analysis goes through
/// whichever [AnalysisEngine] is currently selected in settings (cloud Gemini
/// or, on the offline-analysis branch, on-device Whisper + Gemini Nano).
class JournalManager {
  final _repo = getIt<JournalRepository>();
  final _storage = getIt<LocalStorageService>();
  final _location = getIt<LocationService>();
  final _cloud = getIt<CloudAnalysisEngine>();
  final _onDevice = getIt<OnDeviceAnalysisEngine>();

  late final ValueNotifier<List<JournalEntry>> entriesNotifier;
  late final ValueNotifier<List<JournalEntry>> trashNotifier;

  JournalManager() {
    entriesNotifier = ValueNotifier(_repo.entries);
    trashNotifier = ValueNotifier(_repo.deletedEntries);
  }

  void _refresh() {
    entriesNotifier.value = _repo.entries;
    trashNotifier.value = _repo.deletedEntries;
  }

  /// The engine currently selected in settings (defaults to cloud).
  AnalysisEngine _activeEngine() =>
      _storage.getAnalysisEngine() == 'on_device' ? _onDevice : _cloud;

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
    await _attachLocation(entry);
    await _analyze(entry, _activeEngine());
  }

  /// Best-effort: stamp the entry with where it was recorded. Silent on failure.
  Future<void> _attachLocation(JournalEntry entry) async {
    final loc = await _location.current();
    if (loc == null) return;
    entry
      ..latitude = loc.latitude
      ..longitude = loc.longitude
      ..place = loc.place;
    await _repo.upsert(entry);
    _refresh();
  }

  /// Adds another recording to an existing entry instead of creating a
  /// separate one for the same day. Only the new snippet is sent to Gemini
  /// for transcription — the existing transcript is already known and isn't
  /// re-transcribed — then summary/mood/tags are recomputed from the merged
  /// text. The recording is kept as its own audio file alongside the
  /// entry's other ones (unless the entry's audio was already discarded, in
  /// which case the new snippet's audio is dropped too, once transcribed).
  Future<void> appendRecording(JournalEntry entry, RecordingResult rec) async {
    entry.status = EntryStatus.analyzing;
    entry.errorMessage = null;
    await _repo.upsert(entry);
    _refresh();

    final engine = _activeEngine();
    try {
      final partial = await engine
          .analyzeAudio([File(_repo.audioPath(rec.fileName))]);
      entry.transcript = [entry.transcript, partial.transcript]
          .where((t) => t != null && t.isNotEmpty)
          .join('\n\n');

      if (entry.audioDeleted) {
        await _repo.deleteAudioFile(rec.fileName);
      } else {
        entry.audioFileNames.add(rec.fileName);
      }

      final result = await engine.analyzeText(entry.transcript!);
      entry
        ..summary = result.summary
        ..moodLabel = result.moodLabel
        ..moodScore = result.moodScore
        ..dimensions = result.dimensions
        ..tags = result.tags
        ..analysisModel = engine.modelName
        ..analysisVersion = kAnalysisVersion
        ..errorMessage = null
        ..status = EntryStatus.ready;
      await _maybeDiscardAudio(entry);
    } catch (e) {
      entry
        ..status = EntryStatus.failed
        ..errorMessage = e.toString();
    }
    await _repo.upsert(entry);
    _refresh();
  }

  /// Re-runs analysis on an existing entry with the currently selected
  /// engine; audio + previous data are kept until the new result overwrites
  /// them.
  Future<void> reanalyze(JournalEntry entry) => reanalyzeWith(
        entry,
        _activeEngine(),
      );

  /// Re-runs analysis with an explicitly chosen engine, regardless of the
  /// global setting — lets the detail screen run the same entry through both
  /// cloud and on-device for a direct comparison.
  Future<void> reanalyzeWith(JournalEntry entry, AnalysisEngine engine) async {
    entry.status = EntryStatus.analyzing;
    entry.errorMessage = null;
    await _repo.upsert(entry);
    _refresh();
    await _analyze(entry, engine);
  }

  Future<void> _analyze(JournalEntry entry, AnalysisEngine engine) async {
    try {
      // Once the audio is gone, the transcript is the only source to work from.
      final result = entry.audioDeleted
          ? await engine.analyzeText(entry.transcript ?? '')
          : await engine.analyzeAudio(
              entry.audioFileNames
                  .map((f) => File(_repo.audioPath(f)))
                  .toList(),
            );
      entry
        ..transcript = result.transcript
        ..summary = result.summary
        ..moodLabel = result.moodLabel
        ..moodScore = result.moodScore
        ..dimensions = result.dimensions
        ..tags = result.tags
        ..analysisModel = engine.modelName
        ..analysisVersion = kAnalysisVersion
        ..errorMessage = null
        ..status = EntryStatus.ready;
      await _maybeDiscardAudio(entry);
    } catch (e) {
      entry
        ..status = EntryStatus.failed
        ..errorMessage = e.toString();
    }
    await _repo.upsert(entry);
    _refresh();
  }

  /// If the "delete audio after transcription" setting is on, drop the audio now
  /// that a transcript exists. Only fires on a successful, audio-backed pass.
  Future<void> _maybeDiscardAudio(JournalEntry entry) async {
    if (entry.audioDeleted) return;
    if (!_storage.getDeleteAudioAfterTranscription()) return;
    await _repo.discardAudio(entry);
    entry.audioDeleted = true;
    entry.audioFileNames = [];
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
  Future<void> emptyTrash() async {
    await _repo.emptyTrash();
    _refresh();
  }

  /// Moves an entry to a different day (e.g. backdating). Re-sorts the timeline.
  Future<void> setDay(JournalEntry entry, DateTime day) async {
    entry.day = DateTime(day.year, day.month, day.day);
    await _repo.upsert(entry);
    _refresh();
  }

  /// Sets or clears the entry's location label (also works on old entries).
  Future<void> setPlace(JournalEntry entry, String? place) async {
    final trimmed = place?.trim();
    entry.place = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    await _repo.upsert(entry);
    _refresh();
  }
}
