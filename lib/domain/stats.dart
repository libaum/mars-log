import 'dart:math';

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

/// A tag with the average mood of the entries it appears in.
class TagMood {
  final String tag;
  final double averageMood;
  final int count;
  TagMood(this.tag, this.averageMood, this.count);
}

/// Aggregations across *all* ready entries rather than a single month.
///
/// A month rarely holds enough entries for any of this to mean something —
/// correlations especially need a few dozen data points before they stop
/// being noise — so these deliberately ignore the month selector.
class AllTimeStats {
  final List<JournalEntry> entries;

  /// Below this many entries, a correlation is noise dressed up as insight.
  static const minSampleForCorrelation = 15;

  /// A tag needs at least this many entries before its average means much.
  static const minEntriesPerTag = 3;

  AllTimeStats(this.entries);

  /// All of these are `late final` on purpose: the stats screen reads several
  /// of them per build, and each one walks the whole entry list.
  late final List<JournalEntry> _scored =
      entries.where((e) => e.moodScore != null).toList();

  /// Tags ranked by the average mood of the entries they appear in, best
  /// first. Only tags reaching [minEntriesPerTag] are included.
  late final List<TagMood> tagMoods = _computeTagMoods();

  List<TagMood> _computeTagMoods() {
    final scores = <String, List<double>>{};
    for (final e in _scored) {
      for (final tag in e.tags) {
        (scores[tag] ??= []).add(e.moodScore!);
      }
    }
    final list = scores.entries
        .where((e) => e.value.length >= minEntriesPerTag)
        .map((e) => TagMood(
              e.key,
              e.value.reduce((a, b) => a + b) / e.value.length,
              e.value.length,
            ))
        .toList()
      ..sort((a, b) => b.averageMood.compareTo(a.averageMood));
    return list;
  }

  /// Average mood per weekday (`DateTime.monday`..`DateTime.sunday`).
  late final Map<int, double> moodByWeekday = _computeMoodByWeekday();

  Map<int, double> _computeMoodByWeekday() {
    final byDay = <int, List<double>>{};
    for (final e in _scored) {
      (byDay[e.day.weekday] ??= []).add(e.moodScore!);
    }
    return byDay.map((weekday, scores) => MapEntry(
        weekday, scores.reduce((a, b) => a + b) / scores.length));
  }

  /// How many recordings were started in each hour of the day (0..23), from
  /// [JournalEntry.createdAt] — when the entry was actually recorded, which
  /// backdating doesn't move.
  late final Map<int, int> recordingsByHour = _computeRecordingsByHour();

  Map<int, int> _computeRecordingsByHour() {
    final byHour = <int, int>{};
    for (final e in entries) {
      byHour[e.createdAt.hour] = (byHour[e.createdAt.hour] ?? 0) + 1;
    }
    return byHour;
  }

  /// Average of each dimension per month, oldest month first, for the last
  /// [months] months that have data.
  Map<String, List<double>> dimensionTrend({int months = 12}) {
    final cutoff = DateTime.now();
    final buckets = <String, Map<String, List<int>>>{};
    for (final e in entries) {
      final dims = e.dimensions;
      if (dims == null) continue;
      final monthsAgo =
          (cutoff.year - e.day.year) * 12 + (cutoff.month - e.day.month);
      if (monthsAgo < 0 || monthsAgo >= months) continue;
      final key = '${e.day.year}-${e.day.month.toString().padLeft(2, '0')}';
      for (final d in kMoodDimensions) {
        final value = dims[d];
        if (value != null) ((buckets[d] ??= {})[key] ??= []).add(value);
      }
    }

    return {
      for (final d in kMoodDimensions)
        d: (buckets[d]?.keys.toList()?..sort())
                ?.map((key) {
                  final values = buckets[d]![key]!;
                  return values.reduce((a, b) => a + b) / values.length;
                })
                .toList() ??
            const <double>[],
    };
  }

  /// Pearson correlation between every pair of [kMoodDimensions], strongest
  /// relationship first. Empty when there aren't enough scored entries for
  /// the number to mean anything.
  late final List<({String a, String b, double r})> dimensionCorrelations =
      _computeDimensionCorrelations();

  List<({String a, String b, double r})> _computeDimensionCorrelations() {
    final rows = entries
        .map((e) => e.dimensions)
        .whereType<Map<String, int>>()
        .toList();
    if (rows.length < minSampleForCorrelation) return const [];

    final pairs = <({String a, String b, double r})>[];
    for (var i = 0; i < kMoodDimensions.length; i++) {
      for (var j = i + 1; j < kMoodDimensions.length; j++) {
        final a = kMoodDimensions[i];
        final b = kMoodDimensions[j];
        final xs = <double>[];
        final ys = <double>[];
        for (final row in rows) {
          final x = row[a];
          final y = row[b];
          if (x != null && y != null) {
            xs.add(x.toDouble());
            ys.add(y.toDouble());
          }
        }
        final r = pearson(xs, ys);
        if (r != null) pairs.add((a: a, b: b, r: r));
      }
    }
    pairs.sort((p, q) => q.r.abs().compareTo(p.r.abs()));
    return pairs;
  }

  /// Words per entry, speaking-length proxies and the most-used words.
  late final WordStats wordStats = WordStats(entries);
}

/// Transcript-derived numbers. The transcript is the app's permanent record,
/// so these stay meaningful even for entries whose audio was discarded.
class WordStats {
  final List<JournalEntry> entries;
  WordStats(this.entries);

  /// Compiled once rather than per transcript.
  static final _wordSplitter = RegExp(r'[^a-zäöüß]+');

  /// One pass over every transcript fills all of the numbers below. The stats
  /// screen reads several of them per build, and tokenising a few hundred
  /// transcripts repeatedly is the kind of thing that eats a frame budget.
  late final _WordTally _tally = _count();

  int get totalWords => _tally.totalWords;

  double? get averageWordsPerEntry => _tally.entryCount == 0
      ? null
      : _tally.totalWords / _tally.entryCount;

  /// Most-used words, ignoring German filler and function words.
  List<MapEntry<String, int>> topWords({int limit = 12}) =>
      _tally.ranked.take(limit).toList();

  _WordTally _count() {
    final counts = <String, int>{};
    var totalWords = 0;
    var entryCount = 0;

    for (final entry in entries) {
      final transcript = entry.transcript;
      if (transcript == null || transcript.trim().isEmpty) continue;
      entryCount++;

      for (final word in transcript.toLowerCase().split(_wordSplitter)) {
        if (word.length < 2) continue;
        totalWords++;
        if (_stopwords.contains(word)) continue;
        counts[word] = (counts[word] ?? 0) + 1;
      }
    }

    final ranked = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return _WordTally(
        totalWords: totalWords, entryCount: entryCount, ranked: ranked);
  }
}

class _WordTally {
  final int totalWords;
  final int entryCount;
  final List<MapEntry<String, int>> ranked;
  _WordTally({
    required this.totalWords,
    required this.entryCount,
    required this.ranked,
  });
}

/// Pearson correlation coefficient, or null when undefined (too few points,
/// or one side has no variance at all).
double? pearson(List<double> xs, List<double> ys) {
  if (xs.length != ys.length || xs.length < 3) return null;
  final n = xs.length;
  final meanX = xs.reduce((a, b) => a + b) / n;
  final meanY = ys.reduce((a, b) => a + b) / n;

  var covariance = 0.0;
  var varianceX = 0.0;
  var varianceY = 0.0;
  for (var i = 0; i < n; i++) {
    final dx = xs[i] - meanX;
    final dy = ys[i] - meanY;
    covariance += dx * dy;
    varianceX += dx * dx;
    varianceY += dy * dy;
  }
  if (varianceX == 0 || varianceY == 0) return null;
  return covariance / (sqrt(varianceX) * sqrt(varianceY));
}

/// German stopwords — function words and spoken filler that would otherwise
/// dominate every word count.
const _stopwords = <String>{
  'aber', 'alle', 'allem', 'allen', 'aller', 'alles', 'als', 'also', 'am',
  'an', 'auch', 'auf', 'aus', 'bei', 'beim', 'bin', 'bis', 'bisschen', 'da',
  'dachte', 'damit', 'dann', 'das', 'dass', 'dem', 'den', 'denn', 'der',
  'des', 'dich', 'die', 'dies', 'diese', 'diesem', 'diesen', 'dieser',
  'dieses', 'dir', 'doch', 'dort', 'du', 'durch', 'ein', 'eine', 'einem',
  'einen', 'einer', 'eines', 'einfach', 'er', 'es', 'etwas', 'euch', 'fast',
  'für', 'ganz', 'gar', 'gemacht', 'gerade', 'gewesen', 'gibt', 'ging',
  'gleich', 'habe', 'haben', 'hab', 'hat', 'hatte', 'hatten', 'hier', 'ich',
  'ihm', 'ihn', 'ihr', 'im', 'immer', 'in', 'ins', 'ist', 'ja', 'jetzt',
  'kann', 'kein', 'keine', 'können', 'könnte', 'mal', 'man', 'mehr', 'mein',
  'meine', 'mich', 'mir', 'mit', 'muss', 'musste', 'nach', 'natürlich',
  'nicht', 'nichts', 'noch', 'nur', 'ob', 'oder', 'ohne', 'schon', 'sehr',
  'sein', 'seine', 'sich', 'sie', 'sind', 'so', 'sondern', 'über', 'um',
  'und', 'uns', 'unser', 'vom', 'von', 'vor', 'war', 'waren', 'was', 'weil',
  'weiß', 'weiter', 'welche', 'wenn', 'wer', 'werde', 'werden', 'wie',
  'wieder', 'will', 'wir', 'wird', 'wo', 'wollte', 'wurde', 'würde', 'zu',
  'zum', 'zur', 'zwar', 'äh', 'ähm', 'halt', 'eigentlich', 'irgendwie',
  'quasi', 'sozusagen', 'total', 'voll', 'echt', 'ne', 'nee', 'joa', 'okay',
  'heute', 'gestern', 'morgen', 'tag', 'mach', 'machen', 'geht', 'gehen',
};

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
    // Calendar arithmetic, not `Duration(days: 1)`: stepping back across the
    // October DST change with a Duration lands on 01:00 of the previous day,
    // which never matches the midnight-normalised set — the streak would
    // silently stop there once a year.
    cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
  }
  return streak;
}
