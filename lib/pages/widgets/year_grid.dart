import 'package:flutter/material.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// The last 52 weeks as one dense grid — a column per week, a row per weekday
/// (Monday top, matching the mood calendar), each cell in its day's mood
/// colour. Long stretches that a single month's view can't show — a good
/// spring, a rough autumn — only become visible at this scale.
///
/// Sized to fit the available width rather than scrolling horizontally: the
/// stats screen's own horizontal swipe changes months, and a scrollable strip
/// inside it would fight that gesture.
class YearGrid extends StatelessWidget {
  /// Mood score per day. Days absent from the map have no entry.
  final Map<DateTime, double> moodByDate;

  /// Days that have an entry but no mood score.
  final Set<DateTime> unscoredDays;

  const YearGrid({
    super.key,
    required this.moodByDate,
    required this.unscoredDays,
  });

  static const _weeks = 52;
  static const _gap = 1.5;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    // The grid ends on the current week and starts 51 weeks before it, always
    // on a Monday, so every column is a whole calendar week.
    //
    // Calendar arithmetic, never `Duration(days: n)`: a Duration adds absolute
    // time, so crossing the October DST change shifts every following date to
    // 23:00 of the day before — which would render one day twice and put
    // everything after it in the wrong weekday row. `DateTime(y, m, d + n)`
    // normalises by calendar day and is immune to that.
    final today = DateTime.now();
    final startOfThisWeek =
        DateTime(today.year, today.month, today.day - (today.weekday - 1));
    final start = DateTime(startOfThisWeek.year, startOfThisWeek.month,
        startOfThisWeek.day - 7 * (_weeks - 1));

    return LayoutBuilder(
      builder: (context, constraints) {
        final cell = (constraints.maxWidth - _gap * (_weeks - 1)) / _weeks;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var week = 0; week < _weeks; week++)
                  Padding(
                    padding: EdgeInsets.only(
                        right: week == _weeks - 1 ? 0 : _gap),
                    child: Column(
                      children: [
                        for (var weekday = 0; weekday < 7; weekday++)
                          Padding(
                            padding:
                                EdgeInsets.only(bottom: weekday == 6 ? 0 : _gap),
                            child: _cell(
                              DateTime(start.year, start.month,
                                  start.day + week * 7 + weekday),
                              cell,
                              isDark,
                              primary,
                              today,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_monthLabel(start), style: TEXT_STYLE_STATUS),
                Text('heute', style: TEXT_STYLE_STATUS),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _cell(
    DateTime date,
    double size,
    bool isDark,
    Color primary,
    DateTime today,
  ) {
    final key = DateTime(date.year, date.month, date.day);
    final isFuture = key.isAfter(DateTime(today.year, today.month, today.day));
    final mood = moodByDate[key];

    final Color color;
    if (isFuture) {
      color = Colors.transparent;
    } else if (mood != null) {
      color = moodColor(mood, isDark: isDark);
    } else if (unscoredDays.contains(key)) {
      // Logged, but the analysis produced no score.
      color = primary.withValues(alpha: 0.35);
    } else {
      color = primary.withValues(alpha: 0.08);
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mär', 'Apr', 'Mai', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez', //
  ];

  String _monthLabel(DateTime date) => '${_months[date.month - 1]} ${date.year}';
}
