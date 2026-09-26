import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/domain/analysis_basis.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/logic/analysis_task_service.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/logic/location_service.dart';
import 'package:mars_log/logic/recording_manager.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_sync/mars_sync.dart';

import 'sync_test.dart' show FakeHub, Device, entry, tick, syncLive;

/// A model that answers only once [gate] opens — the seconds during which a
/// sync round can replace the entry being analyzed.
class _Engine extends Fake implements AnalysisEngine {
  final gate = Completer<void>();
  final AnalysisResult Function(String? transcriptIn) respond;
  _Engine(this.respond);

  @override
  String get modelName => 'fake';

  @override
  Future<String> transcribe(List<File> audioFiles) async {
    await gate.future;
    return respond(null).transcript;
  }

  @override
  Future<AnalysisResult> analyzeAudio(List<File> audioFiles) async =>
      analyzeText(await transcribe(audioFiles));

  @override
  Future<AnalysisResult> analyzeText(String transcript) async => respond(transcript);
}

class _NoLocation extends Fake implements LocationService {
  @override
  Future<EntryLocation?> current() async => null;
}

class _Task extends Fake implements AnalysisTaskService {
  @override
  Future<T> run<T>(Future<T> Function() body) => body();
}

AnalysisResult _result({
  String transcript = 'alt',
  String summary = 'neu analysiert',
  List<String> tags = const ['auto'],
}) =>
    AnalysisResult(
      transcript: transcript,
      summary: summary,
      moodLabel: 'ruhig',
      moodScore: 7,
      dimensions: const {'calm': 80},
      tags: tags,
    );

JournalManager _manager(
  JournalRepository journal,
  LocalStorageService storage,
  _Engine engine,
) {
  getIt
    ..registerSingleton<JournalRepository>(journal)
    ..registerSingleton<LocalStorageService>(storage)
    ..registerSingleton<LocationService>(_NoLocation())
    ..registerSingleton<AnalysisEngine>(engine)
    ..registerSingleton<AnalysisTaskService>(_Task());
  return JournalManager();
}

/// Long enough for the manager to write "analyzing" and reach the model.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 30));

/// The phone's JournalManager holds an entry for seconds while the model
/// answers; a sync round may replace the entry meanwhile. Review 2026-09-24,
/// H1: the held object was written back, undoing the laptop's edit
/// everywhere.
///
/// The laptop runs *inside* the phone's run here, because the sync must
/// happen during the analysis. Device.run swaps the global prefs mock, so the
/// assertions stay inside and no further phone.run follows.
void main() {
  late Directory tmp;
  late FakeHub hub;
  late SyncEncryptor key;
  late Device phone;
  late Device laptop;

  setUp(() async {
    await getIt.reset();
    tmp = await Directory.systemTemp.createTemp('mars_log_race_');
    hub = FakeHub();
    key = await SyncEncryptor.generate();
    phone = Device('phone', Directory('${tmp.path}/phone'));
    laptop = Device('laptop', Directory('${tmp.path}/laptop'));
  });

  tearDown(() => tmp.delete(recursive: true));

  test('a laptop edit made during a re-analysis on the phone survives it', () async {
    await phone.run((journal, _) =>
        journal.upsert(entry('a', transcript: 'alt')..tags = ['alt']));
    await phone.sync(hub, key);
    await laptop.sync(hub, key);

    await phone.run((journal, storage) async {
      final engine = _Engine((_) => _result());
      final manager = _manager(journal, storage, engine);
      // The long way round (Whisper first) — the window in which the laptop
      // edits.
      final analysis = manager.reanalyze(journal.byId('a')!, retranscribe: true);
      await _settle();
      expect(journal.byId('a')!.status, EntryStatus.analyzing);

      await tick();
      await laptop.run((lj, _) async {
        await lj.edit(lj.byId('a')!, place: 'Wien', tags: ['korrigiert']);
        await lj.moveToTrash(lj.byId('a')!);
      });
      await laptop.sync(hub, key);
      await syncLive('phone', journal, storage, hub, key);

      engine.gate.complete();
      await analysis;

      final e = journal.byId('a')!;
      // Fields nobody touched take the analysis' result…
      expect(e.summary, 'neu analysiert');
      expect(e.status, EntryStatus.ready);
      // …what the laptop changed meanwhile stays: newer intent than an
      // automatic result.
      expect(e.place, 'Wien');
      expect(e.tags, ['korrigiert']);
      expect(e.deletedAt, isNotNull);
    });
  });

  test('a transcript fixed on the laptop during appendRecording keeps the fix', () async {
    await phone.run((journal, _) async {
      await phone.audio('a.wav').create(recursive: true);
      await journal.upsert(entry('a', transcript: 'Tippfehlr', audio: ['a.wav']));
    });
    await phone.sync(hub, key);
    await laptop.sync(hub, key);

    await phone.run((journal, storage) async {
      final engine = _Engine((text) => text == null
          ? _result(transcript: 'zweiter Teil')
          : _result(transcript: text, summary: 'beides'));
      final manager = _manager(journal, storage, engine);
      await phone.audio('b.wav').create(recursive: true);
      final append = manager.appendRecording(
        journal.byId('a')!,
        RecordingResult(id: 'b', fileName: 'b.wav', createdAt: DateTime.now()),
      );
      await _settle();

      await tick();
      await laptop.run((lj, _) => lj.setText(lj.byId('a')!, transcript: 'Tippfehler'));
      await laptop.sync(hub, key);
      await syncLive('phone', journal, storage, hub, key);

      engine.gate.complete();
      await append;

      final e = journal.byId('a')!;
      expect(e.transcript, 'Tippfehler\n\nzweiter Teil');
      expect(e.audioFileNames, ['a.wav', 'b.wav']);
      expect(e.summary, 'beides');
    });
  });

  test('a recording appended to an entry purged meanwhile becomes its own entry',
      () async {
    await phone.run((journal, _) => journal.upsert(entry('a')));
    await phone.sync(hub, key);
    await laptop.sync(hub, key);

    await phone.run((journal, storage) async {
      final engine = _Engine((text) => _result(transcript: text ?? 'nur das Neue'));
      final manager = _manager(journal, storage, engine);
      await phone.audio('b.wav').create(recursive: true);
      final append = manager.appendRecording(
        journal.byId('a')!,
        RecordingResult(id: 'b', fileName: 'b.wav', createdAt: DateTime.now()),
      );
      await _settle();

      await tick();
      await laptop.run((lj, _) async {
        final e = lj.byId('a')!;
        await lj.moveToTrash(e);
        await lj.purge(e);
      });
      await laptop.sync(hub, key);
      await syncLive('phone', journal, storage, hub, key);
      expect(journal.byId('a'), isNull);

      engine.gate.complete();
      await append;

      final b = journal.byId('b')!;
      expect(b.audioFileNames, ['b.wav']);
      expect(b.transcript, 'nur das Neue');
      expect(b.status, EntryStatus.ready);
    });
  });

  test('a recording appended to an entry trashed meanwhile brings it back', () async {
    // Review round 5, L2: the new recording ended up in the trash.
    await phone.run((journal, _) => journal.upsert(entry('a')));
    await phone.sync(hub, key);
    await laptop.sync(hub, key);

    await phone.run((journal, storage) async {
      final engine = _Engine((text) => _result(transcript: text ?? 'neu'));
      final manager = _manager(journal, storage, engine);
      await phone.audio('b.wav').create(recursive: true);
      final append = manager.appendRecording(
        journal.byId('a')!,
        RecordingResult(id: 'b', fileName: 'b.wav', createdAt: DateTime.now()),
      );
      await _settle();

      await tick();
      await laptop.run((lj, _) => lj.moveToTrash(lj.byId('a')!));
      await laptop.sync(hub, key);
      await syncLive('phone', journal, storage, hub, key);

      engine.gate.complete();
      await append;

      final e = journal.byId('a')!;
      expect(e.deletedAt, isNull);
      expect(e.audioFileNames, contains('b.wav'));
    });
  });

  test('a failed analysis keeps the transcript, and the retry reuses it', () async {
    await phone.run((journal, storage) async {
      await phone.audio('a.wav').create(recursive: true);
      await journal.upsert(entry('a', transcript: '', audio: ['a.wav']));
      var nanoFails = true;
      var transcriptions = 0;
      final engine = _Engine((text) {
        if (text == null) {
          transcriptions++;
          return _result(transcript: 'von Whisper');
        }
        if (nanoFails) throw Exception('BACKGROUND_USE_BLOCKED');
        return _result(transcript: text, summary: 'später');
      });
      engine.gate.complete();
      final manager = _manager(journal, storage, engine);

      await manager.reanalyze(journal.byId('a')!);
      expect(journal.byId('a')!.status, EntryStatus.failed);
      expect(journal.byId('a')!.transcript, 'von Whisper');

      nanoFails = false;
      await manager.resumePending();
      expect(journal.byId('a')!.status, EntryStatus.ready);
      expect(journal.byId('a')!.summary, 'später');
      expect(transcriptions, 1, reason: 'Whisper ran again for a kept transcript');
    });
  });

  test("the phone's re-analysis keeps the laptop's analysis of the same transcript",
      () async {
    await phone.run((journal, storage) async {
      await phone.audio('a.wav').create(recursive: true);
      await journal.upsert(entry('a', transcript: 'alt', audio: ['a.wav']));
      await journal.writeAnalysis(
        'a',
        _result(summary: 'vom Laptop'),
        model: 'ollama:test',
        version: 1,
        source: AnalysisSource.laptop,
        basis: transcriptBasis('alt'),
      );
      final engine = _Engine((_) => _result(summary: 'vom Handy'))..gate.complete();
      await _manager(journal, storage, engine).reanalyze(journal.byId('a')!);

      final e = journal.byId('a')!;
      expect(e.summary, 'vom Laptop');
      expect(e.analysisSource, AnalysisSource.laptop);
      expect(e.status, EntryStatus.ready);
    });
  });

  test('"Neu analysieren" works from the transcript, without Whisper', () async {
    await phone.run((journal, storage) async {
      await phone.audio('a.wav').create(recursive: true);
      await journal.upsert(entry('a', transcript: 'schon da', audio: ['a.wav']));
      var transcriptions = 0;
      final engine = _Engine((text) {
        if (text == null) transcriptions++;
        return _result(transcript: text ?? 'neu gehört', summary: 'Analyse');
      })..gate.complete();
      final manager = _manager(journal, storage, engine);

      await manager.reanalyze(journal.byId('a')!);
      expect(transcriptions, 0);
      expect(journal.byId('a')!.transcript, 'schon da');
      expect(journal.byId('a')!.summary, 'Analyse');

      await manager.reanalyze(journal.byId('a')!, retranscribe: true);
      expect(transcriptions, 1);
      expect(journal.byId('a')!.transcript, 'neu gehört');
      expect(manager.phases.value, isEmpty, reason: 'phase cleared when done');
    });
  });

  test('the phase moves from transcribing to analysing, transcript already stored',
      () async {
    await phone.run((journal, storage) async {
      await phone.audio('a.wav').create(recursive: true);
      await journal.upsert(entry('a', transcript: '', audio: ['a.wav']));
      final engine = _Engine((text) => _result(transcript: text ?? 'gehört'));
      final manager = _manager(journal, storage, engine);
      final seen = <AnalysisPhase?>[];
      String? transcriptWhenAnalysing;
      manager.phases.addListener(() {
        final p = manager.phases.value['a'];
        seen.add(p);
        if (p == AnalysisPhase.analyzing) {
          transcriptWhenAnalysing = journal.byId('a')!.transcript;
        }
      });
      final run = manager.reanalyze(journal.byId('a')!);
      await _settle();
      expect(manager.phaseOf(journal.byId('a')!), AnalysisPhase.transcribing);
      engine.gate.complete();
      await run;

      expect(seen, [AnalysisPhase.transcribing, AnalysisPhase.analyzing, null]);
      expect(transcriptWhenAnalysing, anyOf('', 'gehört'));
      expect(journal.byId('a')!.transcript, 'gehört');
    });
  });

  test('edits through an entry held across a sync land on the stored one', () async {
    // The phone's detail screen holds its entry across date/place dialogs.
    await phone.run((journal, _) async {
      await journal.upsert(entry('a'));
      final held = journal.byId('a')!;

      final remote = JournalEntry.fromJson(held.toJson())
        ..place = 'Wien'
        ..changedAt = held.changedAt.add(const Duration(seconds: 1));
      await journal.applySynced([remote], {});
      expect(identical(journal.byId('a'), held), isFalse);

      await journal.setDay(held, DateTime(2026, 8, 1));
      final e = journal.byId('a')!;
      expect(e.place, 'Wien', reason: 'the remote edit must survive');
      expect(e.day, DateTime(2026, 8, 1));

      await journal.moveToTrash(held);
      expect(journal.byId('a')!.deletedAt, isNotNull);
    });
  });

  test('an edit through an entry purged meanwhile does not bring it back', () async {
    // The detail screen's date dialog is open while a tombstone arrives.
    await phone.run((journal, _) async {
      await journal.upsert(entry('a'));
      final held = journal.byId('a')!;
      await journal.applySynced([], {'a': DateTime.now().add(const Duration(seconds: 1))});
      expect(journal.byId('a'), isNull);

      await journal.setDay(held, DateTime(2026, 8, 1));
      await journal.edit(held, place: 'Wien');
      await journal.moveToTrash(held);
      await journal.restore(held);
      expect(journal.byId('a'), isNull);
      expect(journal.entries, isEmpty);
    });
  });

  test('writing back a stale object is caught in debug builds', () async {
    await phone.run((journal, _) async {
      await journal.upsert(entry('a'));
      final held = journal.byId('a')!;
      final remote = JournalEntry.fromJson(held.toJson())
        ..changedAt = held.changedAt.add(const Duration(seconds: 1));
      await journal.applySynced([remote], {});
      await expectLater(journal.upsert(held), throwsA(isA<AssertionError>()));
    });
  });
}
