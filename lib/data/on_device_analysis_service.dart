import 'dart:convert';
import 'dart:io';
import 'package:gemini_nano_android/gemini_nano_android.dart';
import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

/// Whisper model used for on-device transcription. `small` is the practical
/// floor for usable German accuracy — `tiny`/`base` hallucinate too much.
const kOnDeviceWhisperModel = WhisperModel.small;
const kOnDeviceModelName = 'whisper-small+gemini-nano';

class OnDeviceAnalysisException implements Exception {
  final String message;
  OnDeviceAnalysisException(this.message);
  @override
  String toString() => message;
}

/// On-device counterpart to [CloudAnalysisEngine]: transcribes audio locally
/// with Whisper (whisper.cpp via `whisper_ggml`), then runs the summary/mood/
/// tags step through Gemini Nano on-device via AICore (`gemini_nano_android`).
/// Gemini Nano itself only takes text, so audio always goes through Whisper
/// first, then the merged transcript through Nano — for text-only
/// re-analysis Nano runs directly.
class OnDeviceAnalysisEngine implements AnalysisEngine {
  final _whisper = WhisperController();
  final _nano = GeminiNanoAndroid();

  @override
  String get modelName => kOnDeviceModelName;

  static const _promptText = '''
Du bist der Analyse-Assistent einer Sprach-Tagebuch-App. Unten steht das
bereits transkribierte Tagebuch des Nutzers. Antworte AUSSCHLIESSLICH mit
einem JSON-Objekt, keine anderen Worte, kein Markdown, keine Code-Fences.

Format exakt so (Zahlen ohne Anführungszeichen):
{"summary":"...","moodLabel":"...","moodScore":0.0,"dimensions":{"positivity":0,"energy":0,"calm":0,"stress":0,"focus":0,"social":0},"tags":["..."]}

Regeln:
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

  /// Checks whether Gemini Nano is available on this device (AICore support
  /// + model downloaded). Doesn't throw.
  Future<bool> isNanoAvailable() => _nano.isAvailable();

  @override
  Future<AnalysisResult> analyzeAudio(List<File> audioFiles) async {
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
    return analyzeText(transcript);
  }

  @override
  Future<AnalysisResult> analyzeText(String transcript) async {
    if (transcript.trim().isEmpty) {
      throw OnDeviceAnalysisException('Kein Transkript vorhanden.');
    }
    if (!await _nano.isAvailable()) {
      throw OnDeviceAnalysisException(
        'Gemini Nano ist auf diesem Gerät nicht verfügbar.',
      );
    }
    final candidates = await _nano.generate(
      prompt: '$_promptText$transcript',
      temperature: 0.4,
      maxOutputTokens: 256,
    );
    if (candidates.isEmpty) {
      throw OnDeviceAnalysisException('Gemini Nano lieferte keine Antwort.');
    }
    final data = _extractJson(candidates.first);
    return AnalysisResult(
      transcript: transcript,
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

  /// Gemini Nano has no schema enforcement — extract the first `{...}` block
  /// rather than trusting the whole response to be clean JSON.
  Map<String, dynamic> _extractJson(String text) {
    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      final match = RegExp(r'\{[\s\S]*\}').firstMatch(text);
      if (match == null) {
        throw OnDeviceAnalysisException(
          'Antwort von Gemini Nano konnte nicht gelesen werden.',
        );
      }
      try {
        return jsonDecode(match.group(0)!) as Map<String, dynamic>;
      } catch (e) {
        throw OnDeviceAnalysisException(
          'Antwort von Gemini Nano konnte nicht gelesen werden: $e',
        );
      }
    }
  }
}
