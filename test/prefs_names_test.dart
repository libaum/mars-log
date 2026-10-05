// The pull watermark lives under its pre-rename prefs key on every paired
// device (docs/adr/0001-relay-rename-keeps-hub-id-on-the-wire.md at the Mars
// root). A renamed key would make each device forget where it left off.
import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('pull watermark is read from the pre-rename prefs keys', () async {
    SharedPreferences.setMockInitialValues({
      'sync_server_url': 'https://relay.example',
      'log_sync_last_seen_seq': 42,
      'log_sync_last_seen_hub_id': 'R1',
    });
    final storage = await LocalStorageService.getInstance();
    expect(storage.getSyncServerUrl(), 'https://relay.example');
    expect(storage.getSyncLastSeenSeq(), 42);
    expect(storage.getSyncLastSeenRelayId(), 'R1');
  });

  test('pull watermark is written under the pre-rename prefs keys', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = await LocalStorageService.getInstance();
    await storage.setSyncPullWatermark(seq: 9, relayId: 'R2');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('log_sync_last_seen_seq'), 9);
    expect(prefs.getString('log_sync_last_seen_hub_id'), 'R2');
  });
}
