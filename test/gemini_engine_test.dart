import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/data/gemini_engine.dart';
import 'package:mars_log/domain/analysis_basis.dart';
import 'package:mars_log/domain/journal_entry.dart';

class _Local extends Fake implements AnalysisEngine {
  @override
  String get modelName => 'local';
  @override
  String get source => AnalysisSource.phone;
  @override
  Future<String> transcribe(List<File> audioFiles) async => 'von Whisper';
  @override
  Future<AnalysisResult> analyzeText(String transcript) async => AnalysisResult(
        transcript: transcript,
        summary: 'lokal',
        moodLabel: '',
        moodScore: 5,
        dimensions: const {},
        tags: const [],
        model: modelName,
        source: source,
      );
}

/// Stands in for generativelanguage.googleapis.com.
Future<(HttpServer, List<Map<String, dynamic>>, List<String?>)> _fakeGemini({
  int status = 200,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final bodies = <Map<String, dynamic>>[];
  final keys = <String?>[];
  server.listen((req) async {
    bodies.add(jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>);
    keys.add(req.headers.value('x-goog-api-key'));
    final answer = {
      'title': 'Tag am See',
      'summary': 'Ich war am See.',
      'moodLabel': 'Ruhig',
      'moodScore': 7.5,
      'dimensions': {'calm': 90},
      'tags': ['See'],
    };
    req.response
      ..statusCode = status
      ..write(jsonEncode(status == 200
          ? {
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': jsonEncode(answer)},
                    ],
                  },
                },
              ],
            }
          : {'error': {'message': 'API key not valid'}}));
    await req.response.close();
  });
  return (server, bodies, keys);
}

void main() {
  test('sends only the transcript, with the key in a header, and reads the answer', () async {
    final (server, bodies, keys) = await _fakeGemini();
    addTearDown(server.close);
    final engine = GeminiTextEngine(
      transcriber: _Local(),
      apiKey: () async => 'AIza-test',
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1beta/models/'),
    );

    final r = await engine.analyzeText('Heute am See.');
    expect(r.title, 'Tag am See');
    expect(r.moodScore, 7.5);
    expect(r.dimensions['calm'], 90);
    expect(r.dimensions['stress'], 50, reason: 'missing dimensions default to neutral');
    expect(r.source, AnalysisSource.cloud);
    expect(r.model, contains(kGeminiModel));

    expect(keys.single, 'AIza-test');
    final text = bodies.single['contents'][0]['parts'][0]['text'] as String;
    expect(text, endsWith('Heute am See.'));
    expect(bodies.single['generationConfig']['thinkingConfig'], {'thinkingLevel': 'low'});
  });

  test('a rejected key fails the entry instead of falling back', () async {
    final (server, _, _) = await _fakeGemini(status: 400);
    addTearDown(server.close);
    final selected = SelectedAnalysisEngine(
      onDevice: _Local(),
      cloud: GeminiTextEngine(
        transcriber: _Local(),
        apiKey: () async => 'falsch',
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1beta/models/'),
      ),
      useCloud: () => true,
    );
    await expectLater(selected.analyzeText('x'), throwsA(isA<GeminiException>()));
  });

  test('without a connection the on-device model analyses', () async {
    // Nothing listens on this port.
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = free.port;
    await free.close();
    final selected = SelectedAnalysisEngine(
      onDevice: _Local(),
      cloud: GeminiTextEngine(
        transcriber: _Local(),
        apiKey: () async => 'AIza-test',
        endpoint: Uri.parse('http://127.0.0.1:$port/v1beta/models/'),
      ),
      useCloud: () => true,
    );
    final r = await selected.analyzeText('x');
    expect(r.summary, 'lokal');
    expect(r.source, AnalysisSource.phone, reason: 'recorded as what it is');
  });

  test('no key: a clear message, no request', () async {
    final engine = GeminiTextEngine(transcriber: _Local(), apiKey: () async => null);
    await expectLater(
      engine.analyzeText('x'),
      throwsA(predicate((e) => e.toString().contains('API-Key'))),
    );
  });
}
