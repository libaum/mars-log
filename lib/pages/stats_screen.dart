import 'package:flutter/material.dart';
import 'package:mars_log/data/gemini_service.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/data/secure_storage_service.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/mood.dart';
import 'package:mars_log/domain/stats.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/pages/widgets/dimension_bar.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
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

  late DateTime _month;
  String? _review;
  bool _loadingReview = false;
  String? _reviewError;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _loadCachedReview();
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
              final monthEntries = entries
                  .where((e) =>
                      e.status == EntryStatus.ready &&
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
                      _moodChart(stats, primary),
                      const SizedBox(height: 36),
                      _dimensions(stats, primary),
                      if (stats.topTags.isNotEmpty) ...[
                        const SizedBox(height: 36),
                        _tags(stats, primary),
                      ],
                    ],
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
