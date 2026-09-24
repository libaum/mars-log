import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/mood.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/pages/widgets/confirm_dialog.dart';
import 'package:mars_log/pages/widgets/dimension_bar.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
import 'package:mars_log/pages/widgets/recording_controls.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// Full view of one entry: audio, transcript, summary, mood, tags.
/// Reacts live to re-analysis via the journal's entriesNotifier.
/// Swipe left/right to page to the next/previous day's entry.
class EntryDetailScreen extends StatefulWidget {
  final String entryId;
  const EntryDetailScreen({super.key, required this.entryId});

  @override
  State<EntryDetailScreen> createState() => _EntryDetailScreenState();
}

class _EntryDetailScreenState extends State<EntryDetailScreen> {
  final _journal = getIt<JournalManager>();
  final _repo = getIt<JournalRepository>();
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
    _player.dispose();
    super.dispose();
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
              return PageView.builder(
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
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _content(JournalEntry entry) {
    final primary = Theme.of(context).colorScheme.primary;
    final analyzing = entry.status == EntryStatus.analyzing;

    return ListView(
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
                    Text(formatLongDate(entry.day), style: TEXT_STYLE_TITLE),
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

        if (analyzing)
          const Text('Wird analysiert …', style: TEXT_STYLE_STATUS)
        else if (entry.status == EntryStatus.failed)
          Text(entry.errorMessage ?? 'Analyse fehlgeschlagen',
              style: TEXT_STYLE_SUMMARY.copyWith(color: COLOR_SECONDARY))
        else
          ..._analysis(entry, primary),

        const SizedBox(height: 40),
        _actions(entry, analyzing),
      ],
    );
  }

  List<Widget> _analysis(JournalEntry entry, Color primary) {
    return [
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
        Text(entry.analysisModel!,
            style: TEXT_STYLE_STATUS.copyWith(
                color: primary.withValues(alpha: 0.4))),
      ],
    ];
  }

  Widget _actions(JournalEntry entry, bool analyzing) {
    final reanalyzeButtons = [
      TextButton(
        onPressed: analyzing ? null : () => _journal.reanalyze(entry),
        child: Text(analyzing ? 'Analysiert …' : 'Neu analysieren',
            style: TEXT_STYLE_SETTING),
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
