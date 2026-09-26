import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/domain/analysis_basis.dart';
import 'package:mars_log/domain/journal_entry.dart';

/// The model the cloud analysis uses.
const kGeminiModel = 'gemini-3.8-flash';

class GeminiException implements Exception {
  final String message;

  /// No connection (offline, timeout) — worth falling back to the on-device
  /// model rather than failing the entry. A rejected key is not.
  final bool network;
  GeminiException(this.message, {this.network = false});
  @override
  String toString() => message;
}

/// Analysis through the Gemini API — **text only**. Transcription stays with
/// Whisper on the phone ([transcriber]); the recording never leaves the
/// device, only the transcript goes to Google.
///
/// Meant for the paid API tier: prompts and answers aren't used to train
/// Google's models there. The free tier only gets that protection inside the
/// EU/EEA/UK/Switzerland.
class GeminiTextEngine implements AnalysisEngine {
  final AnalysisEngine transcriber;
  final Future<String?> Function() apiKey;
  final Uri endpoint;

  GeminiTextEngine({
    required this.transcriber,
    required this.apiKey,
    Uri? endpoint,
  }) : endpoint = endpoint ??
            Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/');

  @override
  String get modelName => 'whisper-small+$kGeminiModel';

  @override
  String get source => AnalysisSource.cloud;

  static const _prompt = '''
Du bist der Analyse-Assistent einer Sprach-Tagebuch-App. Unten steht ein
transkribierter, gesprochener Tagebucheintrag (automatisch transkribiert, kann
Hör- und Schreibfehler enthalten). Der Eintrag ist auf Deutsch, mit
gelegentlichen englischen Wörtern — das ist normal. Antworte immer auf Deutsch
(englische Begriffe darfst du übernehmen, wo sie so gemeint sind) und
ausschließlich mit dem geforderten JSON.

Aufgaben:
1. title: 2–5 Wörter, was den Tag ausgemacht hat — wie eine Überschrift im
   Tagebuch (z. B. "Strandtag mit Lena", "Stress vor der Prüfung"). Kein
   Datum, kein Satzzeichen am Ende.
2. summary: Fasse den Eintrag in 3–5 Sätzen aus der Ich-Perspektive zusammen.
   Konkret: was passiert ist, was mich beschäftigt, was ich vorhabe. Nichts
   dazuerfinden.
3. moodLabel: Ein einzelnes deutsches Wort für die Grundstimmung (z. B.
   "Motiviert", "Erschöpft", "Ausgeglichen").
4. moodScore: Wie gut der Tag insgesamt klingt, von 0.0 (sehr schlecht) bis
   10.0 (großartig).
5. dimensions: Schätze jede Dimension von 0 bis 100 — positivity, energy,
   calm, stress, focus, social.
6. tags: 3 bis 6 kurze Themen-Tags (deutsche Substantive, z. B. "Sport",
   "Arbeit", "Freunde").

Transkript:
''';

  static const _promptMonth = '''
Du bist der Analyse-Assistent einer Sprach-Tagebuch-App. Unten stehen die
Kurzzusammenfassungen aller Tagebucheinträge eines Monats, chronologisch
geordnet. Schreibe daraus einen zusammenhängenden Rückblick auf den Monat aus
der Ich-Perspektive (4–6 Sätze): wiederkehrende Themen, wie sich die Stimmung
über den Monat entwickelt hat, was auffällt. Antworte ausschließlich mit dem
geforderten JSON.

Zusammenfassungen:
''';

  static final Map<String, Object> _schema = {
    'type': 'OBJECT',
    'properties': {
      'title': {'type': 'STRING'},
      'summary': {'type': 'STRING'},
      'moodLabel': {'type': 'STRING'},
      'moodScore': {'type': 'NUMBER'},
      'dimensions': {
        'type': 'OBJECT',
        'properties': {
          for (final d in kMoodDimensions) d: {'type': 'INTEGER'},
        },
        'required': kMoodDimensions,
      },
      'tags': {
        'type': 'ARRAY',
        'items': {'type': 'STRING'},
      },
    },
    'required': ['title', 'summary', 'moodLabel', 'moodScore', 'dimensions', 'tags'],
    'propertyOrdering': ['title', 'summary', 'moodLabel', 'moodScore', 'dimensions', 'tags'],
  };

  static final Map<String, Object> _reviewSchema = {
    'type': 'OBJECT',
    'properties': {
      'review': {'type': 'STRING'},
    },
    'required': ['review'],
  };

  @override
  Future<String> transcribe(List<File> audioFiles) => transcriber.transcribe(audioFiles);

  @override
  Future<AnalysisResult> analyzeAudio(List<File> audioFiles) async =>
      analyzeText(await transcribe(audioFiles));

  @override
  Future<AnalysisResult> analyzeText(String transcript) async {
    if (transcript.trim().isEmpty) {
      throw GeminiException('Kein Transkript vorhanden.');
    }
    final json = await _generate('$_prompt$transcript', _schema);
    final dims = json['dimensions'] as Map<String, dynamic>? ?? const {};
    return AnalysisResult(
      transcript: transcript,
      title: (json['title'] as String?)?.trim() ?? '',
      summary: (json['summary'] as String?)?.trim() ?? '',
      moodLabel: (json['moodLabel'] as String?)?.trim() ?? '',
      moodScore: ((json['moodScore'] as num?)?.toDouble() ?? 5.0).clamp(0.0, 10.0),
      dimensions: {
        for (final d in kMoodDimensions) d: ((dims[d] as num?)?.toInt() ?? 50).clamp(0, 100),
      },
      tags: [
        for (final t in (json['tags'] as List<dynamic>? ?? const []))
          if (t.toString().trim().isNotEmpty) t.toString().trim(),
      ],
      model: modelName,
      source: source,
    );
  }

  @override
  Future<String> summarizeMonth(List<String> summaries) async {
    if (summaries.isEmpty) {
      throw GeminiException('Keine Einträge für diesen Monat.');
    }
    final body = summaries.map((s) => '- $s').join('\n');
    final json = await _generate('$_promptMonth$body', _reviewSchema);
    final review = (json['review'] as String?)?.trim() ?? '';
    if (review.isEmpty) throw GeminiException('Gemini lieferte keinen Rückblick.');
    return review;
  }

  Future<Map<String, dynamic>> _generate(String prompt, Map<String, Object> schema) async {
    final key = (await apiKey())?.trim() ?? '';
    if (key.isEmpty) {
      throw GeminiException('Kein Gemini API-Key hinterlegt (Einstellungen → Analyse).');
    }
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
          ],
        },
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'responseSchema': schema,
        'temperature': 0.4,
        // Thinking tokens are billed as output. A summary, a mood and a few
        // tags don't need deep reasoning; 'low' keeps an entry at a fraction
        // of a cent (the model's default is 'medium').
        'thinkingConfig': {'thinkingLevel': 'low'},
      },
    });
    // One retry: a connection dropped in a network switch shouldn't fail the
    // entry.
    for (var attempt = 0;; attempt++) {
      try {
        return await _post(key, body);
      } on GeminiException catch (e) {
        if (!e.network || attempt > 0) rethrow;
      }
    }
  }

  Future<Map<String, dynamic>> _post(String key, String body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      // Not resolve(): 'gemini-3.8-flash:…' would parse as a URI scheme.
      final req = await client.postUrl(
        endpoint.replace(path: '${endpoint.path}$kGeminiModel:generateContent'),
      );
      // In a header, not the URL: URLs end up in logs and error messages.
      req.headers
        ..contentType = ContentType.json
        ..set('x-goog-api-key', key);
      req.add(utf8.encode(body));
      final res = await req.close().timeout(const Duration(seconds: 90));
      final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 90));
      if (res.statusCode != 200) {
        throw GeminiException(_errorFrom(res.statusCode, text));
      }
      final data = jsonDecode(text) as Map<String, dynamic>;
      final candidates = data['candidates'] as List<dynamic>?;
      final parts = ((candidates?.firstOrNull as Map<String, dynamic>?)?['content']
          as Map<String, dynamic>?)?['parts'] as List<dynamic>?;
      final answer = (parts?.firstOrNull as Map<String, dynamic>?)?['text'] as String?;
      if (answer == null) throw GeminiException('Gemini lieferte keine Antwort.');
      return jsonDecode(answer) as Map<String, dynamic>;
    } on SocketException {
      throw GeminiException('Keine Verbindung zu Gemini.', network: true);
    } on TimeoutException {
      throw GeminiException('Zeitüberschreitung bei der Gemini-Anfrage.', network: true);
    } on HttpException {
      throw GeminiException('Verbindung zu Gemini abgebrochen.', network: true);
    } on FormatException {
      throw GeminiException('Antwort von Gemini konnte nicht gelesen werden.');
    } finally {
      client.close(force: true);
    }
  }

  static String _errorFrom(int status, String body) {
    String? message;
    try {
      message = ((jsonDecode(body) as Map<String, dynamic>)['error']
          as Map<String, dynamic>?)?['message'] as String?;
    } catch (_) {}
    return switch (status) {
      400 || 403 => 'Gemini lehnt die Anfrage ab — API-Key prüfen. ($status${message == null ? '' : ': $message'})',
      429 => 'Gemini-Kontingent erschöpft — später erneut versuchen.',
      _ => 'Gemini-Fehler $status${message == null ? '' : ': $message'}',
    };
  }
}

/// The engine settings chose: on-device (Gemma) or Gemini for the analysis;
/// transcription is Whisper either way. Without a connection the cloud choice
/// falls back to the on-device model, so an entry recorded offline still
/// gets its (pre-)analysis.
class SelectedAnalysisEngine implements AnalysisEngine {
  final AnalysisEngine onDevice;
  final AnalysisEngine cloud;
  final bool Function() useCloud;

  SelectedAnalysisEngine({
    required this.onDevice,
    required this.cloud,
    required this.useCloud,
  });

  AnalysisEngine get _current => useCloud() ? cloud : onDevice;

  @override
  String get modelName => _current.modelName;

  @override
  String get source => _current.source;

  @override
  Future<String> transcribe(List<File> audioFiles) => onDevice.transcribe(audioFiles);

  @override
  Future<AnalysisResult> analyzeAudio(List<File> audioFiles) async =>
      analyzeText(await transcribe(audioFiles));

  @override
  Future<AnalysisResult> analyzeText(String transcript) async {
    if (!useCloud()) return onDevice.analyzeText(transcript);
    try {
      return await cloud.analyzeText(transcript);
    } on GeminiException catch (e) {
      if (!e.network) rethrow;
      return onDevice.analyzeText(transcript);
    }
  }

  @override
  Future<String> summarizeMonth(List<String> summaries) async {
    if (!useCloud()) return onDevice.summarizeMonth(summaries);
    try {
      return await cloud.summarizeMonth(summaries);
    } on GeminiException catch (e) {
      if (!e.network) rethrow;
      return onDevice.summarizeMonth(summaries);
    }
  }
}
