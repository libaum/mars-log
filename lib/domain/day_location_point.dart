/// Where a [DayLocationPoint] came from — lets a re-import cleanly replace
/// only its own previous points for the days it covers, without touching the
/// other source (see [LocationHistoryRepository.importTimelinePoints]).
enum LocationSource {
  /// Captured by the app's own background WorkManager fix.
  tracked,

  /// Backfilled from a Google Maps Timeline export.
  timelineImport,
}

/// A single GPS fix, independent of any journal entry. Bucketed by calendar
/// date in [LocationHistoryRepository] — not tied to which entry (if any) was
/// recorded that day, since entries can be backdated.
class DayLocationPoint {
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final LocationSource source;

  DayLocationPoint({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.source = LocationSource.tracked,
  });

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp.toIso8601String(),
        'source': source.name,
      };

  factory DayLocationPoint.fromJson(Map<String, dynamic> json) =>
      DayLocationPoint(
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        timestamp: DateTime.parse(json['timestamp'] as String),
        // Points written before the source field existed were all captured
        // by the background tracker.
        source: LocationSource.values.firstWhere(
          (s) => s.name == json['source'],
          orElse: () => LocationSource.tracked,
        ),
      );
}
