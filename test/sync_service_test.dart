import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/sync/sync_service.dart';
import 'package:mars_sync/mars_sync.dart';

import 'sync_test.dart' show FakeHub, FakeTransport, Device, entry;

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

/// Holds the first key-check pull until [gate] opens — the window in which
/// the pairing can change under a running check.
class _GatedTransport extends FakeTransport {
  final Completer<void> gate;
  _GatedTransport(super.hub, super.deviceId, this.gate);

  @override
  Future<PullResult> pull(String moduleId, {required int sinceSeq}) async {
    if (moduleId == KeyCheck.moduleId) await gate.future;
    return super.pull(moduleId, sinceSeq: sinceSeq);
  }
}

/// On the hub, mars_log's pairing is written by another module's screen and
/// the log follows via reload(). These pin down that a follower can never
/// push with a key it hasn't proven against the hub it now talks to.
void main() {
  late Directory tmp;
  late Device phone;
  late FakeHub hubA;
  late FakeHub hubB;
  late String keyA;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mars_log_service_');
    phone = Device('phone', Directory('${tmp.path}/phone'));
    hubA = FakeHub();
    hubB = FakeHub();
    final a = await SyncEncryptor.generate();
    keyA = await a.exportKey();
    // Each hub already knows its own key (registered by some first device).
    await KeyCheck(client: FakeTransport(hubA, 'first'), encryptor: a, deviceId: 'first').run();
    final b = await SyncEncryptor.generate();
    await KeyCheck(client: FakeTransport(hubB, 'first'), encryptor: b, deviceId: 'first').run();
  });

  tearDown(() => tmp.delete(recursive: true));

  FakeHub hubFor(Uri uri) => uri.host == 'a' ? hubA : hubB;

  test('reload() makes the next round prove the key against the new hub', () async {
    await phone.run((journal, storage) async {
      final keys = _MemoryKeys();
      final sync = SyncService(
        storage: storage,
        journal: journal,
        keys: keys,
        transport: (uri, token) => FakeTransport(hubFor(uri), 'phone'),
      );
      await sync.init();
      await sync.pairDevice(serverUrl: 'https://a', token: 't');
      await sync.importEncryptionKey(keyA);
      await journal.upsert(entry('x'));
      await sync.syncNow();
      expect(sync.statusNotifier.value.phase, SyncPhase.idle);
      expect(hubA.row('x'), isNotNull);

      // Another module re-pairs the shared state to hub B; key A stays.
      await storage.setSyncServerUrl('https://b');
      await sync.reload();
      await sync.syncNow();

      expect(sync.statusNotifier.value.phase, SyncPhase.error);
      expect(hubB.row('x'), isNull, reason: 'pushed with a key hub B never saw');
    });
  });

  test('a key check that outlives a re-pair does not count for the new hub', () async {
    await phone.run((journal, storage) async {
      final keys = _MemoryKeys();
      final gate = Completer<void>();
      final sync = SyncService(
        storage: storage,
        journal: journal,
        keys: keys,
        transport: (uri, token) => uri.host == 'a'
            ? _GatedTransport(hubA, 'phone', gate)
            : FakeTransport(hubB, 'phone'),
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
      gate.complete(); // A answers "ok" — about a hub no longer in use
      await round;

      await sync.syncNow();
      expect(sync.statusNotifier.value.phase, SyncPhase.error);
      expect(hubB.row('x'), isNull);
    });
  });
}
