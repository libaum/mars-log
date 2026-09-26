import 'package:flutter/material.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/mood.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// One line in the timeline: date, mood, and the entry's title (the summary
/// for entries analysed before titles existed).
///
/// In selection mode the mood glyph is replaced by a selection dot and
/// unselected rows fade back, so the timeline stays one calm list.
class EntryTile extends StatelessWidget {
  final JournalEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selectionMode;
  final bool selected;

  const EntryTile({
    super.key,
    required this.entry,
    required this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Opacity(
        opacity: selectionMode && !selected ? 0.4 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 34,
                child: Center(
                  child: selectionMode ? _selectionDot(primary) : _leading(primary),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(formatRelativeDate(entry.day), style: TEXT_STYLE_DATE),
                    const SizedBox(height: 4),
                    // Listens to the phase: Whisper → model changes the
                    // line without the entry itself changing.
                    ValueListenableBuilder<Map<String, AnalysisPhase>>(
                      valueListenable: getIt<JournalManager>().phases,
                      builder: (context, _, _) => Text(
                        _subtitle(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TEXT_STYLE_SUMMARY,
                      ),
                    ),
                  ],
                ),
              ),
              if (entry.status == EntryStatus.ready && entry.moodScore != null) ...[
                const SizedBox(width: 12),
                Text(
                  entry.moodScore!.toStringAsFixed(1),
                  style: TEXT_STYLE_SCORE.copyWith(fontSize: 22),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _selectionDot(Color primary) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: primary.withValues(alpha: 0.5), width: 0.8),
        color: selected ? primary : Colors.transparent,
      ),
    );
  }

  Widget _leading(Color primary) {
    switch (entry.status) {
      case EntryStatus.analyzing:
        return SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            valueColor: AlwaysStoppedAnimation(primary.withValues(alpha: 0.5)),
          ),
        );
      case EntryStatus.failed:
        return Text('⚠', style: TextStyle(fontSize: 20, color: primary));
      case EntryStatus.ready:
        return Text(moodEmoji(entry.moodScore), style: const TextStyle(fontSize: 24));
    }
  }

  String _subtitle() {
    switch (entry.status) {
      case EntryStatus.analyzing:
        return getIt<JournalManager>().phaseOf(entry) == AnalysisPhase.transcribing
            ? 'Wird transkribiert …'
            : 'Wird analysiert …';
      case EntryStatus.failed:
        return entry.errorMessage ?? 'Analyse fehlgeschlagen';
      case EntryStatus.ready:
        final title = entry.title?.trim();
        if (title != null && title.isNotEmpty) return title;
        final s = entry.summary?.trim();
        return (s == null || s.isEmpty) ? 'Kein Text erkannt' : s;
    }
  }
}
