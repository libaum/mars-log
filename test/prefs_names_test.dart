// Paired devices store the sync ledger under these names; the pull watermark
// keeps its pre-rename `hub_id` (docs/adr/0001-relay-rename-keeps-hub-id-on-the-wire.md
// at the Mars root). A renamed key would make each device forget where it
// left off. The ledger's own tests pin the names per prefix; this pins ours.
import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/sync/pairing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the ledger reads what earlier builds stored', () async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({
      'sync_server_url': 'https://relay.example',
      'log_sync_paired': true,
      'log_sync_last_synced_at': 1000,
      'log_sync_last_seen_seq': 42,
      'log_sync_last_seen_hub_id': 'R1',
      'log_sync_purged': '{"a":[500,1000]}',
    });
    final ledger = logLedger(await SharedPreferences.getInstance());
    expect(ledger.serverUrl, 'https://relay.example');
    expect(ledger.paired, isTrue);
    expect(ledger.lastSyncedAt, DateTime.fromMillisecondsSinceEpoch(1000));
    expect(ledger.pullWatermark!.seq, 42);
    expect(ledger.pullWatermark!.relayId, 'R1');
    expect(ledger.purged['a']!.stamp, DateTime.fromMillisecondsSinceEpoch(500));
  });
}
