import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';

import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/data/gemini_engine.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/domain/analysis_basis.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/people_aliases.dart';
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

  /// What [extractPeople] finds, and how often it ran.
  List<PersonMention> Function(String transcript, List<KnownPerson> known) people =
      (_, _) => const [];
  int peopleCalls = 0;

  @override
  String get modelName => 'fake';

  @override
  String get transcriptionModel => 'fake-stt';

  @override
  String get source => AnalysisSource.cloud;

  @override
  Future<String> transcribe(List<File> audioFiles) async {
    await gate.future;
    return respond(null).transcript;
  }

  @override
  Future<AnalysisResult> analyzeText(String transcript) async => respond(transcript);

  @override
  Future<PeopleResult> extractPeople(String transcript, List<KnownPerson> known) async {
    peopleCalls++;
    return PeopleResult(people(transcript, known), model: 'fake');
  }
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
  AnalysisEngine engine,
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
    await phone.run((journal, _) async {
      await phone.audio('a.m4a').create(recursive: true);
      await journal.upsert(entry('a', transcript: 'alt', audio: ['a.m4a'])..tags = ['alt']);
    });
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

  group('pending', () {
    test('no connection: the entry waits, then finishes without transcribing twice',
        () async {
      await phone.run((journal, storage) async {
        var offline = true;
        var transcriptions = 0;
        var analysisCalls = 0;
        final engine = _Engine((text) {
          if (text == null) {
            transcriptions++;
            return _result(transcript: 'gehört');
          }
          analysisCalls++;
          if (offline) throw AnalysisException('Wartet auf Netz.', transient: true, offline: true);
          return _result(transcript: text, summary: 'später');
        })..gate.complete();
        final manager = _manager(journal, storage, engine);
        await phone.audio('1.m4a').create(recursive: true);

        await manager.createFromAudio(
          RecordingResult(id: '1', fileName: '1.m4a', createdAt: DateTime.now()),
        );
        var e = journal.byId('1')!;
        expect(e.status, EntryStatus.pending);
        expect(e.transcript, 'gehört', reason: 'the transcript is kept');
        expect(e.untranscribed, isEmpty);
        expect(e.transcriptionModel, 'fake-stt');
        expect(manager.retryAt.value['1'], isNotNull);
        expect(manager.pendingText(e), startsWith('Wartet auf Netz'));

        // Not due yet: a plain resume leaves it alone.
        await manager.resumePending();
        expect(analysisCalls, 1);

        offline = false;
        await manager.resumePending(now: true); // the connection is back
        e = journal.byId('1')!;
        expect(e.status, EntryStatus.ready);
        expect(e.summary, 'später');
        expect(transcriptions, 1);
        expect(manager.retryAt.value, isEmpty);
      });
    });

    test('a recording appended offline is kept until transcribed', () async {
      await phone.run((journal, storage) async {
        await phone.audio('a.m4a').create(recursive: true);
        await journal.upsert(entry('a', transcript: 'erster Teil', audio: ['a.m4a']));
        var offline = true;
        final engine = _Engine((text) {
          if (text == null) {
            if (offline) throw AnalysisException('Wartet auf Netz.', transient: true, offline: true);
            return _result(transcript: 'zweiter Teil');
          }
          return _result(transcript: text);
        })..gate.complete();
        final manager = _manager(journal, storage, engine);
        await phone.audio('b.m4a').create(recursive: true);

        await manager.appendRecording(
          journal.byId('a')!,
          RecordingResult(id: 'b', fileName: 'b.m4a', createdAt: DateTime.now()),
        );
        expect(journal.byId('a')!.status, EntryStatus.pending);
        expect(journal.byId('a')!.audioFileNames, ['a.m4a', 'b.m4a']);
        expect(journal.byId('a')!.untranscribed, ['b.m4a']);

        offline = false;
        await manager.resumePending(now: true);
        final e = journal.byId('a')!;
        expect(e.status, EntryStatus.ready);
        expect(e.transcript, 'erster Teil\n\nzweiter Teil');
        expect(e.untranscribed, isEmpty);
      });
    });

    test('a rejected key fails instead of waiting', () async {
      await phone.run((journal, storage) async {
        await journal.upsert(entry('a', transcript: 'text'));
        final engine = _Engine((_) => throw AnalysisException('Key prüfen'))..gate.complete();
        final manager = _manager(journal, storage, engine);
        await manager.reanalyze(journal.byId('a')!);
        expect(journal.byId('a')!.status, EntryStatus.failed);
      });
    });

    test('backoff doubles up to half an hour', () {
      expect(JournalManager.retryDelay(1), const Duration(seconds: 30));
      expect(JournalManager.retryDelay(2), const Duration(minutes: 1));
      expect(JournalManager.retryDelay(3), const Duration(minutes: 2));
      expect(JournalManager.retryDelay(20), const Duration(minutes: 30));
    });
  });

  group('people', () {
    test('every new entry gets its people from their own call', () async {
      await phone.run((journal, storage) async {
        final engine = _Engine((text) => _result(transcript: text ?? 'Mit Lena.'))
          ..people = ((_, _) => const [PersonMention(person: 'Lena', mention: 'Lena', isNew: true)])
          ..gate.complete();
        final manager = _manager(journal, storage, engine);
        await phone.audio('1.m4a').create(recursive: true);
        await manager.createFromAudio(
          RecordingResult(id: '1', fileName: '1.m4a', createdAt: DateTime.now()),
        );
        final e = journal.byId('1')!;
        expect(e.people, ['Lena']);
        expect(e.peopleVersion, kPeopleVersion);
        expect(e.peopleModel, 'fake');
      });
    });

    test('a known person under another name: the aliases learn it, the entry keeps the mention',
        () async {
      await phone.run((journal, storage) async {
        await journal.upsert(entry('old', transcript: '')..people = ['Vincent']);
        await journal.upsert(entry('a', transcript: 'Mit meinem Bruder.'));
        late List<KnownPerson> seen;
        final engine = _Engine((t) => _result(transcript: t ?? ''))
          ..people = (_, known) {
            seen = known;
            return const [PersonMention(person: 'Vincent', mention: 'Bruder', isNew: false)];
          }
          ..gate.complete();
        final manager = _manager(journal, storage, engine);
        await manager.backfillPeople(all: true);

        expect(seen.map((k) => k.name), contains('Vincent'));
        expect(journal.byId('a')!.people, ['Bruder']);
        expect(journal.aliases.canonical('Bruder'), 'Vincent');
        expect(effectivePeople(journal.byId('a')!, journal.aliases), ['Vincent']);
      });
    });

    test('backfill: removed by hand stays removed, added by hand stays, no duplicates',
        () async {
      await phone.run((journal, storage) async {
        await journal.upsert(entry('a', transcript: 'Mit Lena und Tom.')
          ..people = ['Lena', 'Tom']
          ..peopleRemoved = ['Tom']
          ..peopleAdded = ['Mia']);
        final engine = _Engine((t) => _result(transcript: t ?? ''))
          ..people = ((_, _) => const [
                PersonMention(person: 'Lena', mention: 'Lena', isNew: true),
                PersonMention(person: 'Tom', mention: 'Tom', isNew: true),
              ])
          ..gate.complete();
        final manager = _manager(journal, storage, engine);

        expect(manager.peopleBackfillDue, 1);
        final first = await manager.backfillPeople();
        expect(first.done, 1);
        expect(manager.peopleBackfillDue, 0);
        expect(effectivePeople(journal.byId('a')!, journal.aliases), ['Lena', 'Mia']);

        // Again, and again everything: nothing changes, nothing doubles.
        await manager.backfillPeople();
        await manager.backfillPeople(all: true);
        expect(engine.peopleCalls, 2);
        final e = journal.byId('a')!;
        expect(e.people, ['Lena', 'Tom']);
        expect(e.peopleRemoved, ['Tom']);
        expect(e.peopleAdded, ['Mia']);
        expect(effectivePeople(e, journal.aliases), ['Lena', 'Mia']);
      });
    });

    test('a removal survives a re-extraction that spells the person differently', () async {
      await phone.run((journal, storage) async {
        final aliases = const PeopleAliases().merge('Vince', 'Vincent');
        await journal.writeAliases(aliases);
        await journal.upsert(entry('a', transcript: 'Mit Vincent.')
          ..people = ['Vincent']
          ..peopleRemoved = ['Vincent']);
        final engine = _Engine((t) => _result(transcript: t ?? ''))
          ..people = ((_, _) => const [PersonMention(person: 'Vincent', mention: 'Vince', isNew: false)])
          ..gate.complete();
        await _manager(journal, storage, engine).backfillPeople(all: true);
        expect(effectivePeople(journal.byId('a')!, journal.aliases), isEmpty);
      });
    });
  });

  test('people by hand: remove with undo, add, and an extraction keeps both', () async {
    await phone.run((journal, storage) async {
      await journal.upsert(entry('a', transcript: 'Mit Lena und Tom.')..people = ['Lena', 'Tom']);
      final engine = _Engine((t) => _result(transcript: t ?? ''))
        ..people = ((_, _) => const [
              PersonMention(person: 'Lena', mention: 'Lena', isNew: true),
              PersonMention(person: 'Tom', mention: 'Tom', isNew: true),
            ])
        ..gate.complete();
      final manager = _manager(journal, storage, engine);
      List<String> shown() => effectivePeople(journal.byId('a')!, journal.aliases);

      final before = await manager.removePerson('a', 'Tom');
      expect(shown(), ['Lena']);
      await manager.restorePeople('a', before!);
      expect(shown(), ['Lena', 'Tom'], reason: 'undo');

      await manager.removePerson('a', 'Tom');
      await manager.addPerson('a', 'Mia');
      await manager.addPerson('a', 'mia'); // already there: no duplicate
      expect(shown(), ['Lena', 'Mia']);

      await manager.reanalyze(journal.byId('a')!);
      expect(shown(), ['Lena', 'Mia'], reason: 'a re-extraction keeps the corrections');

      await manager.addPerson('a', 'Tom'); // brought back by hand
      expect(shown(), ['Lena', 'Tom', 'Mia']);
      expect(journal.byId('a')!.peopleAdded, ['Mia']);

      await manager.removePerson('a', 'Mia'); // only added by hand: no tombstone
      expect(journal.byId('a')!.peopleAdded, isEmpty);
      expect(journal.byId('a')!.peopleRemoved, isEmpty);
    });
  });

  group('self-rating', () {
    test('before: given to the new entry; after: set on it; skipped: null', () async {
      await phone.run((journal, storage) async {
        final engine = _Engine((t) => _result(transcript: t ?? 'gehört'))..gate.complete();
        final manager = _manager(journal, storage, engine);
        await phone.audio('1.m4a').create(recursive: true);
        await phone.audio('2.m4a').create(recursive: true);
        await phone.audio('3.m4a').create(recursive: true);

        manager.ratingForNextRecording = (valence: 7, arousal: 3);
        await manager.createFromAudio(
            RecordingResult(id: '1', fileName: '1.m4a', createdAt: DateTime.now()));
        var e = journal.byId('1')!;
        expect((e.selfValence, e.selfArousal, e.selfRatingTiming), (7, 3, kRatedBefore));
        expect(e.selfRatedAt, isNotNull);
        expect(manager.ratingForNextRecording, isNull, reason: 'used once');

        final run = manager.createFromAudio(
            RecordingResult(id: '2', fileName: '2.m4a', createdAt: DateTime.now()));
        await manager.setSelfRating('2', (valence: 4, arousal: 8)); // while it processes
        await run;
        e = journal.byId('2')!;
        expect((e.selfValence, e.selfArousal, e.selfRatingTiming), (4, 8, kRatedAfter));
        expect(e.status, EntryStatus.ready);

        await manager.createFromAudio(
            RecordingResult(id: '3', fileName: '3.m4a', createdAt: DateTime.now()));
        e = journal.byId('3')!;
        expect((e.selfValence, e.selfArousal, e.selfRatingTiming), (null, null, null));

        // Changed later: keeps when it was first asked.
        await manager.setSelfRating('1', (valence: 9, arousal: 9));
        expect(journal.byId('1')!.selfRatingTiming, kRatedBefore);
        expect(JournalEntry.fromJson(journal.byId('1')!.toJson()).selfValence, 9);
      });
    });

    test('the rating never reaches the model', () async {
      final bodies = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((req) async {
        final body = await utf8.decodeStream(req);
        bodies.add(body);
        final prompt = jsonEncode(jsonDecode(body));
        final Object answer = prompt.contains('inline_data')
            ? 'Heute war ein guter Tag.'
            : prompt.contains('Menschen')
                ? jsonEncode({'people': []})
                : jsonEncode({
                    'title': 'Guter Tag',
                    'summary': 'Gut.',
                    'moodLabel': 'Gut',
                    'moodScore': 7,
                    'dimensions': {},
                    'tags': [],
                  });
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': answer},
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
          }));
        await req.response.close();
      });

      await phone.run((journal, storage) async {
        final engine = GeminiEngine(
          apiKey: () async => 'k',
          transcriptionModelId: () => 'm',
          analysisModelId: () => 'm',
          base: Uri.parse('http://127.0.0.1:${server.port}/'),
        );
        final manager = _manager(journal, storage, engine);
        await phone.audio('1.m4a').writeAsBytes([1, 2, 3]);
        manager.ratingForNextRecording = (valence: 7, arousal: 3);
        await manager.createFromAudio(
            RecordingResult(id: '1', fileName: '1.m4a', createdAt: DateTime.now()));
        await manager.reanalyze(journal.byId('1')!);
        expect(journal.byId('1')!.status, EntryStatus.ready);
        expect(journal.byId('1')!.selfValence, 7);
      });

      expect(bodies, hasLength(5), reason: 'transcript, analysis, people, analysis, people');
      for (final body in bodies) {
        expect(body, isNot(contains('self')));
        expect(body, isNot(contains('Selbst')));
        expect(body, isNot(contains('valence')));
        expect(body, isNot(contains('arousal')));
      }
    });
  });
}
