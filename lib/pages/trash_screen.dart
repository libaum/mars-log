import 'package:flutter/material.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/mood.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/pages/widgets/confirm_dialog.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/sync/sync_service.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// The trash: soft-deleted entries. Each can be restored or purged for good.
/// Entries older than [JournalRepository.trashRetention] are purged
/// automatically — see [JournalRepository.purgeExpired].
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  final _journal = getIt<JournalManager>();

  Future<void> _restore(JournalEntry entry) async {
    await _journal.restore(entry);
    _snack('Wiederhergestellt.');
  }

  Future<void> _purge(JournalEntry entry) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Endgültig löschen?',
      message: 'Aufnahme und Text werden dauerhaft entfernt. '
          'Das lässt sich nicht rückgängig machen.',
    );
    if (ok) await _journal.purge(entry);
  }

  Future<void> _emptyTrash() async {
    // What the user sees now; a sync round may trash more meanwhile.
    final shown = _journal.trashNotifier.value.map((e) => e.id).toSet();
    final ok = await showConfirmDialog(
      context,
      title: 'Papierkorb leeren?',
      message: 'Alle Einträge im Papierkorb werden dauerhaft entfernt. '
          'Das lässt sich nicht rückgängig machen.',
      confirmLabel: 'Leeren',
    );
    if (ok) await _journal.emptyTrash(only: shown);
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return DoubleTapThemeToggle(
      child: Scaffold(
        body: SafeArea(
          child: ValueListenableBuilder<List<JournalEntry>>(
            valueListenable: _journal.trashNotifier,
            builder: (context, entries, _) {
              return ListView(
                children: [
                  const SizedBox(height: 32),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32),
                    child: Text('Papierkorb', style: TEXT_STYLE_TITLE),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: ValueListenableBuilder<SyncStatus>(
                      valueListenable: getIt<SyncService>().statusNotifier,
                      // Paired, the 30-day purge waits for a completed round
                      // (PurgeTrace.defersAutoPurge) — none, no purge.
                      builder: (context, status, _) => Text(
                        status.phase == SyncPhase.error
                            ? 'Einträge werden nach 30 Tagen automatisch '
                                'entfernt – aber erst wieder, wenn der Sync '
                                'klappt.'
                            : 'Einträge werden nach 30 Tagen automatisch entfernt.',
                        style: TEXT_STYLE_STATUS,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (entries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32, vertical: 40),
                      child: Text('Der Papierkorb ist leer.',
                          style: TEXT_STYLE_STATUS),
                    )
                  else ...[
                    for (final entry in entries) _TrashTile(
                      entry: entry,
                      onRestore: () => _restore(entry),
                      onPurge: () => _purge(entry),
                    ),
                    const SizedBox(height: 16),
                    InkWell(
                      onTap: _emptyTrash,
                      splashColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                        child: Text('Papierkorb leeren',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w300,
                                color: COLOR_SECONDARY)),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TrashTile extends StatelessWidget {
  final JournalEntry entry;
  final VoidCallback onRestore;
  final VoidCallback onPurge;

  const _TrashTile({
    required this.entry,
    required this.onRestore,
    required this.onPurge,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final summary = entry.summary?.trim();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(moodEmoji(entry.moodScore), style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(formatRelativeDate(entry.day), style: TEXT_STYLE_DATE),
                const SizedBox(height: 4),
                Text(
                  (summary == null || summary.isEmpty)
                      ? 'Kein Text erkannt'
                      : summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TEXT_STYLE_SUMMARY,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRestore,
            icon: Icon(Icons.restore, color: primary.withValues(alpha: 0.7)),
            tooltip: 'Wiederherstellen',
          ),
          IconButton(
            onPressed: onPurge,
            icon: const Icon(Icons.delete_outline, color: COLOR_SECONDARY),
            tooltip: 'Endgültig löschen',
          ),
        ],
      ),
    );
  }
}
