/// Maps a 0..10 mood score to a single face emoji for the timeline.
String moodEmoji(double? score) {
  if (score == null) return '·';
  if (score >= 8.0) return '😄';
  if (score >= 6.5) return '🙂';
  if (score >= 4.5) return '😐';
  if (score >= 2.5) return '😕';
  return '😔';
}

const _months = [
  'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni',
  'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember',
];

/// "10. Juli 2026"
String formatLongDate(DateTime d) => '${d.day}. ${_months[d.month - 1]} ${d.year}';

const _shortMonths = [
  'Jan', 'Feb', 'Mär', 'Apr', 'Mai', 'Jun',
  'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez',
];

/// "10. Jul 2026" — the entry detail's title, short enough for one line.
String formatDayTitle(DateTime d) =>
    '${d.day}. ${_shortMonths[d.month - 1]} ${d.year}';

/// "10. Juli"
String formatShortDate(DateTime d) => '${d.day}. ${_months[d.month - 1]}';

/// "Juli 2026"
String formatMonthYear(DateTime d) => '${_months[d.month - 1]} ${d.year}';

/// Relative label for recent days, else short date.
String formatRelativeDate(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(DateTime(day.year, day.month, day.day)).inDays;
  if (diff == 0) return 'Heute';
  if (diff == 1) return 'Gestern';
  return formatShortDate(day);
}
