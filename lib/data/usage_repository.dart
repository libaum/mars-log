import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:mars_log/domain/usage_day.dart';

/// Owns `usage/`: one file per day under `days/` (`2026-10-21.json`, see
/// [UsageDay.toJson]), the app labels in `apps.json`, and in `state.json`
/// when the phone last collected.
///
/// Nothing is held in memory: the WorkManager isolate and the app write
/// here independently, so every call reads the file it needs. Writes merge
/// (a set of events, labels that only grow) and land by rename — two
/// writers racing can lose one write, never corrupt a file, and the next
/// collection fills the gap from Android's own week of history.
///
/// Shared with Mars Hub, which holds the phone's days as they sync in.
class UsageRepository {
  static final _random = Random();

  final Directory dir;

  UsageRepository._(this.dir);

  /// [directory]: the folder holding `usage/` (default: app documents —
  /// next to `entries.json`).
  static Future<UsageRepository> open({Directory? directory}) async {
    final parent = directory ?? await getApplicationDocumentsDirectory();
    final repo = UsageRepository._(Directory('${parent.path}/usage'));
    await Directory('${repo.dir.path}/days').create(recursive: true);
    return repo;
  }

  File _dayFile(String day) => File('${dir.path}/days/$day.json');
  File get _appsFile => File('${dir.path}/apps.json');
  File get _stateFile => File('${dir.path}/state.json');

  /// Every stored day file, oldest first — for the export zip.
  Future<List<File>> dayFiles() async {
    final files = await Directory('${dir.path}/days')
        .list()
        .where((f) => f is File && f.path.endsWith('.json'))
        .cast<File>()
        .toList();
    return files..sort((a, b) => a.path.compareTo(b.path));
  }

  /// The labels file, if any labels were learnt — for the export zip.
  File get appsFile => _appsFile;

  Future<List<String>> days() async => [
        for (final f in await dayFiles())
          f.uri.pathSegments.last.replaceAll('.json', ''),
      ];

  Future<UsageDay?> day(String key) async {
    final json = await _read(_dayFile(key));
    if (json == null) return null;
    try {
      return UsageDay.fromJson(json);
    } on Object {
      return null; // unreadable → treated as empty, rewritten on next merge
    }
  }

  /// Days whose [UsageDay.changedAt] is at or after [since] (all if null).
  Future<List<UsageDay>> changedSince(DateTime? since) async {
    final result = <UsageDay>[];
    for (final file in await dayFiles()) {
      // Cheap prefilter: a day written before [since] can't have changed
      // after it. The margin covers file-time granularity.
      if (since != null &&
          (await file.lastModified())
              .isBefore(since.subtract(const Duration(minutes: 1)))) {
        continue;
      }
      final d = await day(file.uri.pathSegments.last.replaceAll('.json', ''));
      if (d != null && (since == null || !d.changedAt.isBefore(since))) {
        result.add(d);
      }
    }
    return result;
  }

  /// Merges freshly collected events into their days; a day that gained
  /// any is stamped [now]. Returns how many events were new.
  Future<int> addEvents(Iterable<UsageEvent> events, {DateTime? now}) async {
    final byDay = <String, List<UsageEvent>>{};
    for (final e in events) {
      (byDay[e.day] ??= []).add(e);
    }
    final stamp = now ?? DateTime.now();
    var added = 0;
    for (final MapEntry(key: key, value: fresh) in byDay.entries) {
      final stored = await day(key) ?? UsageDay(key, const [], changedAt: stamp);
      final n = stored.merge(fresh);
      if (n == 0) continue;
      stored.changedAt = stamp;
      await _write(_dayFile(key), stored.toJson());
      added += n;
    }
    return added;
  }

  /// A day from another device or an export: the union of both, the later
  /// clock. Never moves the clock forward itself, so applying a day the
  /// phone pushed doesn't make it look changed again.
  Future<void> applySynced(UsageDay remote) async {
    final stored = await day(remote.day);
    if (stored == null) {
      await _write(_dayFile(remote.day), remote.toJson());
      return;
    }
    final n = stored.merge(remote.events);
    final later = remote.changedAt.isAfter(stored.changedAt);
    if (n == 0 && !later) return;
    if (later) stored.changedAt = remote.changedAt;
    await _write(_dayFile(remote.day), stored.toJson());
  }

  Future<UsageApps> apps() async {
    final json = await _read(_appsFile);
    if (json == null) return UsageApps(const {});
    try {
      return UsageApps.fromJson(json);
    } on Object {
      return UsageApps(const {});
    }
  }

  /// Learns labels; stamps [now] if any was new or renamed.
  Future<void> addLabels(Map<String, String> labels, {DateTime? now}) async {
    final stored = await apps();
    if (!stored.merge(labels)) return;
    stored.changedAt = now ?? DateTime.now();
    await _write(_appsFile, stored.toJson());
  }

  /// Labels from another device or an export — merged, the later clock.
  Future<void> applySyncedApps(UsageApps remote) async {
    final stored = await apps();
    final changed = stored.merge(remote.labels);
    final at = remote.changedAt;
    final later = at != null && (stored.changedAt == null || at.isAfter(stored.changedAt!));
    if (!changed && !later) return;
    if (later) stored.changedAt = at;
    await _write(_appsFile, stored.toJson());
  }

  /// When the last collection ran to — device-local, never synced.
  Future<DateTime?> lastCollected() async {
    final ms = (await _read(_stateFile))?['lastCollected'];
    return ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  Future<void> setLastCollected(DateTime at) =>
      _write(_stateFile, {'lastCollected': at.millisecondsSinceEpoch});

  Future<Map<String, dynamic>?> _read(File file) async {
    try {
      if (!await file.exists()) return null;
      return (jsonDecode(await file.readAsString()) as Map).cast<String, dynamic>();
    } on Object {
      return null;
    }
  }

  /// Temp file + rename: a reader never sees half a file. The temp name is
  /// the writer's own, so two isolates writing the same day at once can't
  /// interleave into one temp file.
  Future<void> _write(File file, Map<String, dynamic> json) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}'
        '-${_random.nextInt(1 << 32)}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(file.path);
  }
}
