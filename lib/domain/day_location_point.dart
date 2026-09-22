/// A single background GPS fix, independent of any journal entry. Bucketed by
/// calendar date in [LocationHistoryRepository] — not tied to which entry (if
/// any) was recorded that day, since entries can be backdated.
class DayLocationPoint {
  final double latitude;
  final double longitude;
  final DateTime timestamp;

  DayLocationPoint({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp.toIso8601String(),
      };

  factory DayLocationPoint.fromJson(Map<String, dynamic> json) =>
      DayLocationPoint(
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}
