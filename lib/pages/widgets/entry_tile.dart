import 'package:flutter/material.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/mood.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// One line in the timeline: date, mood, and a glimpse of the summary.
class EntryTile extends StatelessWidget {
  final JournalEntry entry;
  final VoidCallback onTap;
  const EntryTile({super.key, required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: 34, child: Center(child: _leading(primary))),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(formatRelativeDate(entry.day), style: TEXT_STYLE_DATE),
                  const SizedBox(height: 4),
                  Text(
                    _subtitle(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TEXT_STYLE_SUMMARY,
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
        return 'Wird analysiert …';
      case EntryStatus.failed:
        return entry.errorMessage ?? 'Analyse fehlgeschlagen';
      case EntryStatus.ready:
        final s = entry.summary?.trim();
        return (s == null || s.isEmpty) ? 'Kein Text erkannt' : s;
    }
  }
}
