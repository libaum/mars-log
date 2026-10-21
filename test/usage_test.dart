import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/data/export_service.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/location_history_repository.dart';
import 'package:mars_log/data/usage_repository.dart';
import 'package:mars_log/domain/usage_day.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _Paths extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  final Directory dir;
  _Paths(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;
  @override
  Future<String?> getTemporaryPath() async => '${dir.path}/tmp';
}

int _ms(int day, int hour, [int minute = 0]) =>
    DateTime(2026, 10, day, hour, minute).millisecondsSinceEpoch;

UsageEvent _open(int at, [String app = 'com.whatsapp']) =>
    UsageEvent(at, app, UsageEventType.activityResumed);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mars_log_usage_');
    await Directory('${tmp.path}/tmp').create();
    PathProviderPlatform.instance = _Paths(tmp);
  });

  tearDown(() => tmp.delete(recursive: true));

  group('UsageDay', () {
    test('survives its compact JSON unchanged', () {
      final day = UsageDay('2026-10-21', [
        _open(_ms(21, 9)),
        UsageEvent(_ms(21, 9, 5), 'com.whatsapp', UsageEventType.activityPaused),
        UsageEvent(_ms(21, 9, 5), '', UsageEventType.screenNonInteractive),
        _open(_ms(21, 8), 'org.mozilla.firefox'),
      ], changedAt: DateTime(2026, 10, 21, 12));
      final back = UsageDay.fromJson(day.toJson());
      expect(back.events, day.events);
      expect(back.events.first.app, 'org.mozilla.firefox', reason: 'sorted by time');
      expect(back.changedAt, day.changedAt);
      expect(back.id, 'usage:2026-10-21');
    });

    test('merging takes only events not held yet', () {
      final day = UsageDay('2026-10-21', [_open(_ms(21, 9))], changedAt: DateTime(2026));
      expect(day.merge([_open(_ms(21, 9)), _open(_ms(21, 10))]), 1);
      expect(day.events.length, 2);
    });
  });

  group('UsageRepository', () {
    test('events land on their local day, across midnight', () async {
      final repo = await UsageRepository.open(directory: tmp);
      await repo.addEvents([_open(_ms(20, 23, 59)), _open(_ms(21, 0, 1))]);
      expect(await repo.days(), ['2026-10-20', '2026-10-21']);
      expect((await repo.day('2026-10-21'))!.events.single.at, _ms(21, 0, 1));
    });

    test('collecting the same stretch twice stores it once and keeps the clock', () async {
      final repo = await UsageRepository.open(directory: tmp);
      final events = [_open(_ms(21, 9)), _open(_ms(21, 10))];
      expect(await repo.addEvents(events, now: DateTime(2026, 10, 21, 11)), 2);
      expect(await repo.addEvents(events, now: DateTime(2026, 10, 21, 17)), 0);
      final day = (await repo.day('2026-10-21'))!;
      expect(day.events.length, 2);
      expect(day.changedAt, DateTime(2026, 10, 21, 11));
    });

    test('changedSince picks the days collected since', () async {
      final repo = await UsageRepository.open(directory: tmp);
      await repo.addEvents([_open(_ms(20, 9))], now: DateTime(2026, 10, 20, 12));
      await repo.addEvents([_open(_ms(21, 9))], now: DateTime(2026, 10, 21, 12));
      // The files were written just now; only the stamp tells the days apart.
      final changed = await repo.changedSince(DateTime(2026, 10, 21));
      expect(changed.map((d) => d.day), ['2026-10-21']);
      expect((await repo.changedSince(null)).length, 2);
    });

    test('a synced day merges in and never moves the clock back', () async {
      final repo = await UsageRepository.open(directory: tmp);
      await repo.addEvents([_open(_ms(21, 9))], now: DateTime(2026, 10, 21, 12));
      await repo.applySynced(UsageDay('2026-10-21', [_open(_ms(21, 8))],
          changedAt: DateTime(2026, 10, 21, 10)));
      final day = (await repo.day('2026-10-21'))!;
      expect(day.events.length, 2);
      expect(day.changedAt, DateTime(2026, 10, 21, 12));
    });

    test('labels only grow', () async {
      final repo = await UsageRepository.open(directory: tmp);
      await repo.addLabels({'com.whatsapp': 'WhatsApp'}, now: DateTime(2026, 10, 21));
      await repo.addLabels({'com.whatsapp': 'WhatsApp'}, now: DateTime(2026, 10, 22));
      expect((await repo.apps()).changedAt, DateTime(2026, 10, 21), reason: 'nothing new');
      await repo.applySyncedApps(UsageApps({'org.mozilla.firefox': 'Firefox'},
          changedAt: DateTime(2026, 10, 20)));
      expect((await repo.apps()).labels.keys, containsAll(['com.whatsapp', 'org.mozilla.firefox']));
    });

    test('the collection mark is kept', () async {
      final repo = await UsageRepository.open(directory: tmp);
      expect(await repo.lastCollected(), isNull);
      await repo.setLastCollected(DateTime(2026, 10, 21, 12));
      expect(await repo.lastCollected(), DateTime(2026, 10, 21, 12));
    });
  });

  test('the export zip carries the usage record and import restores it', () async {
    final journal = await JournalRepository.getInstance(directory: tmp);
    final locations = await LocationHistoryRepository.getInstance();
    final usage = await UsageRepository.open(directory: tmp);
    await usage.addEvents([_open(_ms(21, 9))]);
    await usage.addLabels({'com.whatsapp': 'WhatsApp'});

    final zip = await ExportService(journal, locations, usage: usage).buildZipFile();
    final names = ZipDecoder().decodeBytes(await zip.readAsBytes()).map((f) => f.name);
    expect(names, containsAll(['usage/days/2026-10-21.json', 'usage/apps.json']));
    expect(names.where((n) => n.contains('state') || n.endsWith('.tmp')), isEmpty);

    final other = Directory('${tmp.path}/other')..createSync();
    final usage2 = await UsageRepository.open(directory: other);
    final journal2 = await JournalRepository.getInstance(directory: other);
    await ExportService(journal2, locations, usage: usage2).importZip(zip);
    expect((await usage2.day('2026-10-21'))!.events.single, _open(_ms(21, 9)));
    expect((await usage2.apps()).labels['com.whatsapp'], 'WhatsApp');
  });
}
