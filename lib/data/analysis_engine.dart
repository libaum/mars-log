import 'dart:io';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/people_aliases.dart';

/// Bump when the analysis prompt or schema changes, so entries can be
/// re-analysed later.
/// 2: analysis moved on-device (Whisper + Gemma 4 E2B).
/// 3: people.
/// 4: Gemini transcribes the audio; people are their own call
///    ([AnalysisEngine.extractPeople], versioned by kPeopleVersion).
const kAnalysisVersion = 4;

/// Turns audio into a transcript and a transcript into its interpretation.
/// The three steps are separate calls, so each result is kept on its own:
/// the transcript survives a failed analysis, and the people of every entry
/// — old and new — come from the very same call.
///
/// Implemented by GeminiEngine; an interface so tests can swap in a fake.
abstract class AnalysisEngine {
  /// Written to [JournalEntry.transcriptionModel].
  String get transcriptionModel;

  /// Written to [JournalEntry.analysisModel].
  String get modelName;

  /// Written to [JournalEntry.analysisSource] — see AnalysisSource.
  String get source;

  /// One transcript for all [audioFiles], in order.
  Future<String> transcribe(List<File> audioFiles);

  /// Summary, mood, dimensions, tags and title. Gets the transcript and
  /// nothing else — never the entry, so nothing the user rated about it
  /// can leak into the analysis.
  Future<AnalysisResult> analyzeText(String transcript);

  /// The people [transcript] mentions, matched against [known].
  Future<PeopleResult> extractPeople(String transcript, List<KnownPerson> known);

  /// A short recap of one month, from its entries' summaries in order.
  Future<String> summarizeMonth(List<String> summaries);
}

/// Thrown by an engine. [transient]: worth trying again later by itself —
/// no connection, a timeout, a rate limit, a server error. The entry then
/// waits ([EntryStatus.pending]) instead of failing.
class AnalysisException implements Exception {
  final String message;
  final bool transient;

  /// No connection at all (as opposed to an overloaded server) — the UI says
  /// "Wartet auf Netz".
  final bool offline;
  AnalysisException(this.message, {this.transient = false, this.offline = false});
  @override
  String toString() => message;
}
