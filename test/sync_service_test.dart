import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/sync/sync_service.dart';
import 'package:mars_sync/mars_sync.dart';

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

/// Holds the encryption-key write until [gate] opens, and the next token
/// read until [tokenGate] opens.
class _GatedKeys extends _MemoryKeys {
  Completer<void>? gate;
  Completer<void>? tokenGate;
  @override
  Future<String?> readDeviceToken() async {
    final g = tokenGate;
    tokenGate = null;
    if (g != null) await g.future;
    return super.readDeviceToken();
  }

  @override
  Future<void> writeEncryptionKey(String base64Key) async {
    final g = gate;
    if (g != null) await g.future;
    return super.writeEncryptionKey(base64Key);
  }
}

/// Holds the first key-check pull until [gate] opens — the window in which
/// the pairing can change under a running check.
class _GatedTransport extends FakeTransport {
  final Completer<void> gate;
  _GatedTransport(super.relay, super.deviceId, this.gate);

  @override
  Future<PullResult> pull(String moduleId, {required int sinceSeq}) async {
    if (moduleId == KeyCheck.moduleId) await gate.future;
    return super.pull(moduleId, sinceSeq: sinceSeq);
  }
}

/// In Mars Hub, mars_log's pairing is written by another module's screen and
/// the log follows via reload(). These pin down that a follower can never
/// push with a key it hasn't proven against the relay it now talks to.
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

  test('reload() makes the next round prove the key against the new relay', () async {
    await phone.run((journal, storage) async {
      final keys = _MemoryKeys();
      final sync = SyncService(
        storage: storage,
        journal: journal,
        keys: keys,
        transport: (uri, token) => FakeTransport(relayFor(uri), 'phone'),
      );
      await sync.init();
      await sync.pairDevice(serverUrl: 'https://a', token: 't');
      await sync.importEncryptionKey(keyA);
      await journal.upsert(entry('x'));
      await sync.syncNow();
      expect(sync.statusNotifier.value.phase, SyncPhase.idle);
      expect(relayA.row('x'), isNotNull);

      // Another module re-pairs the shared state to relay B; key A stays.
      await storage.setSyncServerUrl('https://b');
      await sync.reload();
      await sync.syncNow();

      expect(sync.statusNotifier.value.phase, SyncPhase.error);
      expect(relayB.row('x'), isNull, reason: 'pushed with a key relay B never saw');
    });
  });

  test('a key check that outlives a re-pair does not count for the new relay', () async {
    await phone.run((journal, storage) async {
      final keys = _MemoryKeys();
      final gate = Completer<void>();
      final sync = SyncService(
        storage: storage,
        journal: journal,
        keys: keys,
        transport: (uri, token) => uri.host == 'a'
            ? _GatedTransport(relayA, 'phone', gate)
            : FakeTransport(relayB, 'phone'),
      );
      // Paired to A with key A, never verified in this process.
      await storage.setSyncServerUrl('https://a');
      await keys.writeDeviceToken('t');
      await keys.writeDeviceId('phone');
      await keys.writeEncryptionKey(keyA);
      await sync.init();
      await journal.upsert(entry('x'));

      final round = sync.syncNow(); // key check against A, held at the gate
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await storage.setSyncServerUrl('https://b');
      await sync.reload();
      gate.complete(); // A answers "ok" — about a relay no longer in use
      await round;

      await sync.syncNow();
      expect(sync.statusNotifier.value.phase, SyncPhase.error);
      expect(relayB.row('x'), isNull);
    });
  });

  test('a key import that outlives a re-pair does not count for the new relay', () async {
    // Review round 5, L1: the check passed against A, the re-pair to B landed
    // while the key was being written, and B was then marked verified.
    await phone.run((journal, storage) async {
      final keys = _GatedKeys();
      final sync = SyncService(
        storage: storage,
        journal: journal,
        keys: keys,
        transport: (uri, token) => FakeTransport(relayFor(uri), 'phone'),
      );
      await storage.setSyncServerUrl('https://a');
      await keys.writeDeviceToken('t');
      await keys.writeDeviceId('phone');
      await sync.init();
      await journal.upsert(entry('x'));

      keys.gate = Completer<void>();
      final import = sync.importEncryptionKey(keyA);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await storage.setSyncServerUrl('https://b');
      await sync.reload();
      keys.gate!.complete();
      await import;

      await sync.syncNow();
      expect(relayB.row('x'), isNull, reason: 'pushed to relay B with a key B never saw');
    });
  });

  test('a re-pair during the key import\'s engine rebuild wins, unverified',
      () async {
    await phone.run((journal, storage) async {
      final keys = _GatedKeys();
      final sync = SyncService(
        storage: storage,
        journal: journal,
        keys: keys,
        transport: (uri, token) => FakeTransport(relayFor(uri), 'phone'),
      );
      await storage.setSyncServerUrl('https://a');
      await keys.writeDeviceToken('t');
      await keys.writeDeviceId('phone');
      await sync.init();
      await journal.upsert(entry('x'));

      // Checked against A and written; the rebuild then stalls on its token
      // read while the pairing moves to B.
      keys.tokenGate = Completer<void>();
      final gate = keys.tokenGate!;
      final import = sync.importEncryptionKey(keyA);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await storage.setSyncServerUrl('https://b');
      await sync.reload();
      gate.complete();
      await import;

      await sync.syncNow();
      expect(sync.statusNotifier.value.phase, SyncPhase.error,
          reason: 'the stale rebuild pointed the engine back at relay A');
      expect(relayB.row('x'), isNull, reason: 'pushed to relay B with a key B never saw');
    });
  });
}
