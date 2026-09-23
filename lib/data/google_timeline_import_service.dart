import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:mars_log/data/location_history_repository.dart';
import 'package:mars_log/domain/day_location_point.dart';

/// Backfills [LocationHistoryRepository] from a Google Maps Timeline export
/// ("Zeitachse exportieren" in Android's Settings → Standort → Zeitachse),
/// so days before background tracking was ever turned on still get a route.
///
/// The export's schema is `{ semanticSegments: [...], rawSignals: [...],
/// userLocationProfile: {...} }`. Only `semanticSegments` is used —
/// `rawSignals` is the raw, undeduplicated sensor stream (tens of thousands
/// of entries) and far noisier than what this app needs. Each segment is one
/// of:
/// - `timelinePath`: a list of `{point, time}` fixes — one point each.
/// - `visit`: a single place stayed at for the segment's duration — one
///   point at the segment's start time.
/// - `activity`: movement between two points — one point each at start/end
///   time.
///
/// Every point is tagged [LocationSource.timelineImport]. Re-running the
/// import later (Google's on-device Timeline only retains ~3 months, so a
/// periodic re-import is expected) cleanly replaces the previous import's
/// points for whatever days the new file covers, instead of duplicating —
/// see [LocationHistoryRepository.importTimelinePoints].
class GoogleTimelineImportService {
  final LocationHistoryRepository _repository;

  GoogleTimelineImportService(this._repository);

  /// Lets the user pick a Timeline export JSON, parses it off the UI thread
  /// (the export can be tens of MB), and appends every point found. Returns
  /// the number of imported points, or null if cancelled.
  Future<int?> importFromPicker() async {
    // `withData: false` on purpose: a real export runs to tens of MB, and
    // pulling the bytes here would hold the file, its UTF-16 string and the
    // isolate's copy in memory at once. The isolate reads it from the path
    // instead, so only the decoded object graph is ever live.
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: false,
    );
    final path = picked?.files.single.path;
    if (path == null) return null;

    final points = await compute(_parseTimelineFile, path);
    await _repository.importTimelinePoints(points);
    return points.length;
  }
}

/// Runs in a background isolate via [compute] — must stay a top-level
/// function with only transferable inputs/outputs (plain strings/doubles).
List<DayLocationPoint> _parseTimelineFile(String path) {
  final data =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final segments = data['semanticSegments'] as List<dynamic>? ?? const [];
  final points = <DayLocationPoint>[];

  for (final entry in segments) {
    // One malformed segment must not abort an otherwise good import of
    // thousands of points.
    try {
      final segment = entry as Map<String, dynamic>;

      final timelinePath = segment['timelinePath'];
      if (timelinePath is List) {
        for (final e in timelinePath) {
          if (e is! Map) continue;
          final point =
              _point(e['point'] as String?, e['time'] as String?);
          if (point != null) points.add(point);
        }
        continue;
      }

      final visit = segment['visit'];
      if (visit is Map) {
        final topCandidate = visit['topCandidate'];
        final placeLocation =
            topCandidate is Map ? topCandidate['placeLocation'] : null;
        final point = _point(
          placeLocation is Map ? placeLocation['latLng'] as String? : null,
          segment['startTime'] as String?,
        );
        if (point != null) points.add(point);
        continue;
      }

      final activity = segment['activity'];
      if (activity is Map) {
        final start = activity['start'];
        final end = activity['end'];
        final from = _point(
          start is Map ? start['latLng'] as String? : null,
          segment['startTime'] as String?,
        );
        final to = _point(
          end is Map ? end['latLng'] as String? : null,
          segment['endTime'] as String?,
        );
        if (from != null) points.add(from);
        if (to != null) points.add(to);
      }
    } catch (_) {
      continue;
    }
  }

  return points;
}

/// Builds one point, or null if either half is missing/unparseable.
///
/// The timestamps carry an offset (`…+02:00`), and `DateTime.parse` turns
/// those into **UTC** — so bucketing by `.day` straight off the parsed value
/// would file everything between local midnight and the offset onto the
/// previous day, permanently, because `toIso8601String` then writes `Z`.
/// `toLocal()` puts it back on the day it actually happened, matching how
/// tracked fixes (`DateTime.now()`) are stored.
DayLocationPoint? _point(String? rawLatLng, String? rawTime) {
  final latLng = _parseLatLng(rawLatLng);
  final time = DateTime.tryParse(rawTime ?? '');
  if (latLng == null || time == null) return null;
  return DayLocationPoint(
    latitude: latLng.$1,
    longitude: latLng.$2,
    timestamp: time.toLocal(),
    source: LocationSource.timelineImport,
  );
}

/// Parses Google's `"-8.8860174°, 116.2787645°"` lat/lng string format.
(double, double)? _parseLatLng(String? raw) {
  if (raw == null) return null;
  final parts = raw.replaceAll('°', '').split(',');
  if (parts.length != 2) return null;
  final lat = double.tryParse(parts[0].trim());
  final lng = double.tryParse(parts[1].trim());
  if (lat == null || lng == null) return null;
  return (lat, lng);
}
