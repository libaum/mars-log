import 'package:mars_log/domain/journal_entry.dart';

/// Aggregated stats for the ready entries of a single calendar month.
class MonthStats {
  final DateTime month; // any day within the month
  final List<JournalEntry> entries; // ready entries in this month

  MonthStats(this.month, this.entries);

  int get entryCount => entries.length;

  double? get averageMood {
    final scores = entries.map((e) => e.moodScore).whereType<double>().toList();
    if (scores.isEmpty) return null;
    return scores.reduce((a, b) => a + b) / scores.length;
  }

  /// Average of each [kMoodDimensions] key across the month, 0 if no data.
  Map<String, int> get averageDimensions {
    final sums = <String, int>{for (final d in kMoodDimensions) d: 0};
    var count = 0;
    for (final e in entries) {
      final dims = e.dimensions;
      if (dims == null) continue;
      count++;
      for (final d in kMoodDimensions) {
        sums[d] = sums[d]! + (dims[d] ?? 0);
      }
    }
    if (count == 0) return sums;
    return sums.map((k, v) => MapEntry(k, (v / count).round()));
  }

  /// Tags used this month, most frequent first.
  List<MapEntry<String, int>> get topTags {
    final counts = <String, int>{};
    for (final e in entries) {
      for (final t in e.tags) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    final list = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  /// Mood score keyed by day-of-month (1-based).
  Map<int, double> get moodByDay {
    final map = <int, double>{};
    for (final e in entries) {
      if (e.moodScore != null) map[e.day.day] = e.moodScore!;
    }
    return map;
  }
}

/// Number of consecutive days up to and including today that have at least
/// one entry (of any status — a recorded day counts even before it's
/// analyzed). 0 if today has no entry yet.
int currentStreak(List<JournalEntry> entries) {
  final days = entries
      .map((e) => DateTime(e.day.year, e.day.month, e.day.day))
      .toSet();
  var streak = 0;
  var cursor = DateTime.now();
  cursor = DateTime(cursor.year, cursor.month, cursor.day);
  while (days.contains(cursor)) {
    streak++;
    cursor = cursor.subtract(const Duration(days: 1));
  }
  return streak;
}
