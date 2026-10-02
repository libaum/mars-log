import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/domain/analysis_basis.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/people_aliases.dart';

/// The model ids used unless another one is set in Settings.
const kDefaultTranscriptionModel = 'gemini-3.8-flash';
const kDefaultAnalysisModel = 'gemini-3.8-flash';

/// Everything through the Gemini API (Google), paid tier: there prompts and
/// audio aren't used for training. The recording goes up for transcription,
/// the transcript for the analysis; the audio stays on the phone as well.
///
/// Three separate calls, each with only what it needs: [transcribe] (audio),
/// [analyzeText] (transcript), [extractPeople] (transcript + the names
/// already known). None of them ever sees the entry itself.
class GeminiEngine implements AnalysisEngine {
  final Future<String?> Function() apiKey;
  final String Function() transcriptionModelId;
  final String Function() analysisModelId;
  final Uri base;

  /// Above this, audio goes up through the Files API instead of inline —
  /// a request may carry at most 20 MB, and base64 adds a third.
  final int inlineLimitBytes;

  GeminiEngine({
    required this.apiKey,
    required this.transcriptionModelId,
    required this.analysisModelId,
    Uri? base,
    this.inlineLimitBytes = 14 * 1024 * 1024,
  }) : base = base ?? Uri.parse('https://generativelanguage.googleapis.com/');

  @override
  String get transcriptionModel => transcriptionModelId();

  @override
  String get modelName => analysisModelId();

  @override
  String get source => AnalysisSource.cloud;

  // ── Prompts ───────────────────────────────────────────────────────────────

  static const _promptTranscribe = '''
Transkribiere diese Sprachaufnahme wörtlich. Es ist ein gesprochener
Tagebucheintrag, meist auf Deutsch, mit gelegentlichen englischen Wörtern.
Gib nur den gesprochenen Text zurück: keine Überschrift, keine Zeitstempel,
keine Sprecherangaben, keine Kommentare. Setze Satzzeichen und Absätze, wo
sie beim Sprechen hörbar sind. Füllwörter wie "äh" darfst du weglassen.
Erfinde nichts dazu: Ist eine Stelle unverständlich, lass sie aus. Ist
nichts zu verstehen, gib einen leeren Text zurück.''';

  static const _promptAnalysis = '''
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
      },
      'tags': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
    'required': ['title', 'summary', 'moodLabel', 'moodScore', 'dimensions', 'tags'],
  };

  static final Map<String, Object> peopleSchema = {
    'type': 'object',
    'properties': {
      'people': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'person': {'type': 'string'},
            'mention': {'type': 'string'},
            'isNew': {'type': 'boolean'},
          },
          'required': ['person', 'mention', 'isNew'],
        },
      },
    },
    'required': ['people'],
  };

  static final Map<String, Object> reviewSchema = {
    'type': 'object',
    'properties': {
      'review': {'type': 'string'},
    },
    'required': ['review'],
  };

  // ── The three calls ───────────────────────────────────────────────────────

  @override
  Future<String> transcribe(List<File> audioFiles) async {
    final key = await _key();
    final model = transcriptionModel;
    // One call per recording: an entry's later recordings ("Weitere
    // Aufnahme") are transcribed alone anyway, and each call stays short.
    final parts = <String>[];
    for (final file in audioFiles) {
      final text = await _transcribeOne(key, model, file);
      if (text.isNotEmpty) parts.add(text);
    }
    final transcript = parts.join('\n\n');
    if (transcript.trim().isEmpty) {
      throw AnalysisException('In der Aufnahme wurde nichts erkannt.');
    }
    return transcript;
  }

  Future<String> _transcribeOne(String key, String model, File file) async {
    final mime = audioMimeType(file.path);
    final size = await file.length();
    String? uploaded;
    try {
      final Map<String, Object> audio;
      if (size <= inlineLimitBytes) {
        audio = {
          'inline_data': {'mime_type': mime, 'data': base64Encode(await file.readAsBytes())},
        };
      } else {
        final (:name, :uri) = await _upload(key, file, mime, size);
        uploaded = name;
        audio = {
          'file_data': {'mime_type': mime, 'file_uri': uri},
        };
      }
      final data = await _generateContent(
        key,
        model,
        [
          {'text': _promptTranscribe},
          audio,
        ],
        {
          'temperature': 0,
          // A long recording is a long answer; the default cap would cut it.
          'maxOutputTokens': 65536,
          'thinkingConfig': {'thinkingLevel': 'low'},
        },
        // Long audio takes a while to transcribe.
        timeout: const Duration(minutes: 10),
      );
      return _answerText(data).trim();
    } finally {
      // Google deletes uploads after 48 h by itself; no reason to wait.
      if (uploaded != null) unawaited(_deleteFile(key, uploaded));
    }
  }

  @override
  Future<AnalysisResult> analyzeText(String transcript) async {
    if (transcript.trim().isEmpty) {
      throw AnalysisException('Kein Transkript vorhanden.');
    }
    final json = await _generateJson('$_promptAnalysis$transcript', analysisSchema);
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
  Future<PeopleResult> extractPeople(String transcript, List<KnownPerson> known) async {
    if (transcript.trim().isEmpty) {
      throw AnalysisException('Kein Transkript vorhanden.');
    }
    final json = await _generateJson(peoplePrompt(transcript, known), peopleSchema);
    return PeopleResult(
      [
        for (final p in (json['people'] as List<dynamic>? ?? const []))
          if (p is Map<String, dynamic>)
            PersonMention(
              person: (p['person'] as String? ?? '').trim(),
              mention: (p['mention'] as String? ?? '').trim(),
              isNew: p['isNew'] as bool? ?? true,
            ),
      ],
      model: modelName,
    );
  }

  /// The prompt of [extractPeople] — public for tests.
  static String peoplePrompt(String transcript, List<KnownPerson> known) {
    final list = known.isEmpty
        ? '(noch niemand)'
        : known
            .map((p) => p.aliases.isEmpty
                ? '- ${p.name}'
                : '- ${p.name} (auch: ${p.aliases.join(', ')})')
            .join('\n');
    return '''
Du bist der Assistent einer Sprach-Tagebuch-App. Unten steht ein
transkribierter, gesprochener Tagebucheintrag (kann Hörfehler enthalten).
Finde die Menschen, die darin vorkommen. Antworte ausschließlich mit dem
geforderten JSON.

$kPeoplePromptRule

Bekannte Personen (Name, in Klammern andere Schreibweisen oder Bezeichnungen,
unter denen sie schon vorkamen):
$list

Für jede Person im Eintrag:
- mention: wie sie im Text genannt wird, als Name ohne Artikel oder
  Possessiv ("mein Bruder" → "Bruder", "die Lena" → "Lena").
- person: Ist sie eine der bekannten Personen, genau deren Name aus der
  Liste (vor der Klammer). Sonst ein Name für die neue Person, so wie sie
  genannt wird.
- isNew: false, wenn sie eine bekannte Person ist; true sonst. Ordne nur
  zu, wenn es aus dem Text klar hervorgeht oder die Schreibweise passt (auch
  ein offensichtlicher Hörfehler wie "Wincent" für "Vincent") — im Zweifel
  ist sie neu.

Leere Liste, wenn niemand vorkommt.

Transkript:
$transcript''';
  }

  @override
  Future<String> summarizeMonth(List<String> summaries) async {
    if (summaries.isEmpty) {
      throw AnalysisException('Keine Einträge für diesen Monat.');
    }
    final body = summaries.map((s) => '- $s').join('\n');
    final json = await _generateJson('$_promptMonth$body', reviewSchema);
    final review = (json['review'] as String?)?.trim() ?? '';
    if (review.isEmpty) throw AnalysisException('Gemini lieferte keinen Rückblick.');
    return review;
  }

  // ── Plumbing ──────────────────────────────────────────────────────────────

  Future<String> _key() async {
    final key = (await apiKey())?.trim() ?? '';
    if (key.isEmpty) {
      throw AnalysisException('Kein Gemini-API-Key hinterlegt (Einstellungen → Gemini API-Key).');
    }
    return key;
  }

  Future<Map<String, dynamic>> _generateJson(String prompt, Map<String, Object> schema) async {
    final data = await _generateContent(
      await _key(),
      modelName,
      [
        {'text': prompt},
      ],
      {
        'responseMimeType': 'application/json',
        'responseSchema': geminiSchema(schema),
        'temperature': 0.4,
        // Thinking tokens are billed as output. A summary, a mood and a few
        // tags don't need deep reasoning.
        'thinkingConfig': {'thinkingLevel': 'low'},
      },
    );
    final answer = _answerText(data);
    try {
      return jsonDecode(answer) as Map<String, dynamic>;
    } on FormatException {
      throw AnalysisException('Antwort von Gemini ist kein JSON.');
    }
  }

  Future<Map<String, dynamic>> _generateContent(
    String key,
    String model,
    List<Map<String, Object>> parts,
    Map<String, Object> config, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    // One quick retry: a connection dropped in a network switch shouldn't
    // park the entry for half a minute. Longer waits are JournalManager's.
    for (var attempt = 0;; attempt++) {
      try {
        final res = await _send(
          'POST',
          // Not resolve(): 'gemini-3.8-flash:…' would parse as a URI scheme.
          base.replace(path: '${base.path}v1beta/models/$model:generateContent'),
          {'x-goog-api-key': key},
          utf8.encode(jsonEncode({
            'contents': [
              {'parts': parts},
            ],
            'generationConfig': config,
          })),
          timeout: timeout,
          model: model,
        );
        return jsonDecode(res.body) as Map<String, dynamic>;
      } on AnalysisException catch (e) {
        if (!e.offline || attempt > 0) rethrow;
      } on FormatException {
        throw AnalysisException('Antwort von Gemini konnte nicht gelesen werden.');
      }
    }
  }

  /// The text of the first candidate. A cut-off or blocked answer is an
  /// error, not a short transcript: an entry must never quietly lose its end.
  String _answerText(Map<String, dynamic> data) {
    final candidate = (data['candidates'] as List<dynamic>?)?.firstOrNull as Map<String, dynamic>?;
    if (candidate == null) {
      final reason = (data['promptFeedback'] as Map<String, dynamic>?)?['blockReason'];
      throw AnalysisException('Gemini lieferte keine Antwort${reason == null ? '' : ' ($reason)'}.');
    }
    final finish = candidate['finishReason'] as String?;
    if (finish == 'MAX_TOKENS') {
      throw AnalysisException('Gemini hat die Antwort abgeschnitten (zu lang).');
    }
    if (finish != null && finish != 'STOP') {
      throw AnalysisException('Gemini hat abgebrochen ($finish).');
    }
    final parts = (candidate['content'] as Map<String, dynamic>?)?['parts'] as List<dynamic>?;
    // With thinking on, thought summaries may come first; the answer is the
    // text that isn't one.
    return [
      for (final p in parts ?? const [])
        if (p is Map<String, dynamic> && p['thought'] != true && p['text'] is String)
          p['text'] as String,
    ].join();
  }

  /// Resumable upload to the Files API, then wait until it is usable.
  Future<({String name, String uri})> _upload(
    String key,
    File file,
    String mime,
    int size,
  ) async {
    final start = await _send(
      'POST',
      base.replace(path: '${base.path}upload/v1beta/files'),
      {
        'x-goog-api-key': key,
        'X-Goog-Upload-Protocol': 'resumable',
        'X-Goog-Upload-Command': 'start',
        'X-Goog-Upload-Header-Content-Length': '$size',
        'X-Goog-Upload-Header-Content-Type': mime,
      },
      utf8.encode(jsonEncode({
        'file': {'display_name': 'mars-log-audio'},
      })),
    );
    final url = start.headers['x-goog-upload-url'];
    if (url == null) throw AnalysisException('Gemini nahm den Upload nicht an.');
    final done = await _send(
      'POST',
      Uri.parse(url),
      {
        'x-goog-api-key': key,
        'X-Goog-Upload-Offset': '0',
        'X-Goog-Upload-Command': 'upload, finalize',
      },
      await file.readAsBytes(),
      timeout: const Duration(minutes: 5),
    );
    var info = (jsonDecode(done.body) as Map<String, dynamic>)['file'] as Map<String, dynamic>;
    final name = info['name'] as String;
    // Audio is usually ACTIVE at once; give it a minute before giving up.
    for (var i = 0; info['state'] == 'PROCESSING' && i < 30; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final res = await _send('GET', base.replace(path: '${base.path}v1beta/$name'), {'x-goog-api-key': key}, null);
      info = jsonDecode(res.body) as Map<String, dynamic>;
    }
    if (info['state'] != 'ACTIVE') {
      throw AnalysisException('Gemini konnte die Aufnahme nicht verarbeiten (${info['state']}).',
          transient: info['state'] == 'PROCESSING');
    }
    return (name: name, uri: info['uri'] as String);
  }

  Future<void> _deleteFile(String key, String name) async {
    try {
      await _send('DELETE', base.replace(path: '${base.path}v1beta/$name'), {'x-goog-api-key': key}, null);
    } catch (_) {
      // Expires by itself.
    }
  }

  /// One HTTP request. Network trouble becomes an [AnalysisException] that
  /// is `offline`; rate limits and server errors are `transient`.
  Future<({String body, Map<String, String> headers})> _send(
    String method,
    Uri uri,
    Map<String, String> headers,
    List<int>? body, {
    Duration timeout = const Duration(seconds: 90),
    String? model,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.openUrl(method, uri);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.contentLength = body.length;
      }
      // In a header, not the URL: URLs end up in logs and error messages.
      headers.forEach(req.headers.set);
      if (body != null) req.add(body);
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      if (res.statusCode != 200) {
        throw AnalysisException(
          _errorFrom(res.statusCode, text, model ?? modelName),
          transient: res.statusCode == 429 || res.statusCode >= 500,
        );
      }
      final out = <String, String>{};
      res.headers.forEach((k, v) => out[k.toLowerCase()] = v.join(','));
      return (body: text, headers: out);
    } on SocketException {
      throw AnalysisException('Wartet auf Netz.', transient: true, offline: true);
    } on TimeoutException {
      throw AnalysisException('Zeitüberschreitung bei Gemini.', transient: true, offline: true);
    } on HttpException {
      throw AnalysisException('Verbindung zu Gemini abgebrochen.', transient: true, offline: true);
    } finally {
      client.close(force: true);
    }
  }

  static String _errorFrom(int status, String body, String model) {
    String? message;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'];
      message = error is Map ? error['message'] as String? : json['message'] as String?;
    } catch (_) {}
    final detail = message == null ? '' : ': $message';
    return switch (status) {
      401 => 'Gemini kennt diesen API-Key nicht — Key prüfen. ($status$detail)',
      // A valid key without access to this model (e.g. a free plan).
      403 => 'Gemini: Modell $model ist für dieses Konto nicht freigeschaltet. ($status$detail)',
      400 => 'Gemini lehnt die Anfrage ab. ($status$detail)',
      404 => 'Gemini kennt das Modell $model nicht. ($status$detail)',
      429 => 'Gemini-Kontingent erschöpft — neuer Versuch später.',
      _ => 'Gemini-Fehler $status$detail',
    };
  }

  /// The MIME type Gemini expects for a recording, by file extension.
  static String audioMimeType(String path) => switch (path.split('.').last.toLowerCase()) {
        'm4a' || 'mp4' => 'audio/mp4',
        'aac' => 'audio/aac',
        'wav' => 'audio/wav',
        'mp3' => 'audio/mp3',
        'ogg' => 'audio/ogg',
        'flac' => 'audio/flac',
        _ => 'audio/mp4',
      };

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
