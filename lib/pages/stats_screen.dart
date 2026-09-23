import 'package:flutter/material.dart';
import 'package:mars_log/data/gemini_service.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/data/location_history_repository.dart';
import 'package:mars_log/data/secure_storage_service.dart';
import 'package:mars_log/domain/day_location_point.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/mood.dart';
import 'package:mars_log/domain/place_stats.dart';
import 'package:mars_log/domain/stats.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/logic/location_service.dart';
import 'package:mars_log/pages/entry_detail_screen.dart';
import 'package:mars_log/pages/map_screen.dart';
import 'package:mars_log/pages/widgets/dimension_bar.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
import 'package:mars_log/pages/widgets/mood_map.dart';
import 'package:mars_log/pages/widgets/sparkline_painter.dart';
import 'package:mars_log/pages/widgets/year_grid.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// Pure data visualizations over the journal: streak, a month's mood
/// calendar/trend/dimensions/tags. Reached by swiping down from the main
/// screen's header.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  final _journal = getIt<JournalManager>();
  final _gemini = getIt<GeminiService>();
  final _secure = getIt<SecureStorageService>();
  final _storage = getIt<LocalStorageService>();
  final _locations = getIt<LocationHistoryRepository>();
  final _location = getIt<LocationService>();

  late DateTime _month;

  /// Reverse-geocoded names for the place clusters, keyed by rounded
  /// coordinates. Resolved once per screen; until then (or on failure) the
  /// coordinates themselves stand in.
  final Map<String, String> _placeLabels = {};

  /// Places we've already tried to name — including the ones that failed, so
  /// an offline lookup doesn't re-trigger on every rebuild forever.
  final Set<String> _placeLookupsTried = {};
  bool _resolvingPlaces = false;

  String? _review;
  bool _loadingReview = false;
  String? _reviewError;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _loadCachedReview();
    // The background isolate has its own repository instance, so the app's
    // copy is stale for every fix written since launch.
    _locations.reload().then((_) {
      if (mounted) setState(() => _statsSource = null);
    });
  }

  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _month.year == now.year && _month.month == now.month;
  }

  String get _monthKey => '${_month.year}-${_month.month}';

  void _loadCachedReview() {
    _review = _storage.getMonthReview(_monthKey);
    _reviewError = null;
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _loadCachedReview();
    });
  }

  Future<void> _generateReview(List<JournalEntry> monthEntries) async {
    final summaries = monthEntries
        .map((e) => e.summary)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList();
    if (summaries.isEmpty) return;

    setState(() {
      _loadingReview = true;
      _reviewError = null;
    });
    final monthKey = _monthKey;
    try {
      final apiKey = await _secure.getApiKey() ?? '';
      final review =
          await _gemini.summarizeMonth(summaries: summaries, apiKey: apiKey);
      await _storage.setMonthReview(monthKey, review);
      if (!mounted || monthKey != _monthKey) return;
      setState(() {
        _review = review;
        _loadingReview = false;
      });
    } catch (e) {
      if (!mounted || monthKey != _monthKey) return;
      setState(() {
        _reviewError = e.toString();
        _loadingReview = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return DoubleTapThemeToggle(
      child: Scaffold(
        body: SafeArea(
          child: ValueListenableBuilder<List<JournalEntry>>(
            valueListenable: _journal.entriesNotifier,
            builder: (context, entries, _) {
              final readyEntries =
                  entries.where((e) => e.status == EntryStatus.ready).toList();
              _ensureStats(entries, readyEntries);
              final monthEntries = readyEntries
                  .where((e) =>
                      e.day.year == _month.year &&
                      e.day.month == _month.month)
                  .toList()
                ..sort((a, b) => a.day.compareTo(b.day));
              final stats = MonthStats(_month, monthEntries);
              final streak = currentStreak(entries);

              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < -250) {
                    if (!_isCurrentMonth) _shiftMonth(1);
                  } else if (velocity > 250) {
                    _shiftMonth(-1);
                  }
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
                  children: [
                    Text('Statistik', style: TEXT_STYLE_TITLE),
                    const SizedBox(height: 28),
                    _overview(entries.length, streak, primary),
                    const SizedBox(height: 40),
                    _monthNav(primary),
                    const SizedBox(height: 24),
                    if (monthEntries.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Text('Keine Einträge in diesem Monat.',
                            style: TEXT_STYLE_STATUS),
                      )
                    else ...[
                      _reviewSection(monthEntries, primary),
                      const SizedBox(height: 36),
                      _moodCalendar(stats, primary),
                      const SizedBox(height: 36),
                      _moodMap(stats),
                      const SizedBox(height: 36),
                      _moodChart(stats, primary),
                      const SizedBox(height: 36),
                      _dimensions(stats, primary),
                      if (stats.topTags.isNotEmpty) ...[
                        const SizedBox(height: 36),
                        _tags(stats, primary),
                      ],
                    ],
                    // Everything below looks at all entries, not the selected
                    // month — a single month is too thin for any of it.
                    const SizedBox(height: 40),
                    Center(
                      child: Text('—',
                          style: TEXT_STYLE_STATUS.copyWith(fontSize: 15)),
                    ),
                    const SizedBox(height: 40),
                    ..._allTimeSections(_allTime!, primary),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _overview(int totalEntries, int streak, Color primary) {
    return Row(
      children: [
        Expanded(child: _overviewStat('$streak', 'Tage Serie', primary)),
        Expanded(child: _overviewStat('$totalEntries', 'Einträge gesamt', primary)),
      ],
    );
  }

  Widget _overviewStat(String value, String label, Color primary) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: TEXT_STYLE_SCORE),
        const SizedBox(height: 4),
        Text(label, style: TEXT_STYLE_STATUS),
      ],
    );
  }

  Widget _monthNav(Color primary) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          onPressed: () => _shiftMonth(-1),
          icon: Icon(Icons.chevron_left, color: primary),
        ),
        SizedBox(
          width: 160,
          child: Text(
            formatMonthYear(_month),
            textAlign: TextAlign.center,
            style: TEXT_STYLE_SETTING,
          ),
        ),
        IconButton(
          onPressed: _isCurrentMonth ? null : () => _shiftMonth(1),
          icon: Icon(Icons.chevron_right,
              color: _isCurrentMonth ? primary.withValues(alpha: 0.2) : primary),
        ),
      ],
    );
  }

  Widget _reviewSection(List<JournalEntry> monthEntries, Color primary) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('RÜCKBLICK', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 12),
        if (_review != null) ...[
          Text(_review!, style: TEXT_STYLE_BODY),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _loadingReview ? null : () => _generateReview(monthEntries),
            child: Text(
              _loadingReview ? 'Wird generiert …' : 'Neu generieren',
              style: TEXT_STYLE_STATUS.copyWith(color: primary),
            ),
          ),
        ] else ...[
          if (_reviewError != null) ...[
            Text(_reviewError!, style: TEXT_STYLE_STATUS),
            const SizedBox(height: 8),
          ],
          GestureDetector(
            onTap: _loadingReview ? null : () => _generateReview(monthEntries),
            child: Text(
              _loadingReview ? 'Wird generiert …' : 'Rückblick generieren',
              style: TEXT_STYLE_SETTING.copyWith(color: primary),
            ),
          ),
        ],
      ],
    );
  }

  Widget _moodCalendar(MonthStats stats, Color primary) {
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final firstWeekday = DateTime(_month.year, _month.month, 1).weekday;
    final leadingBlanks = firstWeekday - 1; // Monday-first week
    final moodByDay = stats.moodByDay;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STIMMUNGSKALENDER', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 16),
        Wrap(
          spacing: 6,
          runSpacing: 12,
          children: [
            for (var i = 0; i < leadingBlanks; i++)
              const SizedBox(width: 28, height: 30),
            for (var day = 1; day <= daysInMonth; day++)
              _dayCell(day, moodByDay[day], primary),
          ],
        ),
      ],
    );
  }

  Widget _dayCell(int day, double? mood, Color primary) {
    return SizedBox(
      width: 28,
      height: 30,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$day', style: TEXT_STYLE_STATUS.copyWith(fontSize: 10)),
          const SizedBox(height: 5),
          Container(
            height: 3,
            decoration: BoxDecoration(
              color: primary.withValues(
                  alpha: mood == null ? 0.08 : (0.2 + mood / 10 * 0.7)),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  /// Tapping a day's route opens that day's entry — the map is only useful
  /// if it leads back into the journal.
  void _openEntryForDay(int day, List<JournalEntry> monthEntries) {
    final match = monthEntries.where((e) => e.day.day == day).firstOrNull;
    if (match == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Kein Eintrag am ${formatShortDate(DateTime(_month.year, _month.month, day))}.'),
        ),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EntryDetailScreen(entryId: match.id)),
    );
  }

  void _openFullscreenMap(
    Map<int, List<DayLocationPoint>> pointsByDay,
    MonthStats stats,
  ) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapScreen(
          month: _month,
          pointsByDay: pointsByDay,
          moodByDay: stats.moodByDay,
          onDayTap: (day) => _openEntryForDay(day, stats.entries),
        ),
      ),
    );
  }

  /// The month's route, one line per day, coloured by that day's mood.
  Widget _moodMap(MonthStats stats) {
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final pointsByDay = <int, List<DayLocationPoint>>{};
    for (var day = 1; day <= daysInMonth; day++) {
      final points =
          _locations.pointsForDay(DateTime(_month.year, _month.month, day));
      if (points.isNotEmpty) pointsByDay[day] = points;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STIMMUNGSKARTE', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 16),
        MoodMap(
          pointsByDay: pointsByDay,
          moodByDay: stats.moodByDay,
          monthKey: _monthKey,
          onDayTap: (day) => _openEntryForDay(day, stats.entries),
          // A tap that misses every route means "let me look properly".
          onTapEmpty: () => _openFullscreenMap(pointsByDay, stats),
        ),
        // Must match what the map can actually draw: a day needs two points
        // to make a line, so a month of single fixes shows the placeholder —
        // and a legend underneath it would be nonsense.
        if (pointsByDay.values.any((points) => points.length >= 2)) ...[
          const SizedBox(height: 12),
          const MoodScaleLegend(),
          const SizedBox(height: 8),
          Text('Karten: Esri, HERE, Garmin, OpenStreetMap',
                      style: TEXT_STYLE_STATUS),
        ],
      ],
    );
  }

  Widget _moodChart(MonthStats stats, Color primary) {
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final moodByDay = stats.moodByDay;
    const maxHeight = 72.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STIMMUNGSVERLAUF', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 20),
        SizedBox(
          height: maxHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var day = 1; day <= daysInMonth; day++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Container(
                      height: moodByDay[day] == null
                          ? 2
                          : maxHeight * (moodByDay[day]! / 10).clamp(0.05, 1.0),
                      decoration: BoxDecoration(
                        color: primary.withValues(
                            alpha: moodByDay[day] == null ? 0.08 : 0.7),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (stats.averageMood != null) ...[
          const SizedBox(height: 12),
          Text('Ø ${stats.averageMood!.toStringAsFixed(1)} / 10',
              style: TEXT_STYLE_STATUS),
        ],
      ],
    );
  }

  Widget _dimensions(MonthStats stats, Color primary) {
    final avg = stats.averageDimensions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STIMMUNGSDIMENSIONEN', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 12),
        ...kMoodDimensions.map((d) => DimensionBar(
              dimensionKey: d,
              value: avg[d] ?? 0,
              primary: primary,
            )),
      ],
    );
  }

  /// Cached all-time aggregations. Every one of them walks the full entry
  /// list (and, for places, every location point), while this screen rebuilds
  /// on each month swipe, theme toggle and entry change — so they're computed
  /// once per entry list and reused.
  List<JournalEntry>? _statsSource;
  AllTimeStats? _allTime;
  List<PlaceCluster>? _placeClusters;

  /// [source] must be the notifier's own list, not a derived one: a filtered
  /// copy is a fresh object on every build, so keying on that would make the
  /// identity check always miss and cache nothing.
  void _ensureStats(List<JournalEntry> source, List<JournalEntry> ready) {
    if (identical(_statsSource, source)) return;
    _statsSource = source;
    final all = AllTimeStats(ready);
    _allTime = all;
    _placeClusters = clusterPlaces(
      pointsByDate: _locations.byDay,
      moodByDate: {
        for (final e in ready)
          if (e.moodScore != null) _dateKey(e.day): e.moodScore!,
      },
    );
  }

  /// Sections computed over every entry rather than the selected month.
  List<Widget> _allTimeSections(AllTimeStats all, Color primary) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sections = <Widget>[
      Text('MUSTER ÜBER ALLES', style: TEXT_STYLE_LABEL),
      const SizedBox(height: 8),
      Text('Aus allen ${all.entries.length} Einträgen, nicht nur diesem Monat.',
          style: TEXT_STYLE_STATUS),
    ];

    void add(Widget section) {
      sections
        ..add(const SizedBox(height: 36))
        ..add(section);
    }

    add(_yearGrid(all));

    final places = _placeClusters ?? const <PlaceCluster>[];
    if (places.isNotEmpty) {
      _resolvePlaceLabels(places);
      add(_places(places, isDark, primary));
    }

    final tagMoods = all.tagMoods;
    if (tagMoods.isNotEmpty) add(_tagMoods(tagMoods, isDark, primary));

    final byWeekday = all.moodByWeekday;
    if (byWeekday.isNotEmpty) add(_weekdayMoods(byWeekday, isDark, primary));

    if (all.entries.isNotEmpty) add(_recordingHours(all, primary));

    add(_dimensionTrend(all, primary));

    final correlations = all.dimensionCorrelations;
    if (correlations.isNotEmpty) add(_correlations(correlations));

    add(_language(all, primary));

    return sections;
  }

  /// Same `yyyy-MM-dd` key the location history buckets by.
  String _dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String _placeKey(PlaceCluster place) =>
      '${place.latitude.toStringAsFixed(4)},${place.longitude.toStringAsFixed(4)}';

  /// Names the clustered places in the background. Geocoding needs the
  /// network and can fail; coordinates remain as the fallback label, so this
  /// never blocks or breaks the section.
  Future<void> _resolvePlaceLabels(List<PlaceCluster> places) async {
    if (_resolvingPlaces) return;
    final pending = places
        .where((p) => !_placeLookupsTried.contains(_placeKey(p)))
        .toList();
    if (pending.isEmpty) return;

    _resolvingPlaces = true;
    var resolvedAny = false;
    for (final place in pending) {
      final key = _placeKey(place);
      _placeLookupsTried.add(key);
      final label = await _location.labelFor(place.latitude, place.longitude);
      if (label != null) {
        _placeLabels[key] = label;
        resolvedAny = true;
      }
    }
    _resolvingPlaces = false;
    if (resolvedAny && mounted) setState(() {});
  }

  /// Places you keep returning to, and how the days you spent there felt.
  Widget _places(List<PlaceCluster> places, bool isDark, Color primary) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ORTE × STIMMUNG', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 8),
        Text('Wie die Tage waren, an denen du dort warst.',
            style: TEXT_STYLE_STATUS),
        const SizedBox(height: 16),
        for (final place in places)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 110,
                  child: Text(
                    _placeLabels[_placeKey(place)] ??
                        '${place.latitude.toStringAsFixed(3)}, '
                            '${place.longitude.toStringAsFixed(3)}',
                    overflow: TextOverflow.ellipsis,
                    style: TEXT_STYLE_STATUS,
                  ),
                ),
                Expanded(
                  child: place.averageMood == null
                      ? const SizedBox(height: 3)
                      : _moodBar(place.averageMood!, isDark, primary),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 62,
                  child: Text(
                    // "an 12 Tagen", not "12 Tage dort": the cell only says
                    // you were inside a ~275m square that day, not how long.
                    '${place.averageMood?.toStringAsFixed(1) ?? '–'}'
                    ' · an ${place.dayCount}',
                    textAlign: TextAlign.right,
                    style: TEXT_STYLE_STATUS,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// The last 52 weeks at a glance, one cell per day.
  Widget _yearGrid(AllTimeStats all) {
    final moodByDate = <DateTime, double>{};
    final unscored = <DateTime>{};
    for (final entry in all.entries) {
      final key = DateTime(entry.day.year, entry.day.month, entry.day.day);
      if (entry.moodScore != null) {
        moodByDate[key] = entry.moodScore!;
      } else {
        unscored.add(key);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DAS LETZTE JAHR', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 16),
        YearGrid(moodByDate: moodByDate, unscoredDays: unscored),
      ],
    );
  }

  /// Tags ranked by how the entries carrying them felt, best first.
  Widget _tagMoods(List<TagMood> tagMoods, bool isDark, Color primary) {
    // Best and worst are the interesting ends, so a long list keeps both
    // rather than truncating the bottom away.
    final truncated = tagMoods.length > 12;
    final top = truncated ? tagMoods.take(6).toList() : tagMoods;
    final bottom =
        truncated ? tagMoods.skip(tagMoods.length - 6).toList() : <TagMood>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('TAGS × STIMMUNG', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 16),
        for (final tag in top) _tagMoodRow(tag, isDark, primary),
        if (truncated) ...[
          Padding(
            padding: const EdgeInsets.only(left: 96, bottom: 12),
            child: Text('… ${tagMoods.length - 12} weitere',
                style: TEXT_STYLE_STATUS),
          ),
          for (final tag in bottom) _tagMoodRow(tag, isDark, primary),
        ],
      ],
    );
  }

  Widget _tagMoodRow(TagMood tag, bool isDark, Color primary) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(tag.tag,
                overflow: TextOverflow.ellipsis, style: TEXT_STYLE_STATUS),
          ),
          Expanded(child: _moodBar(tag.averageMood, isDark, primary)),
          const SizedBox(width: 12),
          SizedBox(
            width: 56,
            child: Text(
              '${tag.averageMood.toStringAsFixed(1)} · ${tag.count}×',
              textAlign: TextAlign.right,
              style: TEXT_STYLE_STATUS,
            ),
          ),
        ],
      ),
    );
  }

  /// Average mood per weekday — Monday first, matching the calendar.
  Widget _weekdayMoods(Map<int, double> byWeekday, bool isDark, Color primary) {
    const labels = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STIMMUNG NACH WOCHENTAG', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 16),
        for (var weekday = DateTime.monday;
            weekday <= DateTime.sunday;
            weekday++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 32,
                  child: Text(labels[weekday - 1], style: TEXT_STYLE_STATUS),
                ),
                Expanded(
                  child: byWeekday[weekday] == null
                      ? const SizedBox(height: 3)
                      : _moodBar(byWeekday[weekday]!, isDark, primary),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 28,
                  child: Text(
                    byWeekday[weekday]?.toStringAsFixed(1) ?? '–',
                    textAlign: TextAlign.right,
                    style: TEXT_STYLE_STATUS,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// A 0..10 mood as a bar in that mood's colour.
  Widget _moodBar(double mood, bool isDark, Color primary) {
    return Stack(
      children: [
        Container(
          height: 3,
          decoration: BoxDecoration(
            color: primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        FractionallySizedBox(
          widthFactor: (mood / 10).clamp(0.0, 1.0),
          child: Container(
            height: 3,
            decoration: BoxDecoration(
              color: moodColor(mood, isDark: isDark),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ],
    );
  }

  /// When recordings actually happen, by hour of day.
  Widget _recordingHours(AllTimeStats all, Color primary) {
    final byHour = all.recordingsByHour;
    final peak = byHour.values.isEmpty
        ? 0
        : byHour.values.reduce((a, b) => a > b ? a : b);
    const maxHeight = 48.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('WANN DU AUFNIMMST', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 16),
        SizedBox(
          height: maxHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var hour = 0; hour < 24; hour++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Container(
                      height: peak == 0
                          ? 2
                          : (maxHeight * (byHour[hour] ?? 0) / peak)
                              .clamp(2.0, maxHeight),
                      decoration: BoxDecoration(
                        color: primary.withValues(
                            alpha: (byHour[hour] ?? 0) == 0 ? 0.08 : 0.7),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('0', style: TEXT_STYLE_STATUS),
            Text('6', style: TEXT_STYLE_STATUS),
            Text('12', style: TEXT_STYLE_STATUS),
            Text('18', style: TEXT_STYLE_STATUS),
            Text('24', style: TEXT_STYLE_STATUS),
          ],
        ),
      ],
    );
  }

  /// Each dimension's monthly average as a sparkline over the last year.
  Widget _dimensionTrend(AllTimeStats all, Color primary) {
    final trend = all.dimensionTrend();
    final hasData = trend.values.any((series) => series.length > 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DIMENSIONEN ÜBER 12 MONATE', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 16),
        if (!hasData)
          Text('Noch zu wenige Monate mit Einträgen.',
              style: TEXT_STYLE_STATUS)
        else
          for (final dimension in kMoodDimensions)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(dimensionLabels[dimension] ?? dimension,
                        style: TEXT_STYLE_STATUS),
                  ),
                  Expanded(
                    child: SizedBox(
                      height: 24,
                      child: CustomPaint(
                        painter: SparklinePainter(
                          values: trend[dimension] ?? const [],
                          color: primary,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  /// Which dimensions move together — the strongest relationships first.
  Widget _correlations(List<({String a, String b, double r})> correlations) {
    String strength(double r) {
      final magnitude = r.abs();
      if (magnitude >= 0.6) return 'stark';
      if (magnitude >= 0.35) return 'deutlich';
      if (magnitude >= 0.2) return 'schwach';
      return 'kaum';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('WAS ZUSAMMENHÄNGT', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 16),
        for (final pair in correlations.take(5))
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${dimensionLabels[pair.a]} ↔ ${dimensionLabels[pair.b]}',
                    style: TEXT_STYLE_STATUS,
                  ),
                ),
                Text(
                  '${pair.r >= 0 ? '+' : ''}${pair.r.toStringAsFixed(2)}'
                  ' · ${strength(pair.r)}',
                  style: TEXT_STYLE_STATUS,
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Transcript-derived numbers plus the words that come up most.
  Widget _language(AllTimeStats all, Color primary) {
    final words = all.wordStats;
    final average = words.averageWordsPerEntry;
    final topWords = words.topWords();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SPRACHE', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 16),
        if (average == null)
          Text('Noch keine Transkripte.', style: TEXT_STYLE_STATUS)
        else ...[
          Text('${words.totalWords} Wörter insgesamt', style: TEXT_STYLE_BODY),
          const SizedBox(height: 4),
          Text('Ø ${average.round()} pro Eintrag', style: TEXT_STYLE_STATUS),
          if (topWords.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: topWords.map((word) {
                return Text(
                  word.key,
                  style: TEXT_STYLE_BODY.copyWith(
                    // Size carries frequency — the most-used word is biggest.
                    fontSize: 13 + (word.value / topWords.first.value) * 9,
                    color: primary.withValues(
                        alpha: 0.4 + (word.value / topWords.first.value) * 0.6),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ],
    );
  }

  Widget _tags(MonthStats stats, Color primary) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('HÄUFIGSTE TAGS', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: stats.topTags.take(10).map((t) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: primary.withValues(alpha: 0.3)),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('${t.key} · ${t.value}',
                  style: TEXT_STYLE_STATUS.copyWith(color: primary)),
            );
          }).toList(),
        ),
      ],
    );
  }
}
