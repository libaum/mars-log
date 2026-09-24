import 'dart:io';
import 'package:mars_log/domain/journal_entry.dart';

/// Bump when the prompt or schema changes, so entries can be re-analysed later.
/// 2: analysis moved on-device (Whisper + Gemini Nano); no cloud AI anymore.
const kAnalysisVersion = 2;

/// Anything that can turn audio (or a transcript) into an [AnalysisResult].
/// Implemented by [OnDeviceAnalysisEngine]: nothing leaves the phone. Kept as
/// an interface so tests can swap in a fake, and so a later engine (e.g. a
/// local LLM on the laptop) slots in without touching [JournalManager].
abstract class AnalysisEngine {
  /// Written to [JournalEntry.analysisModel] so it's visible afterwards which
  /// engine produced a given result.
  String get modelName;

  Future<AnalysisResult> analyzeAudio(List<File> audioFiles);

  Future<AnalysisResult> analyzeText(String transcript);

  /// A short recap of one month, from its entries' summaries in order.
  Future<String> summarizeMonth(List<String> summaries);
}
