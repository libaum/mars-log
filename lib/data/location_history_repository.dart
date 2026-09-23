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
    repo._docsDir = await getApplicationDocumentsDirectory();
    await repo.reload();
    return repo;
  }

  /// Re-reads the file into memory, dropping whatever was held before.
  ///
  /// Two instances of this repository are alive at different times: the app's
  /// singleton and a fresh one built inside the WorkManager isolate. Since
  /// each rewrites the *whole* file from its own in-memory map, a stale
  /// foreground copy would silently erase every fix the background wrote
  /// since app start. Every foreground mutation therefore reloads first, and
  /// screens that display the history reload when they open.
  Future<void> reload() async {
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
  /// Reloads first so a long-lived instance can't overwrite writes made by
  /// the other one (see [reload]).
  Future<void> addPoint(DayLocationPoint point) async {
    await reload();
    final key = _dayKey(point.timestamp);
    (_byDay[key] ??= []).add(point);
    await _persist();
  }

  /// Merges a Google Timeline import: for every day covered by [points],
  /// first drops that day's *previously imported* points (source
  /// `timelineImport`), then adds the fresh ones. Background-tracked points
  /// (source `tracked`) are never touched by an import. This makes
  /// re-importing an overlapping range (e.g. Google only keeps ~3 months of
  /// Timeline data, so periodic re-imports overlap) idempotent instead of
  /// piling up duplicates — the newest import always wins for its own days.
  Future<void> importTimelinePoints(List<DayLocationPoint> points) async {
    if (points.isEmpty) return;
    await reload();
    final coveredDays = points.map((p) => _dayKey(p.timestamp)).toSet();
    for (final day in coveredDays) {
      _byDay[day]?.removeWhere((p) => p.source == LocationSource.timelineImport);
    }
    for (final point in points) {
      (_byDay[_dayKey(point.timestamp)] ??= []).add(point);
    }
    await _persist();
  }

  /// Writes to a temp file and renames it over the real one. A plain
  /// `writeAsString` truncates first, so a crash — or the background isolate
  /// writing at the same moment — could leave a half-written file, which
  /// [reload] would then discard as corrupt, taking the whole history with
  /// it. Rename is atomic within the same directory.
  Future<void> _persist() async {
    final json = jsonEncode(_byDay.map(
      (key, points) => MapEntry(key, points.map((p) => p.toJson()).toList()),
    ));
    final tmp = File('$_path.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(_path);
  }
}
