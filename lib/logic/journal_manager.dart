import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mars_log/data/gemini_service.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/secure_storage_service.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/logic/recording_manager.dart';
import 'package:mars_log/services/service_locator.dart';

/// Core state manager for the journal. Coordinates recording → entry creation →
/// Gemini analysis, and exposes the live entry list to the UI.
class JournalManager {
  final _repo = getIt<JournalRepository>();
  final _gemini = getIt<GeminiService>();
  final _secure = getIt<SecureStorageService>();

  late final ValueNotifier<List<JournalEntry>> entriesNotifier;

  JournalManager() {
    entriesNotifier = ValueNotifier(_repo.entries);
  }

  void _refresh() => entriesNotifier.value = _repo.entries;

  /// Creates a provisional (analyzing) entry immediately, then analyses it.
  Future<void> createFromAudio(RecordingResult rec) async {
    final entry = JournalEntry(
      id: rec.id,
      createdAt: rec.createdAt,
      day: DateTime(rec.createdAt.year, rec.createdAt.month, rec.createdAt.day),
      audioFileName: rec.fileName,
      status: EntryStatus.analyzing,
    );
    await _repo.upsert(entry);
    _refresh();
    await _analyze(entry);
  }

  /// Re-runs analysis on an existing entry; audio + previous data are kept
  /// until the new result overwrites them.
  Future<void> reanalyze(JournalEntry entry) async {
    entry.status = EntryStatus.analyzing;
    entry.errorMessage = null;
    await _repo.upsert(entry);
    _refresh();
    await _analyze(entry);
  }

  Future<void> _analyze(JournalEntry entry) async {
    try {
      final apiKey = await _secure.getApiKey() ?? '';
      final result = await _gemini.analyze(
        audioFile: File(_repo.audioPath(entry.audioFileName)),
        apiKey: apiKey,
      );
      entry
        ..transcript = result.transcript
        ..summary = result.summary
        ..moodLabel = result.moodLabel
        ..moodScore = result.moodScore
        ..dimensions = result.dimensions
        ..tags = result.tags
        ..analysisModel = kGeminiModel
        ..analysisVersion = kAnalysisVersion
        ..errorMessage = null
        ..status = EntryStatus.ready;
    } catch (e) {
      entry
        ..status = EntryStatus.failed
        ..errorMessage = e.toString();
    }
    await _repo.upsert(entry);
    _refresh();
  }

  Future<void> delete(JournalEntry entry) async {
    // Remove from the in-memory list synchronously (before awaiting the file
    // IO) and refresh now, so a Dismissible sees the item gone in the same
    // frame it dismisses it.
    final done = _repo.delete(entry);
    _refresh();
    await done;
  }

  /// Moves an entry to a different day (e.g. backdating). Re-sorts the timeline.
  Future<void> setDay(JournalEntry entry, DateTime day) async {
    entry.day = DateTime(day.year, day.month, day.day);
    await _repo.upsert(entry);
    _refresh();
  }
}
