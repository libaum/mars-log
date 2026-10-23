import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/sync/journal_sync_items.dart';
import 'package:mars_log/sync/pairing.dart';
import 'package:mars_sync/mars_sync.dart';
import 'package:mars_sync_flutter/mars_sync_flutter.dart';

import 'sync_test.dart' show FakeRelay, FakeTransport, Device, entry;

class _MemoryKeys implements SyncKeyStore {
  final _values = <String, String>{};
  @override
  Future<void> clear() async => _values.clear();
  @override
  Future<String?> readDeviceId() async => _values['id'];
  @override
  Future<String?> readDeviceToken() async => _values['token'];
  @override
  Future<String?> readEncryptionKey() async => _values['key'];
  @override
  Future<void> writeDeviceId(String deviceId) async => _values['id'] = deviceId;
  @override
  Future<void> writeDeviceToken(String token) async => _values['token'] = token;
  @override
  Future<void> writeEncryptionKey(String base64Key) async => _values['key'] = base64Key;
}

/// mars_log's wiring of the shared SyncService: the real journal behind it,
/// the paired mirror its 30-day purge reads. The service's own guarantees
/// (key check, generation guard, overlapping rounds) are pinned in
/// mars_sync_flutter's tests.
SyncService _logSync(
  JournalRepository journal,
  SyncLedger ledger,
  SyncKeyStore keys,
  SyncTransport Function(Uri uri, String token) transport,
) =>
    SyncService.module(
      ledger: ledger,
      keys: keys,
      items: (deviceId) => JournalSyncItems(journal: journal, deviceId: deviceId),
      strings: logSyncStrings,
      transport: transport,
    );

void main() {
  late Directory tmp;
  late Device phone;
  late FakeRelay relayA;
  late FakeRelay relayB;
  late String keyA;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mars_log_service_');
    phone = Device('phone', Directory('${tmp.path}/phone'));
    relayA = FakeRelay();
    relayB = FakeRelay();
    final a = await SyncEncryptor.generate();
    keyA = await a.exportKey();
    // Each relay already knows its own key (registered by some first device).
    await KeyCheck(client: FakeTransport(relayA, 'first'), encryptor: a, deviceId: 'first').run();
    final b = await SyncEncryptor.generate();
    await KeyCheck(client: FakeTransport(relayB, 'first'), encryptor: b, deviceId: 'first').run();
  });

  tearDown(() => tmp.delete(recursive: true));

  FakeRelay relayFor(Uri uri) => uri.host == 'a' ? relayA : relayB;

  // In Mars Hub, mars_log's pairing is written by another module's screen and
  // the log follows via reload(): a follower never pushes with a key it
  // hasn't proven against the relay it now talks to.
  test('reload() makes the next round prove the key against the new relay', () async {
    await phone.run((journal, ledger) async {
      final keys = _MemoryKeys();
      final sync = _logSync(
        journal,
        ledger,
        keys,
        (uri, token) => FakeTransport(relayFor(uri), 'phone'),
      );
      await sync.init();
      await sync.pairDevice(serverUrl: 'https://a', token: 't');
      await sync.importEncryptionKey(keyA);
      await journal.upsert(entry('x'));
      await sync.syncNow();
      expect(sync.statusNotifier.value.phase, SyncPhase.idle);
      expect(relayA.row('x'), isNotNull);

      // Another module re-pairs the shared state to relay B; key A stays.
      await ledger.setServerUrl('https://b');
      await sync.reload();
      await sync.syncNow();

      expect(sync.statusNotifier.value.phase, SyncPhase.error);
      expect(relayB.row('x'), isNull, reason: 'pushed with a key relay B never saw');
    });
  });

  group('the 30-day purge waits only while paired', () {
    test('a relay URL without a key does not defer it', () async {
      await phone.run((journal, ledger) async {
        final sync = _logSync(
          journal,
          ledger,
          _MemoryKeys(),
          (uri, token) => FakeTransport(relayFor(uri), 'phone'),
        );
        await sync.init();
        await sync.pairDevice(serverUrl: 'https://a', token: 't');
        expect(sync.statusNotifier.value.isPaired, isFalse);
        expect(SyncPurgeTrace(ledger).defersAutoPurge, isFalse);

        await sync.importEncryptionKey(keyA);
        expect(sync.statusNotifier.value.isPaired, isTrue);
        expect(SyncPurgeTrace(ledger).defersAutoPurge, isTrue);

        await sync.unpair();
        expect(SyncPurgeTrace(ledger).defersAutoPurge, isFalse);
      });
    });

    test('before the first rebuild after the update, a stored URL still defers', () async {
      await phone.run((journal, ledger) async {
        await ledger.setServerUrl('https://a');
        expect(SyncPurgeTrace(ledger).defersAutoPurge, isTrue);
      });
    });
  });
}
