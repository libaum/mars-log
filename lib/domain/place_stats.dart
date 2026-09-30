import 'dart:math';

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

  /// The `yyyy-MM-dd` dates with at least one fix here — kept so two
  /// clusters that turn out to be the same place can be merged honestly
  /// (a day in both counts once), see [mergePlacesByLabel].
  final Set<String> dates;

  /// Distinct calendar days with at least one fix here.
  int get dayCount => dates.length;

  /// Total fixes in this cell — a rough proxy for time spent.
  final int pointCount;

  /// Average mood of the scored days among [dayCount], or null if none of
  /// those days carry a score.
  final double? averageMood;

  PlaceCluster({
    required this.latitude,
    required this.longitude,
    required this.dates,
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

/// Cells whose centres lie within this distance of a denser cell are folded
/// into it. A place straddling a grid line otherwise shows up twice, and a
/// big one (a campus, a park) several times.
const _mergeRadiusMeters = 400.0;

/// Buckets every location fix into a coarse grid, then folds each cell into
/// the densest cell nearby, and keeps the places you return to, ranked by
/// how many days you were there.
///
/// Grid bucketing rather than true clustering is deliberate: fixes pile up
/// where you linger and stay sparse along roads, so cell density already
/// approximates time spent. Seeding the merge with the densest cells keeps
/// it from chaining along a road into one long blob.
List<PlaceCluster> clusterPlaces({
  required Map<String, List<DayLocationPoint>> pointsByDate,
  required Map<String, double> moodByDate,
  int limit = 8,
}) {
  final cells = <String, _Cell>{};
  for (final entry in pointsByDate.entries) {
    for (final point in entry.value) {
      final key =
          '${(point.latitude / _gridSize).floor()}:'
          '${(point.longitude / _gridSize).floor()}';
      (cells[key] ??= _Cell()).add(entry.key, point);
    }
  }

  // Densest first: each becomes a seed unless a denser seed is close by.
  final ranked = cells.values.toList()
    ..sort((a, b) => b.points.compareTo(a.points));
  final seeds = <_Cell>[];
  for (final cell in ranked) {
    final home = seeds
        .where(
          (s) =>
              _distance(s.lat, s.lng, cell.lat, cell.lng) <= _mergeRadiusMeters,
        )
        .firstOrNull;
    if (home == null) {
      seeds.add(cell.copy());
    } else {
      home.absorb(cell);
    }
  }

  final clusters = [
    for (final seed in seeds)
      if (seed.dates.length >= _minDays)
        _toCluster(seed.lat, seed.lng, seed.dates, seed.points, moodByDate),
  ]..sort((a, b) => b.dayCount.compareTo(a.dayCount));
  return clusters.take(limit).toList();
}

/// Merges clusters that geocoding named the same (two ends of one district,
/// a place larger than [_mergeRadiusMeters]). [labelOf] returns null while a
/// name is unknown; those stay as they are.
List<PlaceCluster> mergePlacesByLabel(
  List<PlaceCluster> places,
  String? Function(PlaceCluster) labelOf,
  Map<String, double> moodByDate,
) {
  final byLabel = <String, List<PlaceCluster>>{};
  final result = <PlaceCluster>[];
  for (final place in places) {
    final label = labelOf(place);
    if (label == null) {
      result.add(place);
    } else {
      (byLabel[label] ??= []).add(place);
    }
  }
  for (final group in byLabel.values) {
    if (group.length == 1) {
      result.add(group.first);
      continue;
    }
    // Keep the busiest one's position: its label is the one shown.
    group.sort((a, b) => b.pointCount.compareTo(a.pointCount));
    result.add(
      _toCluster(
        group.first.latitude,
        group.first.longitude,
        {for (final p in group) ...p.dates},
        group.fold(0, (sum, p) => sum + p.pointCount),
        moodByDate,
      ),
    );
  }
  return result..sort((a, b) => b.dayCount.compareTo(a.dayCount));
}

PlaceCluster _toCluster(
  double lat,
  double lng,
  Set<String> dates,
  int points,
  Map<String, double> moodByDate,
) {
  final scores = dates.map((d) => moodByDate[d]).whereType<double>().toList();
  return PlaceCluster(
    latitude: lat,
    longitude: lng,
    dates: dates,
    pointCount: points,
    averageMood: scores.isEmpty
        ? null
        : scores.reduce((a, b) => a + b) / scores.length,
  );
}

/// Equirectangular approximation — plenty at a few hundred metres.
double _distance(double lat1, double lng1, double lat2, double lng2) {
  const earth = 6371000.0;
  final x = (lng2 - lng1) * pi / 180 * cos((lat1 + lat2) / 2 * pi / 180);
  final y = (lat2 - lat1) * pi / 180;
  return sqrt(x * x + y * y) * earth;
}

class _Cell {
  final dates = <String>{};
  int points = 0;
  double _sumLat = 0;
  double _sumLng = 0;

  double get lat => _sumLat / points;
  double get lng => _sumLng / points;

  void add(String date, DayLocationPoint p) {
    dates.add(date);
    points++;
    _sumLat += p.latitude;
    _sumLng += p.longitude;
  }

  /// Folds [other] in. The position stays weighted by fixes, so it drifts
  /// toward where you actually spend time.
  void absorb(_Cell other) {
    dates.addAll(other.dates);
    points += other.points;
    _sumLat += other._sumLat;
    _sumLng += other._sumLng;
  }

  _Cell copy() => _Cell()..absorb(this);
}
