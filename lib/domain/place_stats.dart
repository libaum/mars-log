import 'package:mars_log/domain/day_location_point.dart';

/// A place you keep coming back to, with how you felt on the days you were
/// there.
///
/// [averageMood] is the average mood of the *whole day*, not of the time
/// actually spent here — the app only ever scores a day, not a moment. So
/// this says "on days you were here, you felt like this", which is a weaker
/// and more honest claim than "this place makes you feel like this".
class PlaceCluster {
  final double latitude;
  final double longitude;

  /// Distinct calendar days with at least one fix in this cell.
  final int dayCount;

  /// Total fixes in this cell — a rough proxy for time spent.
  final int pointCount;

  /// Average mood of the scored days among [dayCount], or null if none of
  /// those days carry a score.
  final double? averageMood;

  PlaceCluster({
    required this.latitude,
    required this.longitude,
    required this.dayCount,
    required this.pointCount,
    required this.averageMood,
  });
}

/// Roughly 275m north-south; less east-west the further from the equator.
/// Fine enough to separate neighbouring places, coarse enough that standing
/// around one building doesn't split into several "places".
const _gridSize = 0.0025;

/// A place has to show up on at least this many separate days before it
/// counts as somewhere you go, rather than somewhere you once drove past.
const _minDays = 3;

/// Buckets every location fix into a coarse grid and keeps the cells you
/// return to, ranked by how many days you were there.
///
/// Grid bucketing rather than true clustering is deliberate: fixes pile up
/// where you linger and stay sparse along roads, so cell density already
/// approximates time spent — without the tuning that a distance-based
/// clustering algorithm would need.
List<PlaceCluster> clusterPlaces({
  required Map<String, List<DayLocationPoint>> pointsByDate,
  required Map<String, double> moodByDate,
  int limit = 8,
}) {
  final days = <String, Set<String>>{};
  final points = <String, int>{};
  final sumLat = <String, double>{};
  final sumLng = <String, double>{};

  for (final entry in pointsByDate.entries) {
    for (final point in entry.value) {
      final cellLat = (point.latitude / _gridSize).floor();
      final cellLng = (point.longitude / _gridSize).floor();
      final key = '$cellLat:$cellLng';

      (days[key] ??= {}).add(entry.key);
      points[key] = (points[key] ?? 0) + 1;
      sumLat[key] = (sumLat[key] ?? 0) + point.latitude;
      sumLng[key] = (sumLng[key] ?? 0) + point.longitude;
    }
  }

  final clusters = <PlaceCluster>[];
  for (final entry in days.entries) {
    if (entry.value.length < _minDays) continue;

    final scores = entry.value
        .map((date) => moodByDate[date])
        .whereType<double>()
        .toList();
    final count = points[entry.key]!;

    clusters.add(PlaceCluster(
      latitude: sumLat[entry.key]! / count,
      longitude: sumLng[entry.key]! / count,
      dayCount: entry.value.length,
      pointCount: count,
      averageMood: scores.isEmpty
          ? null
          : scores.reduce((a, b) => a + b) / scores.length,
    ));
  }

  clusters.sort((a, b) => b.dayCount.compareTo(a.dayCount));
  return clusters.take(limit).toList();
}
