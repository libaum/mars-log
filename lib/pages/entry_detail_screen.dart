import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/mood.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/pages/widgets/confirm_dialog.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
import 'package:mars_log/pages/widgets/recording_controls.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// Full view of one entry: audio, transcript, summary, mood, tags.
/// Reacts live to re-analysis via the journal's entriesNotifier.
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
  bool _playing = false;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay(JournalEntry entry) async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
    } else {
      await _player.play(DeviceFileSource(_repo.audioPath(entry.audioFileName)));
      setState(() => _playing = true);
    }
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

  /// Opens the recording controls in a sheet, pinning any sent recording to
  /// this entry's day rather than today's date.
  Future<void> _addRecording(JournalEntry entry) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
            32, 32, 32, MediaQuery.of(sheetContext).viewInsets.bottom + 32),
        child: RecordingControls(
          day: entry.day,
          onSent: () {
            Navigator.pop(sheetContext);
            if (mounted) Navigator.pop(context);
          },
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
              JournalEntry? entry;
              for (final e in entries) {
                if (e.id == widget.entryId) {
                  entry = e;
                  break;
                }
              }
              if (entry == null) {
                // Deleted (here or elsewhere) — leave the screen exactly once.
                if (!_leaving) {
                  _leaving = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) Navigator.pop(context);
                  });
                }
                return const SizedBox.shrink();
              }
              return _content(entry);
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
        GestureDetector(
          onTap: () => _pickDay(entry),
          behavior: HitTestBehavior.opaque,
          child: Row(
            children: [
              Text(formatLongDate(entry.day), style: TEXT_STYLE_TITLE),
              const SizedBox(width: 10),
              Icon(Icons.edit_calendar_outlined,
                  size: 18, color: primary.withValues(alpha: 0.3)),
            ],
          ),
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
        const SizedBox(height: 16),

        // Add another recording, kept on this same day.
        GestureDetector(
          onTap: () => _addRecording(entry),
          behavior: HitTestBehavior.opaque,
          child: Row(
            children: [
              Icon(Icons.mic_none,
                  size: 16, color: primary.withValues(alpha: 0.4)),
              const SizedBox(width: 6),
              Text('Weitere Aufnahme für diesen Tag',
                  style: TEXT_STYLE_STATUS),
            ],
          ),
        ),
        const SizedBox(height: 28),

        // Audio playback (unavailable once the audio has been discarded)
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
          Row(
            children: [
              GestureDetector(
                onTap: () => _togglePlay(entry),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: primary.withValues(alpha: 0.4)),
                  ),
                  child: Icon(_playing ? Icons.pause : Icons.play_arrow,
                      color: primary),
                ),
              ),
              const SizedBox(width: 16),
              Text('Aufnahme', style: TEXT_STYLE_STATUS),
            ],
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
        ...kMoodDimensions.map((d) => _dimensionBar(d, entry.dimensions![d] ?? 0, primary)),
        const SizedBox(height: 28),
      ],

      if ((entry.transcript ?? '').isNotEmpty) ...[
        Text('TRANSKRIPT', style: TEXT_STYLE_LABEL),
        const SizedBox(height: 10),
        Text(entry.transcript!, style: TEXT_STYLE_BODY),
      ],
    ];
  }

  static const _dimensionLabels = {
    'positivity': 'Positivität',
    'energy': 'Energie',
    'calm': 'Ruhe',
    'stress': 'Stress',
    'focus': 'Fokus',
    'social': 'Sozialität',
  };

  Widget _dimensionBar(String key, int value, Color primary) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(_dimensionLabels[key] ?? key, style: TEXT_STYLE_STATUS),
          ),
          Expanded(
            child: Stack(
              children: [
                Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: (value / 100).clamp(0.0, 1.0),
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 28,
            child: Text('$value',
                textAlign: TextAlign.right, style: TEXT_STYLE_STATUS),
          ),
        ],
      ),
    );
  }

  Widget _actions(JournalEntry entry, bool analyzing) {
    return Row(
      children: [
        TextButton(
          onPressed: analyzing ? null : () => _journal.reanalyze(entry),
          child: Text(analyzing ? 'Analysiert …' : 'Neu analysieren',
              style: TEXT_STYLE_SETTING),
        ),
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
    );
  }
}
