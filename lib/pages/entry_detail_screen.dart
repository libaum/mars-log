import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/mood.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
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
                // Deleted elsewhere — leave the screen.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) Navigator.pop(context);
                });
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
        Text(formatLongDate(entry.day), style: TEXT_STYLE_TITLE),
        const SizedBox(height: 28),

        // Audio playback
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
            await _journal.delete(entry);
            if (mounted) Navigator.pop(context);
          },
          child: Text('Löschen',
              style: TEXT_STYLE_SETTING.copyWith(color: COLOR_SECONDARY)),
        ),
      ],
    );
  }
}
