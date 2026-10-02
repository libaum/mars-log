import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/data/gemini_engine.dart';
import 'package:mars_log/domain/analysis_basis.dart';
import 'package:mars_log/domain/people_aliases.dart';

typedef _Request = ({String method, String path, Map<String, String> headers, List<int> body});

/// The Gemini API's stand-in: records requests, answers via [handle].
class _FakeServer {
  late final HttpServer server;
  final requests = <_Request>[];
  final void Function(HttpRequest req, _Request r) handle;
  _FakeServer(this.handle);

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final headers = <String, String>{};
      req.headers.forEach((k, v) => headers[k] = v.join(','));
      final body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      final r = (method: req.method, path: req.uri.path, headers: headers, body: body);
      requests.add(r);
      handle(req, r);
      await req.response.close();
    });
  }

  Uri get base => Uri.parse('http://127.0.0.1:${server.port}/');

  Map<String, dynamic> json(int i) =>
      jsonDecode(utf8.decode(requests[i].body)) as Map<String, dynamic>;
}

Map<String, Object> _reply(String text, {String finish = 'STOP'}) => {
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': text},
            ],
          },
          'finishReason': finish,
        },
      ],
    };

void _answer(HttpRequest req, Object body, {int status = 200}) {
  req.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
}

const _analysis = {
  'title': 'Tag am See',
  'summary': 'Ich war am See.',
  'moodLabel': 'Ruhig',
  'moodScore': 7.5,
  'dimensions': {'calm': 90},
  'tags': ['See'],
};

GeminiEngine _engine(_FakeServer fake, {int inlineLimit = 1 << 20}) => GeminiEngine(
      apiKey: () async => 'AIza-test',
      transcriptionModelId: () => 'stt-model',
      analysisModelId: () => 'text-model',
      base: fake.base,
      inlineLimitBytes: inlineLimit,
    );

Future<File> _audio(Directory dir, String name, int bytes) async =>
    File('${dir.path}/$name')..writeAsBytesSync(List.filled(bytes, 7));

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('gemini_test_'));
  tearDown(() => tmp.delete(recursive: true));

  test('transcription: the audio inline, with the transcription model and the key in a header',
      () async {
    final fake = _FakeServer((req, _) => _answer(req, _reply('Heute war ich am See.')));
    await fake.start();
    addTearDown(fake.server.close);
    final audio = await _audio(tmp, '1.m4a', 1000);

    expect(await _engine(fake).transcribe([audio]), 'Heute war ich am See.');

    final req = fake.requests.single;
    expect(req.path, '/v1beta/models/stt-model:generateContent');
    expect(req.headers['x-goog-api-key'], 'AIza-test');
    final parts = fake.json(0)['contents'][0]['parts'] as List<dynamic>;
    expect(parts[1]['inline_data']['mime_type'], 'audio/mp4');
    expect(base64Decode(parts[1]['inline_data']['data'] as String), audio.readAsBytesSync());
  });

  test('several recordings: one call each, joined in order', () async {
    var n = 0;
    final fake = _FakeServer((req, _) => _answer(req, _reply('Teil ${++n}')));
    await fake.start();
    addTearDown(fake.server.close);
    final text = await _engine(fake)
        .transcribe([await _audio(tmp, '1.m4a', 10), await _audio(tmp, '2.m4a', 10)]);
    expect(text, 'Teil 1\n\nTeil 2');
    expect(fake.requests, hasLength(2));
  });

  test('a long recording goes up through the Files API and is deleted afterwards', () async {
    final fake = _FakeServer((req, r) {
      if (r.path == '/upload/v1beta/files') {
        req.response.headers.set('x-goog-upload-url', 'http://127.0.0.1:${req.connectionInfo!.localPort}/upload-session');
        _answer(req, const {});
      } else if (r.path == '/upload-session') {
        _answer(req, {
          'file': {'name': 'files/abc', 'uri': 'https://files/abc', 'state': 'ACTIVE'},
        });
      } else if (r.method == 'DELETE') {
        _answer(req, const {});
      } else {
        _answer(req, _reply('Ein langer Eintrag.'));
      }
    });
    await fake.start();
    addTearDown(fake.server.close);
    final audio = await _audio(tmp, '1.m4a', 5000);

    expect(await _engine(fake, inlineLimit: 1000).transcribe([audio]), 'Ein langer Eintrag.');
    await Future<void>.delayed(const Duration(milliseconds: 50)); // the delete

    final paths = fake.requests.map((r) => '${r.method} ${r.path}').toList();
    expect(paths, [
      'POST /upload/v1beta/files',
      'POST /upload-session',
      'POST /v1beta/models/stt-model:generateContent',
      'DELETE /v1beta/files/abc',
    ]);
    expect(fake.requests[1].body, audio.readAsBytesSync());
    final parts = fake.json(2)['contents'][0]['parts'] as List<dynamic>;
    expect(parts[1]['file_data']['file_uri'], 'https://files/abc');
  });

  test('a cut-off transcript is an error, never a short entry', () async {
    final fake = _FakeServer((req, _) => _answer(req, _reply('Heute', finish: 'MAX_TOKENS')));
    await fake.start();
    addTearDown(fake.server.close);
    await expectLater(
      _engine(fake).transcribe([await _audio(tmp, '1.m4a', 10)]),
      throwsA(isA<AnalysisException>().having((e) => e.transient, 'transient', isFalse)),
    );
  });

  test('analysis: only the transcript, the analysis model, low thinking, its schema dialect',
      () async {
    final fake = _FakeServer((req, _) => _answer(req, _reply(jsonEncode(_analysis))));
    await fake.start();
    addTearDown(fake.server.close);

    final r = await _engine(fake).analyzeText('Heute am See.');
    expect(r.title, 'Tag am See');
    expect(r.moodScore, 7.5);
    expect(r.dimensions['stress'], 50, reason: 'missing dimensions default to neutral');
    expect(r.model, 'text-model');
    expect(r.source, AnalysisSource.cloud);

    final req = fake.requests.single;
    expect(req.path, '/v1beta/models/text-model:generateContent');
    final body = fake.json(0);
    expect(body['contents'][0]['parts'], hasLength(1));
    expect(body['contents'][0]['parts'][0]['text'], endsWith('Heute am See.'));
    final config = body['generationConfig'] as Map<String, dynamic>;
    expect(config['thinkingConfig'], {'thinkingLevel': 'low'});
    expect(config['responseSchema']['type'], 'OBJECT');
    expect(jsonEncode(config['responseSchema']), isNot(contains('people')),
        reason: 'people are their own call');
  });

  test('people: their own call, with the known people and their aliases', () async {
    final fake = _FakeServer((req, _) => _answer(
        req,
        _reply(jsonEncode({
          'people': [
            {'person': 'Vincent', 'mention': 'Bruder', 'isNew': false},
            {'person': 'Lena', 'mention': 'Lena', 'isNew': true},
          ],
        }))));
    await fake.start();
    addTearDown(fake.server.close);

    final r = await _engine(fake).extractPeople(
      'Mit meinem Bruder und Lena gekocht.',
      const [KnownPerson('Vincent', ['wincent'])],
    );
    expect(r.names, ['Bruder', 'Lena']);
    expect(r.mentions.first.isNew, isFalse);
    expect(r.model, 'text-model');

    final prompt = fake.json(0)['contents'][0]['parts'][0]['text'] as String;
    expect(prompt, contains('- Vincent (auch: wincent)'));
    expect(prompt, contains('Keine Marken'));
    expect(prompt, endsWith('Mit meinem Bruder und Lena gekocht.'));
  });

  test('a rejected key fails; rate limits and server errors are worth waiting for', () async {
    for (final (status, transient) in [(401, false), (403, false), (429, true), (503, true)]) {
      final fake = _FakeServer((req, _) => _answer(req, {
            'error': {'message': 'nope'},
          }, status: status));
      await fake.start();
      await expectLater(
        _engine(fake).analyzeText('x'),
        throwsA(isA<AnalysisException>().having((e) => e.transient, 'transient $status', transient)),
      );
      await fake.server.close();
    }
  });

  test('no connection: transient and offline', () async {
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = free.port;
    await free.close(); // nothing listens there now
    final engine = GeminiEngine(
      apiKey: () async => 'AIza-test',
      transcriptionModelId: () => 'm',
      analysisModelId: () => 'm',
      base: Uri.parse('http://127.0.0.1:$port/'),
    );
    await expectLater(
      engine.analyzeText('x'),
      throwsA(isA<AnalysisException>()
          .having((e) => e.transient, 'transient', isTrue)
          .having((e) => e.offline, 'offline', isTrue)),
    );
  });

  test('no key: a clear message, not worth waiting for', () async {
    final engine = GeminiEngine(
      apiKey: () async => null,
      transcriptionModelId: () => 'm',
      analysisModelId: () => 'm',
    );
    await expectLater(
      engine.analyzeText('x'),
      throwsA(isA<AnalysisException>()
          .having((e) => e.message, 'message', contains('API-Key'))
          .having((e) => e.transient, 'transient', isFalse)),
    );
  });

  test('audio MIME types by extension', () {
    expect(GeminiEngine.audioMimeType('a/1.m4a'), 'audio/mp4');
    expect(GeminiEngine.audioMimeType('a/1.WAV'), 'audio/wav');
  });
}
