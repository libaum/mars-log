import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/data/export_service.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/location_history_repository.dart';
import 'package:mars_log/domain/day_location_point.dart';
import 'package:mars_log/domain/journal_entry.dart';
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

DayLocationPoint _p(int minute) => DayLocationPoint(
      latitude: 48.2,
      longitude: 16.37,
      timestamp: DateTime(2026, 9, 1, 12, minute),
    );

JournalEntry _entry(String id, List<String> audio) => JournalEntry(
      id: id,
      createdAt: DateTime(2026, 9, 1, 8),
      day: DateTime(2026, 9, 1),
      audioFileNames: [...audio],
      status: EntryStatus.ready,
      transcript: 'text',
    );

/// The location history is in no other backup (no sync, no Google
/// auto-backup), so the export zip must carry it and import must restore it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mars_log_export_');
    await Directory('${tmp.path}/tmp').create();
    PathProviderPlatform.instance = _Paths(tmp);
  });

  tearDown(() => tmp.delete(recursive: true));

  test('the export zip carries the location history and the audio', () async {
    final journal = await JournalRepository.getInstance(directory: tmp);
    final locations = await LocationHistoryRepository.getInstance();
    await locations.addPoint(_p(0));
    await File(journal.audioPath('a.m4a')).writeAsString('ton');
    await journal.upsert(_entry('a', ['a.m4a']));

    final zip = await ExportService(journal, locations).buildZipFile();
    final names = ZipDecoder().decodeBytes(await zip.readAsBytes()).map((f) => f.name);
    expect(names, containsAll(['entries.json', 'location_history.json', 'audio/a.m4a']));
  });

  test('importing an export on a fresh device brings entries and audio back', () async {
    final journal = await JournalRepository.getInstance(directory: tmp);
    final locations = await LocationHistoryRepository.getInstance();
    await File(journal.audioPath('a.m4a')).writeAsString('ton');
    await journal.upsert(_entry('a', ['a.m4a']));
    final zip = await ExportService(journal, locations).buildZipFile();

    final fresh = await Directory.systemTemp.createTemp('mars_log_fresh_');
    addTearDown(() => fresh.delete(recursive: true));
    await Directory('${fresh.path}/tmp').create();
    PathProviderPlatform.instance = _Paths(fresh);
    final journal2 = await JournalRepository.getInstance(directory: fresh);
    final service2 = ExportService(journal2, await LocationHistoryRepository.getInstance());

    expect(await service2.importZip(zip), 1);
    final e = journal2.byId('a')!;
    expect(e.audioFileNames, ['a.m4a']);
    expect(e.audioDeleted, isFalse);
    expect(await File(journal2.audioPath('a.m4a')).readAsString(), 'ton');
  });

  test('an old export without audio imports its entries as "audio discarded"', () async {
    final journal = await JournalRepository.getInstance(directory: tmp);
    final old = ZipFileEncoder()..create('${tmp.path}/old.zip');
    final index = File('${tmp.path}/old_entries.json')
      ..writeAsStringSync(jsonEncode([_entry('b', ['b.m4a']).toJson()]));
    await old.addFile(index, 'entries.json');
    await old.close();

    final service = ExportService(journal, await LocationHistoryRepository.getInstance());
    expect(await service.importZip(File('${tmp.path}/old.zip')), 1);
    expect(journal.byId('b')!.audioDeleted, isTrue);
    expect(journal.byId('b')!.audioFileNames, isEmpty);
  });

  test('merging an export adds missing points once', () async {
    final locations = await LocationHistoryRepository.getInstance();
    await locations.addPoint(_p(0));

    final exported = [_p(0), _p(5), _p(10)];
    expect(await locations.mergeExported(exported), 2);
    expect(await locations.mergeExported(exported), 0);

    final onDisk = jsonDecode(await locations.file.readAsString()) as Map;
    expect((onDisk['2026-09-01'] as List).length, 3);
  });
}
