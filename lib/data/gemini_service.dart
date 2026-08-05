import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:mars_log/domain/journal_entry.dart';

/// Bump when the prompt or schema changes, so entries can be re-analysed later.
const kAnalysisVersion = 1;
const kGeminiModel = 'gemini-2.5-flash';

class GeminiException implements Exception {
  final String message;
  GeminiException(this.message);
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

  /// Analyse [audioFile]. [apiKey] must be a valid Generative Language API key.
  Future<AnalysisResult> analyze({
    required File audioFile,
    required String apiKey,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw GeminiException('Kein Gemini API-Key hinterlegt.');
    }
    if (!await audioFile.exists()) {
      throw GeminiException('Audiodatei nicht gefunden.');
    }

    final bytes = await audioFile.readAsBytes();
    return _generate(apiKey, [
      {'text': _prompt},
      {
        'inline_data': {
          'mime_type': 'audio/wav',
          'data': base64Encode(bytes),
        },
      },
    ]);
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

  Future<AnalysisResult> _generate(
    String apiKey,
    List<Map<String, Object>> parts,
  ) async {
    final uri = Uri.parse('$_endpoint/$kGeminiModel:generateContent?key=$apiKey');

    final body = jsonEncode({
      'contents': [
        {'parts': parts},
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'responseSchema': _responseSchema,
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
          .timeout(const Duration(seconds: 90));
    } on TimeoutException {
      throw GeminiException('Zeitüberschreitung bei der Gemini-Anfrage.');
    } catch (e) {
      throw GeminiException('Netzwerkfehler: $e');
    }

    if (res.statusCode != 200) {
      throw GeminiException(_errorFrom(res));
    }

    return _parse(res.body);
  }

  String _errorFrom(http.Response res) {
    try {
      final msg = (jsonDecode(res.body) as Map)['error']?['message'];
      if (msg is String && msg.isNotEmpty) return 'Gemini: $msg';
    } catch (_) {}
    return 'Gemini-Fehler (HTTP ${res.statusCode}).';
  }

  AnalysisResult _parse(String responseBody) {
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

      final data = jsonDecode(text) as Map<String, dynamic>;
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
    } on GeminiException {
      rethrow;
    } catch (e) {
      throw GeminiException('Antwort konnte nicht gelesen werden: $e');
    }
  }
}
