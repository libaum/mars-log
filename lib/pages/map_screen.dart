import 'package:flutter/material.dart';
import 'package:mars_log/domain/day_location_point.dart';
import 'package:mars_log/domain/mood.dart';
import 'package:mars_log/pages/widgets/mood_map.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// The month's route on the whole screen, pannable and zoomable — the inline
/// map in the stats screen is only a preview, because it can't take the pan
/// gesture without fighting the list scroll and the month swipe.
///
/// Deliberately *not* wrapped in `DoubleTapThemeToggle` like the other
/// screens: here a double tap means zoom.
class MapScreen extends StatelessWidget {
  final DateTime month;
  final Map<int, List<DayLocationPoint>> pointsByDay;
  final Map<int, double> moodByDay;

  /// Tapping a route still opens that day's entry, same as inline.
  final void Function(int day) onDayTap;

  const MapScreen({
    super.key,
    required this.month,
    required this.pointsByDay,
    required this.moodByDay,
    required this.onDayTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 16, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(formatMonthYear(month),
                        style: TEXT_STYLE_SETTING),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.close, size: 20, color: primary),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: MoodMap(
                pointsByDay: pointsByDay,
                moodByDay: moodByDay,
                monthKey: '${month.year}-${month.month}',
                onDayTap: onDayTap,
                expanded: true,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 16, 32, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MoodScaleLegend(),
                  const SizedBox(height: 8),
                  Text('Karten: Esri, HERE, Garmin, OpenStreetMap',
                      style: TEXT_STYLE_STATUS),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
