import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/domain/analysis_basis.dart';
import 'package:mars_log/domain/journal_entry.dart';

/// Where the analysis runs — Settings → Analyse. Transcription is Whisper on
/// the phone in every case.
enum AnalysisProvider {
  device('Gemma (auf dem Handy)'),
  gemini('Gemini 3.8 Flash'),
  mistral('Mistral Large 3');

  final String label;
  const AnalysisProvider(this.label);

  static AnalysisProvider byName(String? name) =>
      values.firstWhere((p) => p.name == name, orElse: () => device);
}

class CloudException implements Exception {
  final String message;

  /// No connection (offline, timeout) — worth falling back to the on-device
  /// model rather than failing the entry. A rejected key is not.
  final bool network;
  CloudException(this.message, {this.network = false});
  @override
  String toString() => message;
}

/// Analysis by a cloud model — **text only**. Transcription stays with
/// Whisper on the phone ([transcriber]); the recording never leaves the
/// device, only the transcript goes to the provider.
///
/// Prompts, schema and parsing are shared; a provider only says how to send
/// a prompt and read the JSON answer ([request]).
abstract class CloudTextEngine implements AnalysisEngine {
  final AnalysisEngine transcriber;
  final Future<String?> Function() apiKey;
  final Uri endpoint;

  CloudTextEngine({
    required this.transcriber,
    required this.apiKey,
    required this.endpoint,
  });

  /// The provider's model id.
  String get model;

  /// For messages ("Gemini", "Mistral").
  String get provider;

  @override
  String get modelName => 'whisper-small+$model';

  @override
  String get source => AnalysisSource.cloud;

  /// Sends [prompt] and returns the answer, which [schema] (plain JSON
  /// Schema) constrains. Throws [CloudException].
  Future<Map<String, dynamic>> request(
    String key,
    String prompt,
    Map<String, Object> schema,
  );

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

  static final Map<String, Object> analysisSchema = {
    'type': 'object',
    'properties': {
      'title': {'type': 'string'},
      'summary': {'type': 'string'},
      'moodLabel': {'type': 'string'},
      'moodScore': {'type': 'number'},
      'dimensions': {
        'type': 'object',
        'properties': {
          for (final d in kMoodDimensions) d: {'type': 'integer'},
        },
        'required': kMoodDimensions,
        'additionalProperties': false,
      },
      'tags': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
    'required': ['title', 'summary', 'moodLabel', 'moodScore', 'dimensions', 'tags'],
    'additionalProperties': false,
  };

  static final Map<String, Object> reviewSchema = {
    'type': 'object',
    'properties': {
      'review': {'type': 'string'},
    },
    'required': ['review'],
    'additionalProperties': false,
  };

  @override
  Future<String> transcribe(List<File> audioFiles) => transcriber.transcribe(audioFiles);

  @override
  Future<AnalysisResult> analyzeAudio(List<File> audioFiles) async =>
      analyzeText(await transcribe(audioFiles));

  @override
  Future<AnalysisResult> analyzeText(String transcript) async {
    if (transcript.trim().isEmpty) {
      throw CloudException('Kein Transkript vorhanden.');
    }
    final json = await _generate('$_prompt$transcript', analysisSchema);
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
      throw CloudException('Keine Einträge für diesen Monat.');
    }
    final body = summaries.map((s) => '- $s').join('\n');
    final json = await _generate('$_promptMonth$body', reviewSchema);
    final review = (json['review'] as String?)?.trim() ?? '';
    if (review.isEmpty) throw CloudException('$provider lieferte keinen Rückblick.');
    return review;
  }

  Future<Map<String, dynamic>> _generate(String prompt, Map<String, Object> schema) async {
    final key = (await apiKey())?.trim() ?? '';
    if (key.isEmpty) {
      throw CloudException('Kein $provider-API-Key hinterlegt (Einstellungen → Analyse).');
    }
    // One retry: a connection dropped in a network switch shouldn't fail the
    // entry.
    for (var attempt = 0;; attempt++) {
      try {
        return await request(key, prompt, schema);
      } on CloudException catch (e) {
        if (!e.network || attempt > 0) rethrow;
      }
    }
  }

  /// POSTs [body] to [uri] and returns the decoded response. Network trouble
  /// becomes a [CloudException] with `network: true`.
  Future<Map<String, dynamic>> postJson(
    Uri uri,
    Map<String, String> headers,
    Object body,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      headers.forEach(req.headers.set);
      req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close().timeout(const Duration(seconds: 90));
      final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 90));
      if (res.statusCode != 200) throw CloudException(_errorFrom(res.statusCode, text));
      return jsonDecode(text) as Map<String, dynamic>;
    } on SocketException {
      throw CloudException('Keine Verbindung zu $provider.', network: true);
    } on TimeoutException {
      throw CloudException('Zeitüberschreitung bei der $provider-Anfrage.', network: true);
    } on HttpException {
      throw CloudException('Verbindung zu $provider abgebrochen.', network: true);
    } on FormatException {
      throw CloudException('Antwort von $provider konnte nicht gelesen werden.');
    } finally {
      client.close(force: true);
    }
  }

  /// The model's answer text, itself JSON.
  Map<String, dynamic> decodeAnswer(String? answer) {
    if (answer == null) throw CloudException('$provider lieferte keine Antwort.');
    try {
      return jsonDecode(answer) as Map<String, dynamic>;
    } on FormatException {
      throw CloudException('Antwort von $provider ist kein JSON.');
    }
  }

  String _errorFrom(int status, String body) {
    String? message;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'];
      message = error is Map ? error['message'] as String? : json['message'] as String?;
    } catch (_) {}
    final detail = message == null ? '' : ': $message';
    return switch (status) {
      400 || 401 || 403 => '$provider lehnt die Anfrage ab — API-Key prüfen. ($status$detail)',
      429 => '$provider-Kontingent erschöpft — später erneut versuchen.',
      _ => '$provider-Fehler $status$detail',
    };
  }
}

/// Gemini through the Gemini API (Google). Meant for the paid tier: there
/// prompts aren't used for training; the free tier has that protection only
/// inside the EU/EEA/UK/Switzerland.
class GeminiTextEngine extends CloudTextEngine {
  GeminiTextEngine({required super.transcriber, required super.apiKey, Uri? endpoint})
      : super(endpoint: endpoint ?? Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/'));

  @override
  String get model => 'gemini-3.8-flash';

  @override
  String get provider => 'Gemini';

  @override
  Future<Map<String, dynamic>> request(
    String key,
    String prompt,
    Map<String, Object> schema,
  ) async {
    final data = await postJson(
      // Not resolve(): 'gemini-3.8-flash:…' would parse as a URI scheme.
      endpoint.replace(path: '${endpoint.path}$model:generateContent'),
      // In a header, not the URL: URLs end up in logs and error messages.
      {'x-goog-api-key': key},
      {
        'contents': [
          {
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
          'responseSchema': geminiSchema(schema),
          'temperature': 0.4,
          // Thinking tokens are billed as output. A summary, a mood and a few
          // tags don't need deep reasoning; 'low' keeps an entry at a
          // fraction of a cent (the model's default is 'medium').
          'thinkingConfig': {'thinkingLevel': 'low'},
        },
      },
    );
    final candidates = data['candidates'] as List<dynamic>?;
    final parts = ((candidates?.firstOrNull as Map<String, dynamic>?)?['content']
        as Map<String, dynamic>?)?['parts'] as List<dynamic>?;
    return decodeAnswer((parts?.firstOrNull as Map<String, dynamic>?)?['text'] as String?);
  }

  /// Gemini's schema dialect: upper-case types, no `additionalProperties`.
  static Object geminiSchema(Object node) => switch (node) {
        Map() => {
            for (final MapEntry(:key, :value) in node.entries)
              if (key != 'additionalProperties')
                key as String: key == 'type'
                    ? (value as String).toUpperCase()
                    : geminiSchema(value as Object),
          },
        List() => [for (final v in node) geminiSchema(v as Object)],
        _ => node,
      };
}

/// Mistral Large 3 through Mistral's API (Paris; data hosted in the EU by
/// default, kept 30 days for abuse monitoring). Switch off "Anonymous
/// improvement data" in Mistral's admin privacy settings.
class MistralTextEngine extends CloudTextEngine {
  MistralTextEngine({required super.transcriber, required super.apiKey, Uri? endpoint})
      : super(endpoint: endpoint ?? Uri.parse('https://api.mistral.ai/v1/chat/completions'));

  @override
  String get model => 'mistral-large-3-25-12';

  @override
  String get provider => 'Mistral';

  @override
  Future<Map<String, dynamic>> request(
    String key,
    String prompt,
    Map<String, Object> schema,
  ) async {
    final data = await postJson(
      endpoint,
      {'Authorization': 'Bearer $key'},
      {
        'model': model,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
        'temperature': 0.3,
        'response_format': {
          'type': 'json_schema',
          'json_schema': {'name': 'analysis', 'schema': schema, 'strict': true},
        },
      },
    );
    final choices = data['choices'] as List<dynamic>?;
    final message = (choices?.firstOrNull as Map<String, dynamic>?)?['message'] as Map<String, dynamic>?;
    return decodeAnswer(message?['content'] as String?);
  }
}

/// The engine settings chose. Transcription is always the on-device one;
/// without a connection a cloud choice falls back to the on-device model, so
/// an entry recorded offline still gets its (pre-)analysis.
class SelectedAnalysisEngine implements AnalysisEngine {
  final AnalysisEngine onDevice;
  final Map<AnalysisProvider, AnalysisEngine> cloud;
  final AnalysisProvider Function() provider;

  SelectedAnalysisEngine({
    required this.onDevice,
    required this.cloud,
    required this.provider,
  });

  AnalysisEngine get _current => cloud[provider()] ?? onDevice;

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
  Future<AnalysisResult> analyzeText(String transcript) =>
      _withFallback((e) => e.analyzeText(transcript));

  @override
  Future<String> summarizeMonth(List<String> summaries) =>
      _withFallback((e) => e.summarizeMonth(summaries));

  Future<T> _withFallback<T>(Future<T> Function(AnalysisEngine e) run) async {
    final engine = _current;
    if (identical(engine, onDevice)) return run(onDevice);
    try {
      return await run(engine);
    } on CloudException catch (e) {
      if (!e.network) rethrow;
      return run(onDevice);
    }
  }
}
