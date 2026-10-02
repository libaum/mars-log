import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/location_history_repository.dart';
import 'package:mars_log/domain/day_location_point.dart';
import 'package:mars_log/pages/map_screen.dart';
import 'package:mars_log/pages/widgets/mood_map.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/mood.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/pages/widgets/confirm_dialog.dart';
import 'package:mars_log/pages/widgets/dimension_bar.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
import 'package:mars_log/pages/widgets/people_sheet.dart';
import 'package:mars_log/pages/widgets/self_rating_sheet.dart';
import 'package:mars_log/domain/people_aliases.dart';
import 'package:mars_log/pages/widgets/recording_controls.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// Full view of one entry: audio, transcript, summary, mood, tags.
/// Reacts live to re-analysis via the journal's entriesNotifier.
/// Swipe left/right to page to the next/previous day's entry; pull down at
/// the top of an entry to close. Vertical scrolling locks the pager so a
/// slightly diagonal drag doesn't make the page wobble sideways.
class EntryDetailScreen extends StatefulWidget {
  final String entryId;
  const EntryDetailScreen({super.key, required this.entryId});

  @override
  State<EntryDetailScreen> createState() => _EntryDetailScreenState();
}

class _EntryDetailScreenState extends State<EntryDetailScreen> {
  final _journal = getIt<JournalManager>();
  final _repo = getIt<JournalRepository>();
  final _locations = getIt<LocationHistoryRepository>();
  // Axis lock for the current touch: vertical drags disable the pager.
  final _pagerLocked = ValueNotifier<bool>(false);
  Offset _touchDelta = Offset.zero;
  // Pull-down-to-close state.
  final _pullOffset = ValueNotifier<double>(0);
  static const _closeThreshold = 110.0;
  final _player = AudioPlayer();
  late String _currentId = widget.entryId;
  PageController? _pageController;
  String? _playingEntryId;
  int? _playingIndex;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingIndex = null);
    });
  }

  @override
  void dispose() {
    _pageController?.dispose();
    _pagerLocked.dispose();
    _pullOffset.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _rateSelf(JournalEntry entry) async {
    final v = entry.selfValence, a = entry.selfArousal;
    final rating = await showSelfRatingSheet(
      context,
      initial: v == null || a == null ? null : (valence: v, arousal: a),
    );
    if (rating != null) await _journal.setSelfRating(entry.id, rating);
  }

  /// Tap on a person: gone at once, with a way back — no dialog.
  Future<void> _removePerson(JournalEntry entry, String person) async {
    final before = await _journal.removePerson(entry.id, person);
    if (before == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text('$person entfernt'),
      action: SnackBarAction(
        label: 'Rückgängig',
        onPressed: () => _journal.restorePeople(entry.id, before),
      ),
    ));
  }

  Future<void> _togglePlay(JournalEntry entry, int index) async {
    if (_playingEntryId == entry.id && _playingIndex == index) {
      await _player.pause();
      setState(() => _playingIndex = null);
    } else {
      final path = _repo.audioPath(entry.audioFileNames[index]);
      if (!await File(path).exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Audiodatei nicht mehr vorhanden')),
          );
        }
        return;
      }
      await _player.play(DeviceFileSource(path));
      setState(() {
        _playingEntryId = entry.id;
        _playingIndex = index;
      });
    }
  }

  void _onPageChanged(List<JournalEntry> pages, int index) {
    if (_playingIndex != null) _player.stop();
    setState(() {
      _currentId = pages[index].id;
      _playingIndex = null;
    });
  }

  /// Keeps the pager on the current entry when the list around it changes
  /// (backdating re-sorts it, another entry gets added or deleted).
  void _keepPage(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _pageController;
      if (!mounted || controller == null || !controller.hasClients) return;
      final page = controller.page;
      if (page != null && page.round() != index) controller.jumpToPage(index);
    });
  }

  Future<void> _pickDay(JournalEntry entry) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: entry.day,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (picked != null) await _journal.setDay(entry, picked);
  }

  /// Prefers the readable label, falls back to raw coordinates so a captured
  /// location is still visible if reverse-geocoding failed, else a prompt.
  String _placeLabel(JournalEntry entry) {
    if (entry.place != null && entry.place!.isNotEmpty) return entry.place!;
    if (entry.latitude != null && entry.longitude != null) {
      return '${entry.latitude!.toStringAsFixed(4)}, '
          '${entry.longitude!.toStringAsFixed(4)}';
    }
    return 'Ort hinzufügen';
  }

  Future<void> _editPlace(JournalEntry entry) async {
    final controller = TextEditingController(text: entry.place ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ort', style: TEXT_STYLE_SETTING),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'z.B. Berlin, Kreuzberg'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) await _journal.setPlace(entry, result);
  }

  /// Opens the recording controls in a sheet; a sent recording is folded
  /// into this same entry (merged transcript/analysis) rather than creating
  /// a separate one, so we stay on this screen afterwards.
  Future<void> _addRecording(JournalEntry entry) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
            32, 32, 32, MediaQuery.of(sheetContext).viewInsets.bottom + 32),
        child: RecordingControls(
          appendTo: entry,
          onSent: () => Navigator.pop(sheetContext),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DoubleTapThemeToggle(
      child: Scaffold(
        body: SafeArea(
          child: ValueListenableBuilder<List<JournalEntry>>(
            valueListenable: _journal.entriesNotifier,
            builder: (context, entries, _) {
              // Oldest on the left, newest on the right — swiping left goes
              // forward in time.
              final pages = entries.reversed.toList();
              final index = pages.indexWhere((e) => e.id == _currentId);
              if (index < 0) {
                // Deleted (here or elsewhere) — leave the screen exactly once.
                if (!_leaving) {
                  _leaving = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) Navigator.pop(context);
                  });
                }
                return const SizedBox.shrink();
              }
              if (_pageController == null) {
                _pageController = PageController(initialPage: index);
              } else {
                _keepPage(index);
              }
              return _pager(pages);
            },
          ),
        ),
      ),
    );
  }

  /// Decides the gesture axis from the first few pixels of a touch: unless
  /// the drag is clearly horizontal, the pager is switched off for it.
  Widget _pager(List<JournalEntry> pages) {
    return Listener(
      onPointerDown: (_) {
        _touchDelta = Offset.zero;
        _pagerLocked.value = false;
      },
      onPointerMove: (e) {
        if (_pagerLocked.value) return;
        _touchDelta += e.delta;
        if (_touchDelta.distance > 6 &&
            _touchDelta.dx.abs() < _touchDelta.dy.abs() * 2) {
          _pagerLocked.value = true;
        }
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: ValueListenableBuilder<double>(
          valueListenable: _pullOffset,
          builder: (context, pull, child) =>
              Transform.translate(offset: Offset(0, pull), child: child),
          child: ValueListenableBuilder<bool>(
            valueListenable: _pagerLocked,
            builder: (context, locked, _) => PageView.builder(
              physics: locked ? const NeverScrollableScrollPhysics() : null,
              controller: _pageController,
              itemCount: pages.length,
              onPageChanged: (i) => _onPageChanged(pages, i),
              findChildIndexCallback: (key) {
                final i = pages.indexWhere(
                    (e) => e.id == (key as ValueKey<String>).value);
                return i < 0 ? null : i;
              },
              itemBuilder: (context, i) => KeyedSubtree(
                key: ValueKey(pages[i].id),
                child: _content(pages[i]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Pull-down-to-close: overscroll at the top moves the page down with the
  /// finger; released far enough, the entry closes, otherwise it snaps back.
  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is OverscrollNotification &&
        n.overscroll < 0 &&
        n.dragDetails != null) {
      _pullOffset.value = (_pullOffset.value - n.overscroll).clamp(0, 240);
    } else if (n is ScrollEndNotification && _pullOffset.value > 0) {
      final close = _pullOffset.value >= _closeThreshold;
      _pullOffset.value = 0;
      if (close && !_leaving) {
        _leaving = true;
        Navigator.pop(context);
      }
    }
    return false;
  }

  Widget _content(JournalEntry entry) {
    final primary = Theme.of(context).colorScheme.primary;
    final analyzing = entry.status == EntryStatus.analyzing;

    return ListView(
      // Clamping, so pulling past the top reports overscroll (see _onScroll)
      // instead of bouncing.
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
      children: [
        // Tap the date to move the entry to another day (backdating).
        // The mic circle starts another recording, kept on this same day.
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => _pickDay(entry),
                behavior: HitTestBehavior.opaque,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(formatDayTitle(entry.day), style: TEXT_STYLE_TITLE),
                    const SizedBox(width: 10),
                    Icon(Icons.edit_calendar_outlined,
                        size: 18, color: primary.withValues(alpha: 0.3)),
                  ],
                ),
              ),
            ),
            GestureDetector(
              onTap: entry.status == EntryStatus.analyzing
                  ? null
                  : () => _addRecording(entry),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: primary.withValues(
                          alpha: entry.status == EntryStatus.analyzing
                              ? 0.15
                              : 0.4)),
                ),
                child: Icon(Icons.mic_none,
                    size: 18,
                    color: primary.withValues(
                        alpha: entry.status == EntryStatus.analyzing
                            ? 0.25
                            : 0.6)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Location — tap to set/adjust the label (also on old entries).
        GestureDetector(
          onTap: () => _editPlace(entry),
          behavior: HitTestBehavior.opaque,
          child: Row(
            children: [
              Icon(Icons.place_outlined,
                  size: 16, color: primary.withValues(alpha: 0.4)),
              const SizedBox(width: 6),
              Text(_placeLabel(entry), style: TEXT_STYLE_STATUS),
            ],
          ),
        ),
        const SizedBox(height: 28),

        // Audio playback — one row per recording (unavailable once the
        // audio has been discarded).
        if (entry.audioDeleted)
          Row(
            children: [
              Icon(Icons.mic_off_outlined,
                  size: 20, color: primary.withValues(alpha: 0.4)),
              const SizedBox(width: 12),
              Text('Aufnahme gelöscht', style: TEXT_STYLE_STATUS),
            ],
          )
        else
          for (var i = 0; i < entry.audioFileNames.length; i++)
            Padding(
              padding: EdgeInsets.only(
                  bottom: i == entry.audioFileNames.length - 1 ? 0 : 16),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => _togglePlay(entry, i),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: primary.withValues(alpha: 0.4)),
                      ),
                      child: Icon(
                          _playingEntryId == entry.id && _playingIndex == i
                              ? Icons.pause
                              : Icons.play_arrow,
                          color: primary),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                      entry.audioFileNames.length > 1
                          ? 'Aufnahme ${i + 1}'
                          : 'Aufnahme',
                      style: TEXT_STYLE_STATUS),
                ],
              ),
            ),
        const SizedBox(height: 32),

        if (analyzing) ...[
          ValueListenableBuilder<Map<String, AnalysisPhase>>(
            valueListenable: _journal.phases,
            builder: (context, _, _) => Text(
              _journal.phaseOf(entry) == AnalysisPhase.transcribing
                  ? 'Wird transkribiert …'
                  : 'Wird analysiert …',
              style: TEXT_STYLE_STATUS,
            ),
          ),
          // Transcribed: the transcript is there to read while the model
          // works on the rest.
          if ((entry.transcript ?? '').isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('TRANSKRIPT', style: TEXT_STYLE_LABEL),
            const SizedBox(height: 10),
            Text(entry.transcript!, style: TEXT_STYLE_BODY),
          ],
        ] else if (entry.status == EntryStatus.pending) ...[
          ValueListenableBuilder<Map<String, DateTime>>(
            valueListenable: _journal.retryAt,
            builder: (context, _, _) =>
                Text(_journal.pendingText(entry), style: TEXT_STYLE_STATUS),
          ),
          const SizedBox(height: 28),
          if (entry.moodScore != null)
            ..._analysis(entry, primary)
          else if ((entry.transcript ?? '').isNotEmpty) ...[
            Text('TRANSKRIPT', style: TEXT_STYLE_LABEL),
            const SizedBox(height: 10),
            Text(entry.transcript!, style: TEXT_STYLE_BODY),
          ],
        ] else if (entry.status == EntryStatus.failed)
          Text(entry.errorMessage ?? 'Analyse fehlgeschlagen',
              style: TEXT_STYLE_SUMMARY.copyWith(color: COLOR_SECONDARY))
        else
          ..._analysis(entry, primary),

        ..._dayMap(entry),

        const SizedBox(height: 40),
        _actions(entry, analyzing),
      ],
    );
  }

  /// Route of the entry's day only, at the very bottom. Needs two fixes to
  /// draw a line; otherwise nothing is shown.
  List<Widget> _dayMap(JournalEntry entry) {
    final points = _locations.pointsForDay(entry.day);
    if (points.length < 2) return const [];
    final byDay = <int, List<DayLocationPoint>>{entry.day.day: points};
    final mood = <int, double>{
      if (entry.moodScore != null) entry.day.day: entry.moodScore!,
    };
    void open() => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MapScreen(
              month: entry.day,
              title: formatDayTitle(entry.day),
              pointsByDay: byDay,
              moodByDay: mood,
              onDayTap: (_) {},
            ),
          ),
        );
    return [
      const SizedBox(height: 40),
      Text('STANDORTVERLAUF', style: TEXT_STYLE_LABEL),
      const SizedBox(height: 16),
      MoodMap(
        pointsByDay: byDay,
        moodByDay: mood,
        monthKey: '${entry.day.year}-${entry.day.month}-${entry.day.day}',
        // Any tap — on the route or beside it — opens it fullscreen.
        onTapEmpty: open,
        onDayTap: (_) => open(),
      ),
    ];
  }

  List<Widget> _analysis(JournalEntry entry, Color primary) {
    return [
      if ((entry.title ?? '').isNotEmpty) ...[
        Text(entry.title!, style: TEXT_STYLE_SUMMARY),
        const SizedBox(height: 24),
      ],
      // Mood
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(moodEmoji(entry.moodScore), style: const TextStyle(fontSize: 32)),
          const SizedBox(width: 16),
          Expanded(
            child: Text(entry.moodLabel ?? '', style: TEXT_STYLE_SUMMARY),
          ),
          if (entry.moodScore != null)
            Text('${entry.moodScore!.toStringAsFixed(1)} / 10',
                style: TEXT_STYLE_SCORE.copyWith(fontSize: 24)),
        ],
      ),
      const SizedBox(height: 28),

      // The user's own rating — not the model's; tap to set or change it.
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _rateSelf(entry),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SELBST', style: TEXT_STYLE_LABEL),
            const SizedBox(height: 10),
            Text(
              entry.selfValence == null
                  ? 'Nicht eingeschätzt · tippen zum Nachtragen'
                  : 'Befinden ${entry.selfValence} · Energie ${entry.selfArousal}',
              style: entry.selfValence == null
                  ? TEXT_STYLE_STATUS
                  : TEXT_STYLE_BODY,
            ),
          ],
        ),
      ),
      const SizedBox(height: 28),

      if ((entry.summary ?? '').isNotEmpty) ...[
        Text('ZUSAMMENFASSUNG', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 10),
        Text(entry.summary!, style: TEXT_STYLE_BODY),
        const SizedBox(height: 28),
      ],

      if (entry.tags.isNotEmpty) ...[
        Text('TAGS', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: entry.tags
              .map((t) => Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      border: Border.all(color: primary.withValues(alpha: 0.3)),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(t, style: TEXT_STYLE_STATUS.copyWith(color: primary)),
                  ))
              .toList(),
        ),
        const SizedBox(height: 28),
      ],

      Text('MENSCHEN', style: TEXT_STYLE_LABEL),
      const SizedBox(height: 12),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final person in effectivePeople(entry, _repo.aliases))
            PersonChip(label: person, onTap: () => _removePerson(entry, person)),
          PersonChip(
            label: '+ Person',
            faint: true,
            onTap: () => showAddPeopleSheet(context, entry.id),
          ),
        ],
      ),
      const SizedBox(height: 28),

      if (entry.dimensions != null) ...[
        Text('STIMMUNG', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 12),
        ...kMoodDimensions.map((d) => DimensionBar(
              dimensionKey: d,
              value: entry.dimensions![d] ?? 0,
              primary: primary,
            )),
        const SizedBox(height: 28),
      ],

      if ((entry.transcript ?? '').isNotEmpty) ...[
        Text('TRANSKRIPT', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 10),
        Text(entry.transcript!, style: TEXT_STYLE_BODY),
      ],

      if ((entry.analysisModel ?? '').isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(
            {entry.transcriptionModel, entry.analysisModel}
                .whereType<String>()
                .where((m) => m.isNotEmpty)
                .join(' · '),
            style: TEXT_STYLE_STATUS.copyWith(
                color: primary.withValues(alpha: 0.4))),
      ],
    ];
  }

  Widget _actions(JournalEntry entry, bool analyzing) {
    final canTranscribe = !entry.audioDeleted && entry.audioFileNames.isNotEmpty;
    final reanalyzeButtons = [
      // From the transcript: seconds, no new transcription.
      TextButton(
        onPressed: analyzing ? null : () => _journal.reanalyze(entry),
        child: const Text('Neu analysieren', style: TEXT_STYLE_SETTING),
      ),
      if (canTranscribe)
        TextButton(
          onPressed: analyzing
              ? null
              : () => _journal.reanalyze(entry, retranscribe: true),
          child: const Text('Neu transkribieren', style: TEXT_STYLE_SETTING),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 4, runSpacing: 4, children: reanalyzeButtons),
        Row(
          children: [
            const Spacer(),
            TextButton(
              onPressed: () async {
                if (_leaving) return;
                final ok = await showConfirmDialog(
                  context,
                  title: 'In den Papierkorb?',
                  message:
                      'Du kannst den Eintrag im Papierkorb wiederherstellen.',
                );
                if (!ok || _leaving || !mounted) return;
                _leaving = true;
                _journal.delete(entry); // fire; the pop below is the only one
                Navigator.pop(context);
              },
              child: Text('Löschen',
                  style: TEXT_STYLE_SETTING.copyWith(color: COLOR_SECONDARY)),
            ),
          ],
        ),
      ],
    );
  }
}
