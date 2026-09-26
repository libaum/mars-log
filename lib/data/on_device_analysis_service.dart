import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';
import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/data/local_llm.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

/// Whisper model used for on-device transcription. `small` is the practical
/// floor for usable German accuracy — `tiny`/`base` hallucinate too much.
const kOnDeviceWhisperModel = WhisperModel.small;
const kOnDeviceModelName = 'whisper-small+${LocalLlm.modelName}';

class OnDeviceAnalysisException implements Exception {
  final String message;
  OnDeviceAnalysisException(this.message);
  @override
  String toString() => message;
}

/// The app's analysis engine: transcribes audio locally
/// with Whisper (whisper.cpp via `whisper_ggml`), then runs the summary/mood/
/// tags step through an open model on the phone ([LocalLlm], Gemma 4 E2B).
/// Audio always goes through Whisper first, then the transcript through the
/// model — for text-only re-analysis the model runs directly.
class OnDeviceAnalysisEngine implements AnalysisEngine {
  final _whisper = WhisperController();
  final _llm = LocalLlm();

  /// Download progress of the analysis model, for settings.
  ValueListenable<int?> get llmProgress => _llm.progress;

  @override
  String get modelName => kOnDeviceModelName;

  static const _promptText = '''
Du bist der Analyse-Assistent einer Sprach-Tagebuch-App. Unten steht das
bereits transkribierte Tagebuch des Nutzers. Antworte AUSSCHLIESSLICH mit
einem JSON-Objekt, keine anderen Worte, kein Markdown, keine Code-Fences.

Format exakt so (Zahlen ohne Anführungszeichen):
{"title":"...","summary":"...","moodLabel":"...","moodScore":0.0,"dimensions":{"positivity":0,"energy":0,"calm":0,"stress":0,"focus":0,"social":0},"tags":["..."]}

Regeln:
- title: 2-5 Wörter, was den Tag ausgemacht hat (z.B. "Strandtag mit Lena",
  "Stress vor der Prüfung"). Kein Datum, kein Satzzeichen am Ende.
- summary: 2-3 Sätze aus der Ich-Perspektive, knapp.
- moodLabel: ein einzelnes deutsches Wort für die Grundstimmung.
- moodScore: 0.0 (sehr schlecht) bis 10.0 (großartig).
- dimensions: jede Dimension 0 bis 100.
- tags: 3 bis 5 kurze deutsche Substantive.

Transkript:
''';

  /// Ensures the Whisper model is downloaded before first use. Safe to call
  /// repeatedly — a no-op once the file exists on disk.
  Future<void> ensureWhisperModelDownloaded() async {
    await _whisper.downloadModel(kOnDeviceWhisperModel);
  }

  /// Makes sure the analysis model is on the device (downloads ~2.6 GB on
  /// first use).
  Future<void> ensureLlmReady() => _llm.ensureReady();

  @override
  Future<AnalysisResult> analyzeAudio(List<File> audioFiles) async =>
      analyzeText(await transcribe(audioFiles));

  @override
  Future<String> transcribe(List<File> audioFiles) async {
    // First use downloads the model (a few hundred MB, from Hugging Face, not
    // Google). A no-op afterwards.
    await ensureWhisperModelDownloaded();
    final transcripts = <String>[];
    for (final file in audioFiles) {
      if (!await file.exists()) {
        throw OnDeviceAnalysisException('Audiodatei nicht gefunden.');
      }
      final result = await _whisper.transcribe(
        model: kOnDeviceWhisperModel,
        audioPath: file.path,
        lang: 'de',
      );
      final text = result?.transcription.text.trim() ?? '';
      if (text.isNotEmpty) transcripts.add(text);
    }
    final transcript = transcripts.join('\n\n');
    if (transcript.isEmpty) {
      throw OnDeviceAnalysisException(
        'Whisper konnte kein Transkript erzeugen (Modell heruntergeladen?).',
      );
    }
    return transcript;
  }

  @override
  Future<AnalysisResult> analyzeText(String transcript) async {
    if (transcript.trim().isEmpty) {
      throw OnDeviceAnalysisException('Kein Transkript vorhanden.');
    }
    final answer = await _llm.generate('$_promptText$transcript');
    if (answer.isEmpty) {
      throw OnDeviceAnalysisException('Das Analysemodell lieferte keine Antwort.');
    }
    final data = _extractJson(answer);
    return AnalysisResult(
      transcript: transcript,
      title: (data['title'] as String?)?.trim() ?? '',
      summary: (data['summary'] as String?)?.trim() ?? '',
      moodLabel: (data['moodLabel'] as String?)?.trim() ?? '',
      moodScore: ((data['moodScore'] as num?)?.toDouble() ?? 5.0)
          .clamp(0.0, 10.0),
      dimensions: {
        for (final d in kMoodDimensions)
          d: (((data['dimensions'] as Map?)?[d] as num?)?.toInt() ?? 50)
              .clamp(0, 100),
      },
      tags: (data['tags'] as List<dynamic>?)
              ?.map((t) => t.toString())
              .where((t) => t.isNotEmpty)
              .toList() ??
          const [],
    );
  }

  static const _promptMonth = '''
Du bist der Rückblick-Assistent einer Sprach-Tagebuch-App. Unten stehen die
Zusammenfassungen der Tagebucheinträge eines Monats, in zeitlicher Reihenfolge.
Schreib einen Rückblick auf den Monat in 4-6 Sätzen, aus der Du-Perspektive,
warm und konkret: was ihn geprägt hat, wie sich die Stimmung entwickelt hat,
was wiederkehrt. Nur der Text, keine Überschrift, kein Markdown.

Einträge:
''';

  /// The model's context is 4096 tokens here, so a long month is recapped in
  /// parts first and the parts are then recapped together.
  static const _maxMonthChars = 6000;

  @override
  Future<String> summarizeMonth(List<String> summaries) async {
    if (summaries.isEmpty) {
      throw OnDeviceAnalysisException('Keine Einträge für diesen Monat.');
    }
    final lines = summaries.map((s) => '- ${s.trim()}').toList();
    if (lines.join('\n').length <= _maxMonthChars) {
      return _recap(lines.join('\n'));
    }
    final parts = <String>[];
    var chunk = <String>[];
    var size = 0;
    for (final line in lines) {
      if (size + line.length > _maxMonthChars && chunk.isNotEmpty) {
        parts.add(await _recap(chunk.join('\n')));
        chunk = [];
        size = 0;
      }
      chunk.add(line);
      size += line.length + 1;
    }
    if (chunk.isNotEmpty) parts.add(await _recap(chunk.join('\n')));
    return _recap(parts.map((p) => '- $p').join('\n'));
  }

  Future<String> _recap(String body) async {
    final text = await _llm.generate('$_promptMonth$body', temperature: 0.5);
    if (text.isEmpty) {
      throw OnDeviceAnalysisException('Das Analysemodell lieferte keinen Rückblick.');
    }
    return text;
  }

  /// The model has no schema enforcement — extract the first `{...}` block
  /// rather than trusting the whole response to be clean JSON.
  Map<String, dynamic> _extractJson(String text) {
    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      final match = RegExp(r'\{[\s\S]*\}').firstMatch(text);
      if (match == null) {
        throw OnDeviceAnalysisException(
          'Antwort des Analysemodells konnte nicht gelesen werden.',
        );
      }
      try {
        return jsonDecode(match.group(0)!) as Map<String, dynamic>;
      } catch (e) {
        throw OnDeviceAnalysisException(
          'Antwort des Analysemodells konnte nicht gelesen werden: $e',
        );
      }
    }
  }
}
