import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:mars_log/domain/journal_entry.dart';

/// Bump when the prompt or schema changes, so entries can be re-analysed later.
const kAnalysisVersion = 1;

/// Models to try, best first. The free tier caps each model separately
/// (Gemini 3.7 Flash: 5 RPM / 20 RPD), so when the strongest model is rate
/// limited the call falls through to the next one instead of failing the
/// entry — the lite models at the end carry a much higher daily quota
/// (15 RPM / 500 RPD) and keep the app usable for the rest of the day.
const kGeminiModels = <String>[
  'gemini-3.7-flash',
  'gemini-3.5-flash',
  'gemini-2.5-flash',
  'gemini-3.5-flash-lite',
];

/// Preferred model — what a fresh call starts with.
const kGeminiModel = 'gemini-3.7-flash';

class GeminiException implements Exception {
  final String message;
  GeminiException(this.message);
  @override
  String toString() => message;
}

/// Internal: a failure that justifies trying the next model in [kGeminiModels].
class _GeminiRetryable implements Exception {
  final String message;
  _GeminiRetryable(this.message);
  @override
  String toString() => message;
}

/// Sends recorded audio to Gemini and gets back a full [AnalysisResult] in one
/// multimodal call: transcription + summary + mood + tags as structured JSON.
class GeminiService {
  static const _endpoint =
      'https://generativelanguage.googleapis.com/v1beta/models';

  static const _prompt = '''
Du bist der Analyse-Assistent einer Sprach-Tagebuch-App. Der Nutzer hat einen
gesprochenen Tagebucheintrag aufgenommen. Analysiere die beigefügte Audiodatei
und antworte ausschließlich mit dem geforderten JSON.

Aufgaben:
1. transcript: Transkribiere das Gesagte wörtlich in der Originalsprache (i.d.R. Deutsch). Keine Zusammenfassung, keine Korrekturen.
2. summary: Fasse den Eintrag in 3–5 Sätzen aus der Ich-Perspektive zusammen.
3. moodLabel: Ein einzelnes deutsches Wort für die Grundstimmung (z.B. "Motiviert", "Erschöpft", "Ausgeglichen").
4. moodScore: Wie gut der Tag insgesamt klingt, von 0.0 (sehr schlecht) bis 10.0 (großartig).
5. dimensions: Schätze jede Dimension von 0 bis 100 – positivity, energy, calm, stress, focus, social.
6. tags: 3 bis 6 kurze Themen-Tags (deutsche Substantive, z.B. "Sport", "Arbeit", "Freunde").

Wenn die Aufnahme leer oder unverständlich ist, gib einen leeren transcript,
eine kurze Erklärung als summary, moodScore 5.0 und neutrale Werte zurück.

Falls mehrere Audiodateien angehängt sind, gehören sie alle zum selben Tag und
wurden nacheinander aufgenommen. Transkribiere sie in der gegebenen
Reihenfolge und behandle sie inhaltlich als einen zusammenhängenden Eintrag.
''';

  /// Text-only variant: used when the audio has already been discarded and only
  /// the transcript survives. The transcript is returned unchanged.
  static const _promptText = '''
Du bist der Analyse-Assistent einer Sprach-Tagebuch-App. Unten steht das bereits
transkribierte Tagebuch des Nutzers. Analysiere den Text und antworte
ausschließlich mit dem geforderten JSON.

Aufgaben:
1. transcript: Gib den Text unverändert zurück.
2. summary: Fasse den Eintrag in 3–5 Sätzen aus der Ich-Perspektive zusammen.
3. moodLabel: Ein einzelnes deutsches Wort für die Grundstimmung (z.B. "Motiviert", "Erschöpft", "Ausgeglichen").
4. moodScore: Wie gut der Tag insgesamt klingt, von 0.0 (sehr schlecht) bis 10.0 (großartig).
5. dimensions: Schätze jede Dimension von 0 bis 100 – positivity, energy, calm, stress, focus, social.
6. tags: 3 bis 6 kurze Themen-Tags (deutsche Substantive, z.B. "Sport", "Arbeit", "Freunde").

Transkript:
''';

  /// Used for the on-demand monthly AI review: takes the month's per-entry
  /// summaries (chronological) and writes a short first-person recap.
  static const _promptMonthReview = '''
Du bist der Analyse-Assistent einer Sprach-Tagebuch-App. Unten stehen die
Kurzzusammenfassungen aller Tagebucheinträge eines Monats, chronologisch
geordnet. Schreibe daraus einen zusammenhängenden Rückblick auf den Monat aus
der Ich-Perspektive (4–6 Sätze): wiederkehrende Themen, wie sich die Stimmung
über den Monat entwickelt hat, was auffällt. Antworte ausschließlich mit dem
geforderten JSON.

Zusammenfassungen:
''';

  static final Map<String, Object> _reviewSchema = {
    'type': 'OBJECT',
    'properties': {
      'review': {'type': 'STRING'},
    },
    'required': ['review'],
  };

  static final Map<String, Object> _responseSchema = {
    'type': 'OBJECT',
    'properties': {
      'transcript': {'type': 'STRING'},
      'summary': {'type': 'STRING'},
      'moodLabel': {'type': 'STRING'},
      'moodScore': {'type': 'NUMBER'},
      'dimensions': {
        'type': 'OBJECT',
        'properties': {
          for (final d in kMoodDimensions) d: {'type': 'INTEGER'},
        },
        'required': kMoodDimensions,
        'propertyOrdering': kMoodDimensions,
      },
      'tags': {
        'type': 'ARRAY',
        'items': {'type': 'STRING'},
      },
    },
    'required': [
      'transcript',
      'summary',
      'moodLabel',
      'moodScore',
      'dimensions',
      'tags',
    ],
    'propertyOrdering': [
      'transcript',
      'summary',
      'moodLabel',
      'moodScore',
      'dimensions',
      'tags',
    ],
  };

  /// Analyse one or more [audioFiles] (in chronological order) as a single
  /// entry. [apiKey] must be a valid Generative Language API key.
  Future<AnalysisResult> analyze({
    required List<File> audioFiles,
    required String apiKey,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw GeminiException('Kein Gemini API-Key hinterlegt.');
    }
    var totalBytes = 0;
    for (final file in audioFiles) {
      if (!await file.exists()) {
        throw GeminiException('Audiodatei nicht gefunden.');
      }
      totalBytes += await file.length();
    }

    return _generate(
      apiKey,
      [
        {'text': _prompt},
        for (final file in audioFiles)
          {
            'inline_data': {
              'mime_type': _mimeTypeFor(file.path),
              'data': base64Encode(await file.readAsBytes()),
            },
          },
      ],
      timeout: _timeoutFor(totalBytes),
    );
  }

  /// Older entries may still carry `.wav` recordings from before the
  /// switch to AAC (`.m4a`), so the mime type is derived per file rather
  /// than assumed.
  String _mimeTypeFor(String path) =>
      path.toLowerCase().endsWith('.wav') ? 'audio/wav' : 'audio/aac';

  /// Upload of a large recording can dominate the request time on a slow
  /// connection, so the timeout scales with audio size rather than being a
  /// flat cutoff that a long recording can never finish within (90s was too
  /// short for ~10 minutes of audio and always failed with a timeout).
  /// Assumes a conservative 50 KB/s floor, plus headroom for processing,
  /// capped so a broken request doesn't hang forever.
  Duration _timeoutFor(int totalBytes) {
    final seconds = 90 + totalBytes ~/ (50 * 1024);
    return Duration(seconds: seconds.clamp(90, 300));
  }

  /// Re-analyse from the transcript alone (used when the audio was discarded).
  Future<AnalysisResult> analyzeText({
    required String transcript,
    required String apiKey,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw GeminiException('Kein Gemini API-Key hinterlegt.');
    }
    if (transcript.trim().isEmpty) {
      throw GeminiException('Kein Transkript vorhanden.');
    }
    return _generate(apiKey, [
      {'text': '$_promptText$transcript'},
    ]);
  }

  /// On-demand monthly recap from a chronological list of entry summaries.
  Future<String> summarizeMonth({
    required List<String> summaries,
    required String apiKey,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw GeminiException('Kein Gemini API-Key hinterlegt.');
    }
    if (summaries.isEmpty) {
      throw GeminiException('Keine Einträge für diesen Monat.');
    }
    final body = summaries.map((s) => '- $s').join('\n');
    final data = await _generateJson(
      apiKey,
      [
        {'text': '$_promptMonthReview$body'},
      ],
      _reviewSchema,
    );
    final review = (data['review'] as String?)?.trim() ?? '';
    if (review.isEmpty) {
      throw GeminiException('Gemini lieferte keinen Rückblick.');
    }
    return review;
  }

  Future<AnalysisResult> _generate(
    String apiKey,
    List<Map<String, Object>> parts, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final data = await _generateJson(apiKey, parts, _responseSchema,
        timeout: timeout);
    return _toAnalysisResult(data);
  }

  /// The model that produced the most recent successful response — may be a
  /// fallback rather than [kGeminiModel], so it is what gets recorded on the
  /// entry.
  String lastUsedModel = kGeminiModel;

  /// Walks [kGeminiModels] in order until one answers. Only quota/availability
  /// failures fall through; a real error (bad key, malformed request) stops
  /// immediately, since retrying it on another model would fail the same way.
  Future<Map<String, dynamic>> _generateJson(
    String apiKey,
    List<Map<String, Object>> parts,
    Map<String, Object> schema, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    GeminiException? lastError;
    for (final model in kGeminiModels) {
      try {
        final data = await _generateJsonWith(model, apiKey, parts, schema,
            timeout: timeout);
        lastUsedModel = model;
        return data;
      } on _GeminiRetryable catch (e) {
        lastError = GeminiException(e.message);
      }
    }
    throw lastError ?? GeminiException('Kein Gemini-Modell verfügbar.');
  }

  Future<Map<String, dynamic>> _generateJsonWith(
    String model,
    String apiKey,
    List<Map<String, Object>> parts,
    Map<String, Object> schema, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final uri = Uri.parse('$_endpoint/$model:generateContent?key=$apiKey');

    final body = jsonEncode({
      'contents': [
        {'parts': parts},
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'responseSchema': schema,
        'temperature': 0.4,
      },
    });

    late final http.Response res;
    try {
      res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(timeout);
    } on TimeoutException {
      throw GeminiException('Zeitüberschreitung bei der Gemini-Anfrage.');
    } catch (e) {
      throw GeminiException('Netzwerkfehler: ${_redactApiKey(e.toString())}');
    }

    if (res.statusCode != 200) {
      final message = _errorFrom(res);
      // 429 = quota exhausted, 503 = model overloaded, 404 = the model is
      // unknown to this key/API version. All three are worth retrying on the
      // next model in the chain; a 400 (bad key, malformed request) is not —
      // it would just re-upload the whole recording to fail the same way.
      if (const [404, 429, 503].contains(res.statusCode)) {
        throw _GeminiRetryable(message);
      }
      throw GeminiException(message);
    }

    return _extractJson(res.body);
  }

  /// Network exceptions from the http package stringify the request URI,
  /// which includes the API key as a query param — strip it before the
  /// message is ever shown in the UI or persisted to an entry.
  String _redactApiKey(String message) =>
      message.replaceAll(RegExp(r'key=[^&\s]+'), 'key=REDACTED');

  String _errorFrom(http.Response res) {
    try {
      final msg = (jsonDecode(res.body) as Map)['error']?['message'];
      if (msg is String && msg.isNotEmpty) return 'Gemini: $msg';
    } catch (_) {}
    return 'Gemini-Fehler (HTTP ${res.statusCode}).';
  }

  Map<String, dynamic> _extractJson(String responseBody) {
    try {
      final root = jsonDecode(responseBody) as Map<String, dynamic>;
      final candidates = root['candidates'] as List<dynamic>?;
      if (candidates == null || candidates.isEmpty) {
        throw GeminiException('Leere Antwort von Gemini.');
      }
      final parts = (candidates.first as Map)['content']?['parts'] as List?;
      final text = parts?.first?['text'] as String?;
      if (text == null || text.isEmpty) {
        throw GeminiException('Gemini lieferte keinen Inhalt.');
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } on GeminiException {
      rethrow;
    } catch (e) {
      throw GeminiException('Antwort konnte nicht gelesen werden: $e');
    }
  }

  AnalysisResult _toAnalysisResult(Map<String, dynamic> data) {
    final rawDims = (data['dimensions'] as Map?) ?? {};
    return AnalysisResult(
      transcript: (data['transcript'] as String?)?.trim() ?? '',
      summary: (data['summary'] as String?)?.trim() ?? '',
      moodLabel: (data['moodLabel'] as String?)?.trim() ?? '',
      moodScore: ((data['moodScore'] as num?)?.toDouble() ?? 5.0)
          .clamp(0.0, 10.0),
      dimensions: {
        for (final d in kMoodDimensions)
          d: ((rawDims[d] as num?)?.toInt() ?? 50).clamp(0, 100),
      },
      tags: (data['tags'] as List<dynamic>?)
              ?.map((t) => t.toString())
              .where((t) => t.isNotEmpty)
              .toList() ??
          const [],
    );
  }
}
