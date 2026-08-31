import 'dart:io';
import 'package:mars_log/data/gemini_service.dart';
import 'package:mars_log/data/secure_storage_service.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/services/service_locator.dart';

/// Anything that can turn audio (or a transcript) into an [AnalysisResult].
/// Implemented by [CloudAnalysisEngine] (existing Gemini API) and
/// [OnDeviceAnalysisEngine] (Whisper + Gemini Nano, offline-analysis branch).
/// [JournalManager] talks to whichever engine is active without knowing which
/// one it is, so the two stay swappable and comparable.
abstract class AnalysisEngine {
  /// Written to [JournalEntry.analysisModel] so it's visible afterwards which
  /// engine produced a given result.
  String get modelName;

  Future<AnalysisResult> analyzeAudio(List<File> audioFiles);

  Future<AnalysisResult> analyzeText(String transcript);
}

/// Thin wrapper around the existing [GeminiService] cloud calls — no
/// behaviour change from before the offline-analysis branch existed.
class CloudAnalysisEngine implements AnalysisEngine {
  final _gemini = getIt<GeminiService>();
  final _secure = getIt<SecureStorageService>();

  /// The chain may fall back to a weaker model when the preferred one is rate
  /// limited, so the name reported is the model that actually answered last.
  @override
  String get modelName => _gemini.lastUsedModel;

  @override
  Future<AnalysisResult> analyzeAudio(List<File> audioFiles) async {
    final apiKey = await _secure.getApiKey();
    return _gemini.analyze(audioFiles: audioFiles, apiKey: apiKey ?? '');
  }

  @override
  Future<AnalysisResult> analyzeText(String transcript) async {
    final apiKey = await _secure.getApiKey();
    return _gemini.analyzeText(transcript: transcript, apiKey: apiKey ?? '');
  }
}
