import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:mars_log/domain/day_location_point.dart';

/// Owns `location_history.json`: background GPS fixes bucketed by calendar
/// date (`yyyy-MM-dd`), independent of [JournalEntry] — a day's route stays
/// put even if its journal entry is recorded, or backdated, later.
///
/// Same load/persist shape as `JournalRepository`: the whole map is held in
/// memory and rewritten on every mutation. Must be constructible standalone
/// (no GetIt) since the WorkManager background isolate creates its own
/// instance rather than reusing the app's singleton.
class LocationHistoryRepository {
  static const _fileName = 'location_history.json';

  late final Directory _docsDir;
  final Map<String, List<DayLocationPoint>> _byDay = {};

  LocationHistoryRepository._();

  static Future<LocationHistoryRepository> getInstance() async {
    final repo = LocationHistoryRepository._();
    await repo._load();
    return repo;
  }

  Future<void> _load() async {
    _docsDir = await getApplicationDocumentsDirectory();
    final file = File(_path);
    if (!await file.exists()) return;
    try {
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _byDay
        ..clear()
        ..addAll(map.map((key, value) => MapEntry(
              key,
              (value as List<dynamic>)
                  .map((e) =>
                      DayLocationPoint.fromJson((e as Map).cast<String, dynamic>()))
                  .toList(),
            )));
    } catch (_) {
      // Corrupt file → start empty rather than crash.
    }
  }

  String get _path => '${_docsDir.path}/$_fileName';

  String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Points recorded on [day] (any time-of-day component is ignored).
  List<DayLocationPoint> pointsForDay(DateTime day) =>
      List.unmodifiable(_byDay[_dayKey(day)] ?? const []);

  /// All days with at least one point — for a future map/route screen.
  Map<String, List<DayLocationPoint>> get byDay => Map.unmodifiable(_byDay);

  /// Appends [point], bucketed by its own (local) date, and persists.
  Future<void> addPoint(DayLocationPoint point) async {
    final key = _dayKey(point.timestamp);
    (_byDay[key] ??= []).add(point);
    await _persist();
  }

  Future<void> _persist() async {
    final json = jsonEncode(_byDay.map(
      (key, points) => MapEntry(key, points.map((p) => p.toJson()).toList()),
    ));
    await File(_path).writeAsString(json);
  }
}
