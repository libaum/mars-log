import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/domain/analysis_basis.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/sync/journal_sync_repository.dart';
import 'package:mars_log/sync/sync_purge_trace.dart';
import 'package:mars_sync/mars_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hub with the real hub's write rule (server-side LWW, one seq counter
/// across modules, rows per module). Same semantics as mars_sync's
/// engine-test fake, minus the limits these tests don't exercise.
class FakeHub {
  final _rows = <String, SyncItem>{};
  var _seq = 0;

  static String _key(String module, String id) => '$module/$id';

  void push(String deviceId, List<SyncItem> items) {
    for (final item in items) {
      final key = _key(item.moduleId, item.itemId);
      final stored = _rows[key];
      final accept = stored == null ||
          item.updatedAtMs > stored.updatedAtMs ||
          (item.updatedAtMs == stored.updatedAtMs &&
              item.deviceId.compareTo(stored.deviceId) >= 0);
      if (accept) _rows[key] = item.copyWith(seq: ++_seq);
    }
  }

  PullResult pull(String module, int sinceSeq) {
    final page = _rows.values
        .where((r) => r.moduleId == module && r.seq! > sinceSeq)
        .toList()
      ..sort((a, b) => a.seq!.compareTo(b.seq!));
    return PullResult(
      items: page,
      latestSeq: page.isEmpty ? sinceSeq : page.last.seq!,
      hubId: 'hub',
      hasMore: false,
    );
  }

  SyncItem? row(String id, {String module = 'mars_log'}) => _rows[_key(module, id)];
}

class FakeTransport implements SyncTransport {
  final FakeHub hub;
  final String deviceId;
  FakeTransport(this.hub, this.deviceId);

  @override
  Future<String> whoami() async => deviceId;

  @override
  Future<void> push(String moduleId, List<SyncItem> items) async =>
      hub.push(deviceId, items);

  @override
  Future<PullResult> pull(String moduleId, {required int sinceSeq}) async =>
      hub.pull(moduleId, sinceSeq);
}

/// One device: its own journal directory and its own prefs. Every [run] is
/// a fresh app start — SharedPreferences is a process-wide singleton in
/// tests, so each device's prefs are swapped in and snapshotted back out.
class Device {
  final String id;
  final Directory dir;
  Map<String, Object> prefs = {};

  /// False for the desktop hub, which leaves the 30-day purge to the phone.
  final bool autoPurge;

  Device(this.id, this.dir, {this.autoPurge = true});

  Future<T> run<T>(
    Future<T> Function(JournalRepository journal, LocalStorageService storage) body,
  ) async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(prefs);
    final storage = await LocalStorageService.getInstance();
    final journal = await JournalRepository.getInstance(
      purgeTrace: SyncPurgeTrace(storage),
      directory: dir,
      autoPurge: autoPurge,
    );
    final result = await body(journal, storage);
    final raw = await SharedPreferences.getInstance();
    prefs = {for (final k in raw.getKeys()) k: raw.get(k)!};
    return result;
  }

  Future<SyncResult> sync(FakeHub hub, SyncEncryptor key) => run(
        (journal, storage) => MarsSyncEngine(
          repository: JournalSyncRepository(
            journal: journal,
            storage: storage,
            deviceId: id,
          ),
          client: FakeTransport(hub, id),
          encryptor: key,
        ).syncNow(),
      );

  File audio(String name) => File('${dir.path}/audio/$name');
}

JournalEntry entry(
  String id, {
  String transcript = 'text',
  List<String> audio = const [],
  EntryStatus status = EntryStatus.ready,
  DateTime? deletedAt,
}) {
  final created = DateTime(2026, 9, 1, 8);
  return JournalEntry(
    id: id,
    createdAt: created,
    day: DateTime(2026, 9, 1),
    audioFileNames: [...audio],
    status: status,
    transcript: transcript,
    deletedAt: deletedAt,
  );
}

/// Timestamps are ms-resolution on the wire; two edits inside one ms would
/// tie and fall to the device-id tie-break instead of "later wins".
Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 5));

/// A sync round on a journal that is already open — for rounds that must run
/// *during* something else on the same device (an analysis, an edit).
Future<SyncResult> syncLive(
  String id,
  JournalRepository journal,
  LocalStorageService storage,
  FakeHub hub,
  SyncEncryptor key,
) =>
    MarsSyncEngine(
      repository:
          JournalSyncRepository(journal: journal, storage: storage, deviceId: id),
      client: FakeTransport(hub, id),
      encryptor: key,
    ).syncNow();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late FakeHub hub;
  late SyncEncryptor key;
  late Device phone;
  late Device laptop;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mars_log_sync_');
    hub = FakeHub();
    key = await SyncEncryptor.generate();
    phone = Device('phone', Directory('${tmp.path}/phone'));
    laptop = Device('laptop', Directory('${tmp.path}/laptop'));
  });

  tearDown(() => tmp.delete(recursive: true));

  group('change clock', () {
    test('entries written before sync existed fall back to createdAt', () {
      final json = entry('a').toJson()..remove('changedAt');
      final loaded = JournalEntry.fromJson(json);
      expect(loaded.changedAt, loaded.createdAt);
    });

    test('every local write moves changedAt', () async {
      await phone.run((journal, _) async {
        final e = entry('a');
        await journal.upsert(e);
        final stamps = [e.changedAt];
        for (final write in <Future<void> Function()>[
          () => journal.setText(e, transcript: 'edited'),
          () => journal.setPlace(e, 'Wien'),
          () => journal.setTags(e, ['x']),
          () => journal.moveToTrash(e),
          () => journal.restore(e),
        ]) {
          await tick();
          await write();
          expect(e.changedAt.isAfter(stamps.last), isTrue);
          stamps.add(e.changedAt);
        }
      });
    });

    test('an edit of several fields is one write, normalized', () async {
      // An editor saving field by field would see the first write's revision
      // while the rest is pending, and read a half-saved entry back.
      await phone.run((journal, _) async {
        final e = entry('a');
        await journal.upsert(e);
        final before = journal.revision.value;
        await journal.edit(e,
            transcript: 'neu', place: '  Wien ', tags: [' see', '', 'ruhe ']);
        expect(journal.revision.value, before + 1);
        expect([e.transcript, e.place, e.tags], ['neu', 'Wien', ['see', 'ruhe']]);
        await journal.edit(e, place: '   ');
        expect(e.place, isNull);
      });
    });

    test('a sync apply keeps the remote stamp and never overwrites newer local edits', () async {
      await phone.run((journal, _) async {
        final local = entry('a', transcript: 'local');
        await journal.upsert(local);
        final localStamp = local.changedAt;

        final older = entry('a', transcript: 'older remote')
          ..changedAt = localStamp.subtract(const Duration(minutes: 1));
        await journal.applySynced([older], {});
        expect(journal.byId('a')!.transcript, 'local');

        final newer = entry('a', transcript: 'newer remote')
          ..changedAt = localStamp.add(const Duration(minutes: 1));
        await journal.applySynced([newer], {});
        expect(journal.byId('a')!.transcript, 'newer remote');
        expect(journal.byId('a')!.changedAt, newer.changedAt);
      });
    });

    test('our own push coming back does not rewrite the journal', () async {
      // The real path: the echo arrives with the stamp truncated to ms (UTC),
      // so the local, finer stamp is *after* it and it is skipped as older.
      await phone.run((journal, _) => journal.upsert(entry('a')));
      await phone.sync(hub, key);
      await phone.run((journal, storage) async {
        await storage.setSyncPullWatermark(seq: null, hubId: null);
        final before = journal.revision.value;
        await syncLive('phone', journal, storage, hub, key);
        expect(journal.revision.value, before);
      });
    });

    test('an entry received earlier and pulled again does not rewrite the journal',
        () async {
      // Received entries carry the hub's ms stamp, so a second pull (after a
      // re-pair) meets the same stamp — the same-content check is what
      // stops the rewrite here.
      await phone.run((journal, _) => journal.upsert(entry('a')));
      await phone.sync(hub, key);
      await laptop.sync(hub, key);
      await laptop.run((journal, storage) async {
        await storage.setSyncPullWatermark(seq: null, hubId: null);
        final before = journal.revision.value;
        await syncLive('laptop', journal, storage, hub, key);
        expect(journal.revision.value, before);
      });
    });
  });

  group('purge trace', () {
    test('emptying the trash is remembered for the next push', () async {
      await phone.run((journal, storage) async {
        final e = entry('a');
        await journal.upsert(e);
        await journal.moveToTrash(e);
        await journal.emptyTrash();
        expect(storage.getSyncPurged().keys, ['a']);
      });
    });

    test('the 30-day expiry while loading is remembered too', () async {
      // The expiry runs inside getInstance(), before any sync object exists —
      // the reason the trace is a constructor argument.
      await phone.dir.create(recursive: true);
      final expired = entry(
        'old',
        deletedAt: DateTime.now().subtract(const Duration(days: 31)),
      );
      await File('${phone.dir.path}/entries.json')
          .writeAsString(jsonEncode([expired.toJson()]));

      await phone.run((journal, storage) async {
        expect(journal.byId('old'), isNull);
        expect(storage.getSyncPurged().keys, ['old']);
      });
    });
  });

  group('phone ⇄ laptop', () {
    test('an entry recorded on the phone shows up on the laptop, without audio', () async {
      await phone.run((journal, _) async {
        await phone.audio('a.wav').create(recursive: true);
        await journal.upsert(entry('a', transcript: 'Heute am See', audio: ['a.wav']));
      });
      await phone.sync(hub, key);
      await laptop.sync(hub, key);

      await laptop.run((journal, _) async {
        final e = journal.byId('a')!;
        expect(e.transcript, 'Heute am See');
        // Metadata travels, the file does not.
        expect(e.audioFileNames, ['a.wav']);
        expect(await laptop.audio('a.wav').exists(), isFalse);
      });
    });

    test('a laptop edit comes back to the phone and the phone keeps its audio', () async {
      await phone.run((journal, _) async {
        await phone.audio('a.wav').create(recursive: true);
        await journal.upsert(entry('a', transcript: 'Tippfehlr', audio: ['a.wav']));
      });
      await phone.sync(hub, key);
      await laptop.sync(hub, key);

      await tick();
      await laptop.run((journal, _) =>
          journal.setText(journal.byId('a')!, transcript: 'Tippfehler'));
      await laptop.sync(hub, key);
      await phone.sync(hub, key);

      await phone.run((journal, _) async {
        final e = journal.byId('a')!;
        expect(e.transcript, 'Tippfehler');
        expect(e.audioFileNames, ['a.wav']);
        // Survives the load-time orphan sweep, which deletes unreferenced audio.
        expect(await phone.audio('a.wav').exists(), isTrue);
      });
    });

    test('a laptop edit cannot orphan a recording the phone added meanwhile', () async {
      // Phone appends a second recording ("Weitere Aufnahme für diesen Tag")
      // while the laptop fixes a typo. The laptop's edit is newer and wins
      // the entry — with the *old* file list. Without the audio guard the
      // new recording is referenced by nothing, and the load-time orphan
      // sweep deletes it.
      await phone.run((journal, _) async {
        await phone.audio('a.wav').create(recursive: true);
        await journal.upsert(entry('a', audio: ['a.wav']));
      });
      await phone.sync(hub, key);
      await laptop.sync(hub, key);

      await tick();
      await phone.run((journal, _) async {
        await phone.audio('b.wav').create(recursive: true);
        final e = journal.byId('a')!..audioFileNames = ['a.wav', 'b.wav'];
        await journal.upsert(e);
      });
      await tick();
      await laptop.run((journal, _) =>
          journal.setText(journal.byId('a')!, transcript: 'korrigiert'));
      await laptop.sync(hub, key);
      await phone.sync(hub, key);

      await phone.run((journal, _) async {
        final e = journal.byId('a')!;
        expect(e.transcript, 'korrigiert');
        expect(e.audioFileNames, ['a.wav', 'b.wav']);
        expect(await phone.audio('b.wav').exists(), isTrue);
      });
    });

    test('trash is an ordinary edit: restorable on the other device', () async {
      await phone.run((journal, _) => journal.upsert(entry('a')));
      await phone.sync(hub, key);
      await laptop.sync(hub, key);

      await tick();
      await phone.run((journal, _) => journal.moveToTrash(journal.byId('a')!));
      await phone.sync(hub, key);
      await laptop.sync(hub, key);
      await laptop.run((journal, _) async {
        expect(journal.deletedEntries.map((e) => e.id), ['a']);
      });

      await tick();
      await laptop.run((journal, _) => journal.restore(journal.byId('a')!));
      await laptop.sync(hub, key);
      await phone.sync(hub, key);
      await phone.run((journal, _) async {
        expect(journal.entries.map((e) => e.id), ['a']);
      });
    });

    test('a purge on the laptop removes the entry and its audio on the phone', () async {
      await phone.run((journal, _) async {
        await phone.audio('a.wav').create(recursive: true);
        await journal.upsert(entry('a', audio: ['a.wav']));
      });
      await phone.sync(hub, key);
      await laptop.sync(hub, key);

      await tick();
      await laptop.run((journal, _) async {
        final e = journal.byId('a')!;
        await journal.moveToTrash(e);
        await journal.purge(e);
      });
      await laptop.sync(hub, key);
      await phone.sync(hub, key);

      await phone.run((journal, _) async {
        expect(journal.byId('a'), isNull);
        expect(await phone.audio('a.wav').exists(), isFalse);
      });
      expect(hub.row('a')!.isDeleted, isTrue);
    });

    test('an entry still being analyzed is held back until it is ready', () async {
      await phone.run((journal, _) =>
          journal.upsert(entry('a', status: EntryStatus.analyzing, transcript: '')));
      await phone.sync(hub, key);
      expect(hub.row('a'), isNull);

      await tick();
      await phone.run((journal, _) async {
        final e = journal.byId('a')!
          ..status = EntryStatus.ready
          ..transcript = 'fertig';
        await journal.upsert(e);
      });
      await phone.sync(hub, key);
      await laptop.sync(hub, key);
      await laptop.run((journal, _) async {
        expect(journal.byId('a')!.transcript, 'fertig');
      });
    });

    test('the hub only ever sees ciphertext', () async {
      await phone.run((journal, _) =>
          journal.upsert(entry('a', transcript: 'sehr privat')));
      await phone.sync(hub, key);
      final stored = jsonEncode(hub.row('a')!.payload);
      expect(stored, isNot(contains('sehr privat')));
      expect(hub.row('a')!.payload.keys, ['ciphertext']);
    });
  });

  group('review 2026-09-24', () {
    // older version (audioDeleted=false, old list) with a newer stamp.
    test('M4: phone never ends up pointing at audio it discarded', () async {
      await phone.run((journal, _) async {
        await phone.audio('a.wav').create(recursive: true);
        await journal.upsert(entry('a', audio: ['a.wav']));
      });
      await phone.sync(hub, key);
      await laptop.sync(hub, key);

      await tick();
      await phone.run((journal, _) async {
        final e = journal.byId('a')!;
        await journal.discardAudio(e);
        e
          ..audioDeleted = true
          ..audioFileNames = [];
        await journal.upsert(e);
      });
      await tick();
      await laptop.run((lj, _) => lj.setPlace(lj.byId('a')!, 'Wien'));
      await laptop.sync(hub, key);
      await phone.sync(hub, key);

      await phone.run((journal, _) async {
        final e = journal.byId('a')!;
        expect(e.place, 'Wien');
        final dangling = [
          for (final f in e.audioFileNames)
            if (!await phone.audio(f).exists()) f,
        ];
        expect(e.audioDeleted, isTrue, reason: 'audioDeleted flipped back');
        expect(dangling, isEmpty, reason: 'entry lists files that do not exist');
      });
    });

    // list is non-empty it never takes the phone's list again.
    test('L1: a recording added on the phone shows up in the laptop metadata', () async {
      await phone.run((journal, _) async {
        await phone.audio('a.wav').create(recursive: true);
        await journal.upsert(entry('a', audio: ['a.wav']));
      });
      await phone.sync(hub, key);
      await laptop.sync(hub, key);

      await tick();
      await phone.run((journal, _) async {
        await phone.audio('b.wav').create(recursive: true);
        await journal.upsert(journal.byId('a')!..audioFileNames = ['a.wav', 'b.wav']);
      });
      await phone.sync(hub, key);
      await laptop.sync(hub, key);
      await laptop.run((lj, _) async {
        expect(lj.byId('a')!.audioFileNames, ['a.wav', 'b.wav']);
      });
    });

    // other device that happened in between.
    test('M3: a restore on the laptop beats a later automatic 30-day purge', () async {
      final trashedAt = DateTime.now().subtract(const Duration(days: 31));
      final e = entry('a', deletedAt: trashedAt)..changedAt = trashedAt;
      // Both devices hold the trashed entry (as after an earlier sync).
      for (final d in [phone, laptop]) {
        await d.dir.create(recursive: true);
        await File('${d.dir.path}/entries.json').writeAsString(jsonEncode([e.toJson()]));
      }
      // Laptop: user restores it. Written directly so the laptop's own load
      // doesn't auto-purge first: restore happened on day 29 in reality.
      final restored = JournalEntry.fromJson(e.toJson())
        ..deletedAt = null
        ..changedAt = DateTime.now().subtract(const Duration(minutes: 5));
      await File('${laptop.dir.path}/entries.json')
          .writeAsString(jsonEncode([restored.toJson()]));

      await phone.sync(hub, key); // load → auto-purge → tombstone(now)
      await laptop.sync(hub, key);
      await laptop.run((lj, _) async {
        expect(lj.byId('a'), isNotNull, reason: 'deliberate restore lost to auto-purge');
      });
    });
  });

  group('review round 5', () {
    /// A paired device: the 30-day purge then waits for a completed round.
    void pair(Device d) => d.prefs['flutter.sync_server_url'] = 'https://hub';

    Future<JournalEntry> trashedLongAgo(List<Device> devices, {List<String> audio = const []}) async {
      final trashedAt = DateTime.now().subtract(const Duration(days: 31));
      final e = entry('a', deletedAt: trashedAt, audio: audio)..changedAt = trashedAt;
      for (final d in devices) {
        await d.dir.create(recursive: true);
        await File('${d.dir.path}/entries.json').writeAsString(jsonEncode([e.toJson()]));
      }
      return e;
    }

    test('M1: a restore on the laptop brings the entry back with its recording', () async {
      pair(phone);
      final e = await trashedLongAgo([phone, laptop], audio: ['a.wav']);
      await phone.audio('a.wav').create(recursive: true);
      final restored = JournalEntry.fromJson(e.toJson())
        ..deletedAt = null
        ..changedAt = DateTime.now().subtract(const Duration(minutes: 5));
      await File('${laptop.dir.path}/entries.json')
          .writeAsString(jsonEncode([restored.toJson()]));
      await laptop.sync(hub, key);

      await phone.sync(hub, key); // app start: load, then the first round
      await phone.run((journal, _) async {
        expect(journal.byId('a')?.deletedAt, isNull);
        expect(journal.byId('a')!.audioFileNames, ['a.wav']);
      });
      expect(phone.audio('a.wav').existsSync(), isTrue,
          reason: 'the only recording was deleted before the restore arrived');
    });

    test('a paired device purges expired entries after a round, and the tombstone '
        'reaches the hub although its stamp lies behind the watermark', () async {
      pair(phone);
      final e = await trashedLongAgo([phone], audio: ['a.wav']);
      await phone.audio('a.wav').create(recursive: true);

      await phone.run((journal, _) async {
        expect(journal.byId('a'), isNotNull, reason: 'purged at load while paired');
      });
      await phone.sync(hub, key); // pushes the trashed entry, then purges
      expect(phone.audio('a.wav').existsSync(), isFalse);
      await phone.run((journal, _) async => expect(journal.byId('a'), isNull));

      await tick();
      await phone.sync(hub, key); // pushes the tombstone
      final row = hub.row('a')!;
      expect(row.deletedAt, isNotNull);
      expect(row.updatedAtMs, e.changedAt.millisecondsSinceEpoch + 1);
    });

    test('a device without autoPurge (the hub) keeps expired entries for the phone to purge',
        () async {
      await trashedLongAgo([laptop]); // unpaired: would purge at load
      final journal = await JournalRepository.getInstance(
        directory: laptop.dir,
        autoPurge: false,
      );
      await journal.purgeExpired();
      expect(journal.byId('a'), isNotNull);
    });

    test('an unpaired device still purges at load', () async {
      await trashedLongAgo([phone]);
      await phone.run((journal, _) async => expect(journal.byId('a'), isNull));
    });

    test('a read-only instance changes nothing on disk', () async {
      await trashedLongAgo([phone]);
      await phone.audio('recording-now.m4a').create(recursive: true);
      final before = await File('${phone.dir.path}/entries.json').readAsString();

      final ro = await JournalRepository.getInstance(directory: phone.dir, readOnly: true);
      expect(ro.allEntries.map((e) => e.id), ['a']);
      expect(await File('${phone.dir.path}/entries.json').readAsString(), before);
      expect(phone.audio('recording-now.m4a').existsSync(), isTrue,
          reason: 'swept a recording the app is still writing');
    });

    test('a corrupt index does not take the audio with it', () async {
      await phone.dir.create(recursive: true);
      await File('${phone.dir.path}/entries.json').writeAsString('[{"id": "a", tru');
      await phone.audio('a.wav').create(recursive: true);
      await phone.run((journal, _) async => expect(journal.allEntries, isEmpty));
      expect(phone.audio('a.wav').existsSync(), isTrue);
    });

    test('overlapping writes run one at a time, via a temp file, newest last',
        () async {
      final writes = _WriteLog();
      await IOOverrides.runWithIOOverrides(
        () => phone.run((journal, _) async {
          await journal.upsert(entry('a'));
          await Future.wait([
            journal.edit(journal.byId('a')!, place: 'Wien'),
            journal.upsert(entry('b')),
            journal.edit(journal.byId('a')!, tags: ['x']),
          ]);
        }),
        writes,
      );
      expect(writes.count, 4, reason: 'every write goes through the temp file');
      expect(writes.maxInFlight, 1, reason: 'writes overlapped');
      await phone.run((journal, _) async {
        expect(journal.byId('a')!.place, 'Wien');
        expect(journal.byId('a')!.tags, ['x']);
        expect(journal.byId('b'), isNotNull);
      });
    });
  });

  group('review round 6', () {
    late Directory tmp;
    late FakeHub hub;
    late SyncEncryptor key;
    late Device phone;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('mars_log_review6_');
      hub = FakeHub();
      key = await SyncEncryptor.generate();
      phone = Device('phone', Directory('${tmp.path}/phone'));
    });
    tearDown(() => tmp.delete(recursive: true));

    test('H1: a corrupt index is set aside and its audio survives later writes',
        () async {
      await phone.dir.create(recursive: true);
      final index = File('${phone.dir.path}/entries.json');
      await index.writeAsString('[{"id": "old", tru');
      await phone.audio('old.wav').create(recursive: true);

      await phone.run((journal, _) async {
        expect(journal.allEntries, isEmpty);
        expect(journal.corruptIndex.value, isTrue);
        await journal.upsert(entry('new', audio: ['new.wav']));
      });
      await phone.audio('new.wav').create(recursive: true);

      // Next start: the new index reads fine, old.wav belongs to nobody.
      await phone.run((journal, _) async {
        expect(journal.corruptIndex.value, isTrue);
        final aside = await journal.corruptIndexFiles();
        expect(aside, hasLength(1));
        expect(await aside.single.readAsString(), '[{"id": "old", tru');
      });
      expect(phone.audio('old.wav').existsSync(), isTrue,
          reason: 'the orphan sweep deleted the recordings of the lost index');

      // Discarding the old index is the user's call; then the sweep resumes.
      await phone.run((journal, _) async => journal.discardCorruptIndexes());
      await phone.run((journal, _) async {
        expect(journal.corruptIndex.value, isFalse);
      });
      expect(phone.audio('old.wav').existsSync(), isFalse);
      expect(phone.audio('new.wav').existsSync(), isTrue);
    });

    test('after a corrupt index, a re-pair brings the entries back to their audio',
        () async {
      phone.prefs['flutter.sync_server_url'] = 'https://hub';
      await phone.run((j, _) async => j.upsert(entry('a', audio: ['a.wav'])));
      await phone.audio('a.wav').create(recursive: true);
      await phone.sync(hub, key);
      await phone.sync(hub, key); // the watermark now covers its own push

      await File('${phone.dir.path}/entries.json').writeAsString('[{"id": "a", tru');
      await phone.sync(hub, key);
      await phone.run((j, _) async {
        expect(j.byId('a'), isNull, reason: 'the pull watermark still says "seen"');
      });

      phone.prefs
        ..remove('flutter.log_sync_last_synced_at')
        ..removeWhere((k, _) => k.contains('last_seen'));
      await phone.sync(hub, key);
      await phone.run((j, _) async {
        expect(j.byId('a')?.audioFileNames, ['a.wav']);
      });
      expect(phone.audio('a.wav').existsSync(), isTrue);
    });

    test('a failed write is made good by the next one', () async {
      await phone.run((journal, _) async {
        await journal.upsert(entry('a'));
        final rev = journal.revision.value;
        final blocker = Directory('${phone.dir.path}/entries.json.tmp');
        await blocker.create();
        await expectLater(
            journal.edit(journal.byId('a')!, place: 'Wien'), throwsA(anything));
        expect(journal.revision.value, rev, reason: 'no revision for a failed write');
        await blocker.delete();
        await journal.edit(journal.byId('a')!, tags: ['x']);
        expect(journal.revision.value, rev + 1);
      });
      await phone.run((journal, _) async {
        expect(journal.byId('a')!.place, 'Wien');
        expect(journal.byId('a')!.tags, ['x']);
      });
    });

    test('H2: hub restore undoes a 30-day purge without wiping the phone',
        () async {
      final laptop =
          Device('laptop', Directory('${tmp.path}/laptop'), autoPurge: false);
      for (final d in [phone, laptop]) {
        d.prefs['flutter.sync_server_url'] = 'https://hub';
      }

      final trashedAt = DateTime.now().subtract(const Duration(days: 31));
      final e = entry('a', deletedAt: trashedAt, audio: ['a.wav'])
        ..changedAt = trashedAt;
      for (final d in [phone, laptop]) {
        await d.dir.create(recursive: true);
        await File('${d.dir.path}/entries.json')
            .writeAsString(jsonEncode([e.toJson()]));
      }
      await phone.audio('a.wav').create(recursive: true);
      await phone.run((j, _) async => j.upsert(entry('keep', audio: ['keep.wav'])));
      await phone.audio('keep.wav').create(recursive: true);

      await laptop.sync(hub, key);
      final snapshot = FakeHub()..push('laptop', [hub.row('a')!]);

      await phone.sync(hub, key); // purges 'a' after the round
      await tick();
      await phone.sync(hub, key); // pushes the tombstone, prunes the trace
      await laptop.sync(hub, key);
      expect(hub.row('a')!.deletedAt, isNotNull);

      // Recovery: hub from the snapshot, both devices re-paired (watermarks
      // reset), laptop first — and the phone's data left alone.
      hub = snapshot;
      void rePair(Device d) => d.prefs
        ..remove('flutter.log_sync_last_synced_at')
        ..removeWhere((k, _) => k.contains('last_seen'));
      rePair(laptop);
      await laptop.sync(hub, key);
      await laptop.run((j, _) async {
        expect(j.byId('a')?.deletedAt, isNotNull, reason: 'back in the trash');
        await j.restore(j.byId('a')!);
      });
      await tick();
      await laptop.sync(hub, key);

      rePair(phone);
      await phone.sync(hub, key);
      await tick();
      await phone.sync(hub, key);
      await phone.run((j, _) async {
        expect(j.byId('a')?.deletedAt, isNull);
        expect(j.byId('keep'), isNotNull);
      });
      expect(hub.row('a')!.deletedAt, isNull);
      expect(phone.audio('keep.wav').existsSync(), isTrue);
    });
  });
  group('analysis as its own item', () {
    /// What the laptop's analyzer does: write an analysis onto the stored
    /// entry, without touching the entry item's clock.
    Future<void> laptopAnalyzes(JournalRepository j, String id, String summary) async {
      final ok = await j.writeAnalysis(
        id,
        AnalysisResult(
          transcript: j.byId(id)!.transcript!,
          title: 'Laptop-Titel',
          summary: summary,
          moodLabel: 'gut',
          moodScore: 8,
          dimensions: const {'calm': 70},
          tags: ['vom Laptop'],
        ),
        model: 'ollama:test',
        version: 1,
        source: AnalysisSource.laptop,
        basis: transcriptBasis(j.byId(id)!.transcript),
      );
      expect(ok, isTrue);
    }

    test('the laptop replaces the pre-analysis, and a phone edit made meanwhile stays',
        () async {
      await phone.run((j, _) async {
        final e = entry('a', transcript: 'heute')
          ..summary = 'vom Handy'
          ..analysisSource = AnalysisSource.phone;
        await j.upsert(e);
        await j.saveAnalysis(j.byId('a')!, entryChanged: false);
      });
      await phone.sync(hub, key);
      await laptop.sync(hub, key);

      await tick();
      await laptop.run((j, _) => laptopAnalyzes(j, 'a', 'vom Laptop'));
      await tick();
      // Edited on the phone *after* the laptop's analysis, before any sync:
      // under one item per entry, one of the two would be lost.
      await phone.run((j, _) => j.setPlace(j.byId('a')!, 'Wien'));

      await laptop.sync(hub, key);
      await phone.sync(hub, key);
      await laptop.sync(hub, key);

      for (final d in [phone, laptop]) {
        await d.run((j, _) async {
          final e = j.byId('a')!;
          expect(e.place, 'Wien', reason: '${d.id}: phone edit lost');
          expect(e.summary, 'vom Laptop', reason: '${d.id}: laptop analysis lost');
          expect(e.analysisSource, AnalysisSource.laptop);
        });
      }
    });

    test('a summary edited by hand survives a later analysis', () async {
      await phone.run((j, _) => j.upsert(entry('a', transcript: 'heute')));
      await phone.sync(hub, key);
      await laptop.sync(hub, key);

      await tick();
      await phone.run((j, _) => j.edit(j.byId('a')!, summary: 'meine Worte', tags: ['eigen']));
      await phone.sync(hub, key);
      await laptop.sync(hub, key);
      await tick();
      await laptop.run((j, _) => laptopAnalyzes(j, 'a', 'vom Laptop'));
      await laptop.sync(hub, key);
      await phone.sync(hub, key);

      for (final d in [phone, laptop]) {
        await d.run((j, _) async {
          final e = j.byId('a')!;
          expect(e.summary, 'meine Worte', reason: d.id);
          expect(e.tags, ['eigen'], reason: d.id);
          expect(e.moodScore, 8, reason: '${d.id}: the rest of the analysis applies');
        });
      }
    });

    test("the laptop's title reaches the phone; a title set by hand stays", () async {
      await phone.run((j, _) async {
        await j.upsert(entry('a', transcript: 'eins'));
        await j.upsert(entry('b', transcript: 'zwei'));
      });
      await phone.sync(hub, key);
      await laptop.sync(hub, key);
      await tick();
      await phone.run((j, _) => j.edit(j.byId('b')!, title: 'Mein Titel'));
      await phone.sync(hub, key);
      await laptop.sync(hub, key);
      await tick();
      await laptop.run((j, _) async {
        await laptopAnalyzes(j, 'a', 'x');
        await laptopAnalyzes(j, 'b', 'y');
      });
      await laptop.sync(hub, key);
      await phone.sync(hub, key);

      await phone.run((j, _) async {
        expect(j.byId('a')!.title, 'Laptop-Titel');
        expect(j.byId('b')!.title, 'Mein Titel');
        expect(j.byId('b')!.summary, 'y', reason: 'the rest of the analysis applies');
      });
    });

    test('an item from before the split brings its analysis along', () async {
      final old = entry('a', transcript: 'alt')
        ..summary = 'von Gemini'
        ..moodScore = 6;
      final item = SyncItem(
        itemId: 'a',
        moduleId: 'mars_log',
        deviceId: 'old-phone',
        updatedAt: old.changedAt,
        payload: old.toJson(), // the old format: no 'v', analysis inside
      );
      hub.push('old-phone', [
        item.copyWith(payload: {'ciphertext': await key.encrypt(item.payload, aad: item.aad)}),
      ]);

      await laptop.sync(hub, key);
      await laptop.run((j, _) async {
        final e = j.byId('a')!;
        expect(e.summary, 'von Gemini');
        expect(e.moodScore, 6);
        expect(e.analysisChangedAt, old.changedAt);
        expect(e.analysisSource, isNull, reason: 'unknown source — the laptop redoes it');
      });
    });

    test('a purge removes both items, and the entry everywhere', () async {
      await phone.run((j, _) async {
        await j.upsert(entry('a', transcript: 'x')..summary = 's');
        await j.saveAnalysis(j.byId('a')!, entryChanged: false);
      });
      await phone.sync(hub, key);
      await laptop.sync(hub, key);
      await tick();
      await phone.run((j, _) async {
        await j.moveToTrash(j.byId('a')!);
        await j.purge(j.byId('a')!);
      });
      await phone.sync(hub, key);
      await laptop.sync(hub, key);

      expect(hub.row('a')!.isDeleted, isTrue);
      expect(hub.row('a$kAnalysisItemSuffix')!.isDeleted, isTrue);
      await laptop.run((j, _) async => expect(j.byId('a'), isNull));
    });

    test('an entry whose phone analysis failed is fine where an analysis exists', () async {
      await phone.run((j, _) => j.upsert(entry('a', transcript: 'x', status: EntryStatus.failed)
        ..errorMessage = 'Modell fehlt'));
      await phone.sync(hub, key);
      await laptop.sync(hub, key);
      await tick();
      await laptop.run((j, _) => laptopAnalyzes(j, 'a', 'vom Laptop'));
      await laptop.sync(hub, key);
      await phone.sync(hub, key);
      await phone.run((j, _) async {
        expect(j.byId('a')!.status, EntryStatus.ready);
        expect(j.byId('a')!.summary, 'vom Laptop');
      });
      await laptop.run((j, _) async => expect(j.byId('a')!.status, EntryStatus.ready));
    });
  });

}

/// Watches the journal's temp-file writes: how many, and how many at once
/// (from the temp write until its rename lands). Each write is slowed down
/// so writes that are not serialized would overlap.
final class _WriteLog extends IOOverrides {
  var count = 0;
  var inFlight = 0;
  var maxInFlight = 0;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.endsWith('.tmp') ? _LoggedFile(file, this) : file;
  }
}

class _LoggedFile implements File {
  final File _file;
  final _WriteLog _log;
  _LoggedFile(this._file, this._log);

  @override
  String get path => _file.path;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    _log.count++;
    _log.maxInFlight = max(_log.maxInFlight, ++_log.inFlight);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return _file.writeAsString(contents, mode: mode, encoding: encoding, flush: flush);
  }

  @override
  Future<File> rename(String newPath) async {
    try {
      return await _file.rename(newPath);
    } finally {
      _log.inFlight--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
