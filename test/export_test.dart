import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/data/export_service.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/location_history_repository.dart';
import 'package:mars_log/domain/day_location_point.dart';
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

  test('the export zip carries the location history', () async {
    final journal = await JournalRepository.getInstance(directory: tmp);
    final locations = await LocationHistoryRepository.getInstance();
    await locations.addPoint(_p(0));

    final bytes = await ExportService(journal, locations).buildZipBytes();
    final names = ZipDecoder().decodeBytes(bytes).map((f) => f.name);
    expect(names, contains('location_history.json'));
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
