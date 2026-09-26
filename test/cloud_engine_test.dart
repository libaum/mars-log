import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/data/cloud_engine.dart';
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

const _answer = {
  'title': 'Tag am See',
  'summary': 'Ich war am See.',
  'moodLabel': 'Ruhig',
  'moodScore': 7.5,
  'dimensions': {'calm': 90},
  'tags': ['See'],
};

/// A provider stand-in: records requests, answers with [reply] or [status].
class _FakeServer {
  late final HttpServer server;
  final requests = <({String path, Map<String, String> headers, Map<String, dynamic> body})>[];
  final Object Function() reply;
  final int status;
  _FakeServer(this.reply, {this.status = 200});

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final headers = <String, String>{};
      req.headers.forEach((k, v) => headers[k] = v.join(','));
      requests.add((
        path: req.uri.path,
        headers: headers,
        body: jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>,
      ));
      req.response
        ..statusCode = status
        ..write(jsonEncode(status == 200 ? reply() : {'error': {'message': 'invalid key'}}));
      await req.response.close();
    });
  }

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
}

Object _geminiReply() => {
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': jsonEncode(_answer)},
            ],
          },
        },
      ],
    };

Object _mistralReply() => {
      'choices': [
        {
          'message': {'role': 'assistant', 'content': jsonEncode(_answer)},
        },
      ],
    };

void expectAnswer(AnalysisResult r, String model) {
  expect(r.title, 'Tag am See');
  expect(r.moodScore, 7.5);
  expect(r.dimensions['calm'], 90);
  expect(r.dimensions['stress'], 50, reason: 'missing dimensions default to neutral');
  expect(r.source, AnalysisSource.cloud);
  expect(r.model, contains(model));
}

void main() {
  test('Gemini: only the transcript, key in a header, low thinking, its schema dialect',
      () async {
    final fake = _FakeServer(_geminiReply);
    await fake.start();
    addTearDown(fake.server.close);
    final engine = GeminiTextEngine(
      transcriber: _Local(),
      apiKey: () async => 'AIza-test',
      endpoint: fake.uri('/v1beta/models/'),
    );

    expectAnswer(await engine.analyzeText('Heute am See.'), 'gemini-3.8-flash');

    final req = fake.requests.single;
    expect(req.path, '/v1beta/models/gemini-3.8-flash:generateContent');
    expect(req.headers['x-goog-api-key'], 'AIza-test');
    expect(req.body['contents'][0]['parts'][0]['text'], endsWith('Heute am See.'));
    final config = req.body['generationConfig'] as Map<String, dynamic>;
    expect(config['thinkingConfig'], {'thinkingLevel': 'low'});
    expect(config['responseSchema']['type'], 'OBJECT');
    expect(jsonEncode(config['responseSchema']), isNot(contains('additionalProperties')));
  });

  test('Mistral: bearer key, model id, strict JSON schema', () async {
    final fake = _FakeServer(_mistralReply);
    await fake.start();
    addTearDown(fake.server.close);
    final engine = MistralTextEngine(
      transcriber: _Local(),
      apiKey: () async => 'mistral-test',
      endpoint: fake.uri('/v1/chat/completions'),
    );

    expectAnswer(await engine.analyzeText('Heute am See.'), 'mistral-large-2512');

    final req = fake.requests.single;
    expect(req.headers['authorization'], 'Bearer mistral-test');
    expect(req.body['model'], 'mistral-large-2512');
    expect(req.body['messages'][0]['content'], endsWith('Heute am See.'));
    final format = req.body['response_format'] as Map<String, dynamic>;
    expect(format['type'], 'json_schema');
    expect(format['json_schema']['strict'], isTrue);
  });

  test('a rejected key fails the entry instead of falling back', () async {
    final fake = _FakeServer(_mistralReply, status: 401);
    await fake.start();
    addTearDown(fake.server.close);
    final selected = SelectedAnalysisEngine(
      onDevice: _Local(),
      cloud: {
        AnalysisProvider.mistral: MistralTextEngine(
          transcriber: _Local(),
          apiKey: () async => 'falsch',
          endpoint: fake.uri('/v1/chat/completions'),
        ),
      },
      provider: () => AnalysisProvider.mistral,
    );
    await expectLater(
      selected.analyzeText('x'),
      throwsA(isA<CloudException>().having((e) => e.message, 'message', contains('API-Key'))),
    );
  });

  test('without a connection the on-device model analyses', () async {
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = free.port;
    await free.close(); // nothing listens there now
    final selected = SelectedAnalysisEngine(
      onDevice: _Local(),
      cloud: {
        AnalysisProvider.gemini: GeminiTextEngine(
          transcriber: _Local(),
          apiKey: () async => 'AIza-test',
          endpoint: Uri.parse('http://127.0.0.1:$port/v1beta/models/'),
        ),
      },
      provider: () => AnalysisProvider.gemini,
    );
    final r = await selected.analyzeText('x');
    expect(r.summary, 'lokal');
    expect(r.source, AnalysisSource.phone, reason: 'recorded as what it is');
  });

  test('no key: a clear message', () async {
    final engine = MistralTextEngine(transcriber: _Local(), apiKey: () async => null);
    await expectLater(
      engine.analyzeText('x'),
      throwsA(predicate((e) => e.toString().contains('Mistral-API-Key'))),
    );
  });

  test('the device choice and unknown names use the on-device model', () {
    expect(AnalysisProvider.byName(null), AnalysisProvider.device);
    expect(AnalysisProvider.byName('cloud'), AnalysisProvider.device,
        reason: 'the old audio-to-Gemini value must not switch a provider on');
  });
}
