import 'package:flutter/foundation.dart';
import 'package:mars_sync/mars_sync.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/sync/journal_sync_repository.dart';
import 'package:mars_log/sync/secure_sync_key_store.dart';

enum SyncPhase { unpaired, idle, syncing, error }

class SyncStatus {
  final SyncPhase phase;
  final DateTime? lastSyncedAt;
  final String? error;

  /// Non-fatal: items on the hub this device couldn't read last round.
  final int undecryptable;

  const SyncStatus({
    required this.phase,
    this.lastSyncedAt,
    this.error,
    this.undecryptable = 0,
  });

  bool get isPaired => phase != SyncPhase.unpaired;
}

/// Thrown by pairing/import when the input is unusable before anything is
/// stored — the message is safe to show verbatim.
class SyncSetupException implements Exception {
  final String message;
  SyncSetupException(this.message);
  @override
  String toString() => message;
}

/// Owns mars_log's sync lifecycle: pairing (server URL, device
/// token, encryption key), the wired-up [MarsSyncEngine], and a single
/// `syncNow()` that the UI and app lifecycle can call freely — overlapping
/// calls collapse into the one already running.
///
/// The three pairing steps are independent so a device can be paired in any
/// order; sync only runs once all of them are in place — and, before the
/// first push of real data, only after the key has been verified against the
/// hub's key-check item (see [KeyCheck]).
class SyncService {
  final LocalStorageService _storage;
  final JournalRepository _journal;
  final SyncKeyStore _keys;

  final statusNotifier = ValueNotifier<SyncStatus>(
    const SyncStatus(phase: SyncPhase.unpaired),
  );

  MarsSyncEngine? _engine;
  SyncTransport? _client;
  SyncEncryptor? _encryptor;
  String? _deviceId;
  bool _keyVerified = false;

  /// Bumped on every change to the pairing (pair, key, unpair, reload). A key
  /// check still running when it moves on answers a question about a hub or
  /// key this service no longer uses — its result must not count.
  int _generation = 0;

  final SyncTransport Function(Uri baseUrl, String token) _transport;
  Future<void>? _inFlight;

  /// [keys] defaults to the Android Keystore-backed store; the desktop hub
  /// passes a file-backed one.
  SyncService({
    required LocalStorageService storage,
    required JournalRepository journal,
    SyncKeyStore? keys,
    @visibleForTesting SyncTransport Function(Uri baseUrl, String token)? transport,
  })  : _storage = storage,
        _journal = journal,
        _keys = keys ?? SecureSyncKeyStore(),
        _transport = transport ??
            ((baseUrl, token) => SyncClient(baseUrl: baseUrl, deviceToken: token));

  void _pairingChanged() {
    _keyVerified = false;
    _generation++;
  }

  /// Never throws: a broken secure-storage (backup restore, keystore reset)
  /// must not take the whole app down with it — the journal lives in its own
  /// file and is unaffected.
  Future<void> init() async {
    try {
      await _rebuildEngine();
    } on FormatException {
      // The store answered, but what's in it can't be used (garbled key or
      // hub URL). Different remedy than a dead keystore: re-pair.
      _engine = null;
      _publish(SyncPhase.error, error: 'Gespeicherte Kopplung ist ungültig — entkoppeln und neu koppeln');
    } catch (e) {
      _engine = null;
      _publish(SyncPhase.error, error: 'Sicherer Speicher nicht verfügbar');
    }
  }

  /// Re-reads the pairing from storage and forgets that the key was ever
  /// verified. For the desktop hub, where the hub URL and the secrets are
  /// shared with the other modules and paired through one of them: after
  /// any change there, this module must prove its key against the hub again
  /// before it may push — otherwise a re-pair to a different hub would skip
  /// the key check entirely.
  Future<void> reload() async {
    _pairingChanged();
    await init();
  }

  String? get serverUrl => _storage.getSyncServerUrl();

  Future<String?> get deviceId => _keys.readDeviceId();

  Future<bool> get hasEncryptionKey async =>
      (await _keys.readEncryptionKey()) != null;

  Future<bool> get hasDeviceToken async =>
      (await _keys.readDeviceToken()) != null;

  /// Stores the hub URL and device token, then asks the hub which device id
  /// the token belongs to — the user never retypes the name they registered
  /// on the server. Throws if the hub rejects the token or is unreachable.
  ///
  /// Plain `http://` is only accepted in debug builds (LAN testing against a
  /// hub on the laptop); the release build talks TLS or not at all.
  Future<void> pairDevice({required String serverUrl, required String token}) async {
    final trimmedUrl = serverUrl.trim();
    final trimmedToken = token.trim();
    final uri = Uri.tryParse(trimmedUrl);
    if (uri == null || uri.host.isEmpty) {
      throw SyncSetupException('Keine gültige URL');
    }
    if (uri.scheme != 'https' && !(kDebugMode && uri.scheme == 'http')) {
      throw SyncSetupException('Hub-URL muss mit https:// beginnen');
    }
    if (trimmedToken.isEmpty) throw SyncSetupException('Token ist leer');

    final client = _transport(uri, trimmedToken);
    final deviceId = await client.whoami();

    await _storage.setSyncServerUrl(trimmedUrl);
    await _keys.writeDeviceToken(trimmedToken);
    await _keys.writeDeviceId(deviceId);
    // A (re-)pair may point at a different hub: forget where pulls left off
    // (the engine also detects a changed hub_id by itself) and re-verify the
    // key against whatever hub this is.
    await _storage.setSyncPullWatermark(seq: null, hubId: null);
    _pairingChanged();
    await _rebuildEngine();
  }

  /// First device only: mints the shared encryption key. Returns it encoded
  /// for transfer to the other devices — and for backing up, because there
  /// is no way to recover it from the hub.
  Future<String> generateEncryptionKey() async {
    final encryptor = await SyncEncryptor.generate();
    final exported = await encryptor.exportKey();
    await _keys.writeEncryptionKey(exported);
    _pairingChanged();
    await _rebuildEngine();
    return exported;
  }

  /// Every other device: takes the key generated elsewhere. Rejects
  /// anything that isn't a 32-byte key outright; if the hub is already
  /// paired, verifies against its key-check item before storing, so a
  /// mistyped key can never push a single item.
  Future<void> importEncryptionKey(String encoded) async {
    final trimmed = encoded.trim();
    final SyncEncryptor encryptor;
    try {
      encryptor = SyncEncryptor.importKey(trimmed);
    } on FormatException catch (e) {
      throw SyncSetupException('Kein gültiger Schlüssel: ${e.message}');
    }

    final client = _client;
    final deviceId = _deviceId;
    final generation = _generation;
    var verified = false;
    if (client != null && deviceId != null) {
      final outcome =
          await KeyCheck(client: client, encryptor: encryptor, deviceId: deviceId).run();
      if (outcome == KeyCheckOutcome.mismatch) {
        throw SyncSetupException(
          'Dieser Schlüssel passt nicht zu dem, der auf dem Hub schon verwendet wird',
        );
      }
      // Only if nothing re-paired while the check ran.
      verified = generation == _generation;
    }

    await _keys.writeEncryptionKey(trimmed);
    // A re-pair may also land while the key is written or the engine is
    // rebuilt; the check then was against a hub this service no longer uses.
    verified = verified && generation == _generation;
    _pairingChanged();
    final mine = _generation;
    await _rebuildEngine();
    // Set after the rebuild, which is itself a pairing change: the check
    // above was for exactly this key against exactly this hub.
    if (verified && mine == _generation) _keyVerified = true;
  }

  Future<String?> exportEncryptionKey() => _keys.readEncryptionKey();

  /// Drops pairing and key. The hub keeps its (ciphertext) copy of every
  /// entry; local entries stay as they are. Both watermarks reset so a
  /// later re-pair does one full round again.
  Future<void> unpair() async {
    await _keys.clear();
    await _storage.setSyncServerUrl(null);
    await _storage.setSyncLastSyncedAt(null);
    await _storage.setSyncPullWatermark(seq: null, hubId: null);
    _pairingChanged();
    await _rebuildEngine();
  }

  /// Runs one push/pull round. Never throws — outcome lands in
  /// [statusNotifier] — so it's safe to fire from lifecycle callbacks.
  Future<void> syncNow() {
    final running = _inFlight;
    if (running != null) return running;
    final future = _run().whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<void> _run() async {
    final engine = _engine;
    if (engine == null) return;
    final generation = _generation;
    _publish(SyncPhase.syncing);
    try {
      if (!_keyVerified) {
        final outcome = await KeyCheck(
          client: _client!,
          encryptor: _encryptor!,
          deviceId: _deviceId!,
        ).run();
        // Re-paired while the check ran: its answer is about the old pairing.
        // The rebuild already published the new state; the next round checks
        // the new pairing from scratch.
        if (generation != _generation) return;
        if (outcome == KeyCheckOutcome.mismatch) {
          _publish(SyncPhase.error, error: 'Schlüssel passt nicht zum Hub');
          return;
        }
        _keyVerified = true;
      }
      final result = await engine.syncNow();
      _publish(SyncPhase.idle, undecryptable: result.undecryptable);
    } catch (e) {
      _publish(SyncPhase.error, error: _describe(e));
    }
  }

  Future<void> _rebuildEngine() async {
    final generation = _generation;
    final url = _storage.getSyncServerUrl();
    final token = await _keys.readDeviceToken();
    final key = await _keys.readEncryptionKey();
    final deviceId = await _keys.readDeviceId();
    // The pairing changed while the keys were read: a newer rebuild runs (or
    // ran) for it. Finishing this one would point the engine at the old hub.
    if (generation != _generation) return;

    _client = (url != null && token != null)
        ? _transport(Uri.parse(url), token)
        : null;
    _deviceId = deviceId;
    _encryptor = key != null ? SyncEncryptor.importKey(key) : null;

    if (_client == null || _encryptor == null || deviceId == null) {
      _engine = null;
      _publish(SyncPhase.unpaired);
      return;
    }

    _engine = MarsSyncEngine(
      repository: JournalSyncRepository(
        journal: _journal,
        storage: _storage,
        deviceId: deviceId,
      ),
      client: _client!,
      encryptor: _encryptor!,
    );
    _publish(SyncPhase.idle);
  }

  void _publish(SyncPhase phase, {String? error, int undecryptable = 0}) {
    statusNotifier.value = SyncStatus(
      phase: phase,
      lastSyncedAt: _storage.getSyncLastSyncedAt(),
      error: error,
      undecryptable: undecryptable,
    );
  }

  String _describe(Object e) {
    if (e is SyncClientException) {
      return switch (e.statusCode) {
        401 => 'Hub hat das Geräte-Token abgelehnt',
        429 => 'Hub bremst dieses Gerät (Rate-Limit)',
        null => 'Hub nicht erreichbar',
        // The hub's own explanation ("updated_at is in the future — this
        // device's clock is ahead of the hub") beats a bare status code.
        final code => e.detail == null ? 'Hub-Fehler $code' : 'Hub-Fehler $code: ${e.detail}',
      };
    }
    return 'Sync fehlgeschlagen';
  }
}
