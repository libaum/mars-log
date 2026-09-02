import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/mood.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/pages/entry_detail_screen.dart';
import 'package:mars_log/pages/settings_screen.dart';
import 'package:mars_log/pages/stats_screen.dart';
import 'package:mars_log/pages/widgets/confirm_dialog.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
import 'package:mars_log/pages/widgets/entry_tile.dart';
import 'package:mars_log/pages/widgets/recording_controls.dart';
import 'package:mars_log/pages/widgets/swipe_to_delete.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _journal = getIt<JournalManager>();

  /// Ids of the entries picked in selection mode. Non-null means the timeline
  /// is in selection mode (a tap toggles a row instead of opening it).
  Set<String>? _selected;

  bool get _selecting => _selected != null;

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  void _openStats() {
    Navigator.push(context, _slideDownRoute(const StatsScreen()));
  }

  Route _slideDownRoute(Widget page) => PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => page,
        transitionsBuilder: (_, animation, _, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
              .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
      );

  void _openEntry(JournalEntry entry) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EntryDetailScreen(entryId: entry.id)),
    );
  }

  void _startSelection(JournalEntry entry) {
    HapticFeedback.mediumImpact();
    setState(() => _selected = {entry.id});
  }

  void _toggle(JournalEntry entry) {
    final selected = _selected;
    if (selected == null) return;
    setState(() {
      if (!selected.remove(entry.id)) selected.add(entry.id);
      if (selected.isEmpty) _selected = null;
    });
  }

  void _endSelection() => setState(() => _selected = null);

  void _toggleAll(List<JournalEntry> entries) {
    final selected = _selected;
    if (selected == null) return;
    setState(() {
      if (selected.length == entries.length) {
        selected.clear();
      } else {
        _selected = entries.map((e) => e.id).toSet();
      }
    });
  }

  /// Copies the transcripts of the picked entries, oldest first, each under its
  /// date — the plain-text form of a stretch of days.
  Future<void> _copySelected(List<JournalEntry> entries) async {
    final selected = _selected ?? const {};
    final picked = entries.where((e) => selected.contains(e.id)).toList()
      ..sort((a, b) => a.day.compareTo(b.day));

    final blocks = <String>[];
    for (final entry in picked) {
      final text = entry.transcript?.trim();
      if (text == null || text.isEmpty) continue;
      blocks.add('${formatLongDate(entry.day)}\n\n$text');
    }

    if (blocks.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Keine Transkription in der Auswahl.')),
        );
      }
      return;
    }

    await Clipboard.setData(ClipboardData(text: blocks.join('\n\n---\n\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(blocks.length == 1
            ? '1 Eintrag kopiert.'
            : '${blocks.length} Einträge kopiert.'),
      ),
    );
    _endSelection();
  }

  @override
  Widget build(BuildContext context) {
    return DoubleTapThemeToggle(
      child: PopScope(
        canPop: !_selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _endSelection();
        },
        child: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                GestureDetector(
                  onLongPress: _openSettings,
                  onVerticalDragEnd: (details) {
                    if ((details.primaryVelocity ?? 0) > 250) _openStats();
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.only(top: 56, bottom: 28),
                    child: const Column(
                      children: [
                        RecordingControls(),
                      ],
                    ),
                  ),
                ),
                _divider(),
                Expanded(child: _timeline()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _divider() => Divider(
        height: 1,
        thickness: 0.5,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
      );

  Widget _timeline() {
    return ValueListenableBuilder<List<JournalEntry>>(
      valueListenable: _journal.entriesNotifier,
      builder: (context, entries, _) {
        if (entries.isEmpty) {
          return const Center(
            child: Text(
              'Noch keine Einträge.\nTippe auf den Kreis und erzähl von deinem Tag.',
              textAlign: TextAlign.center,
              style: TEXT_STYLE_STATUS,
            ),
          );
        }
        return Column(
          children: [
            Expanded(child: _list(entries)),
            if (_selecting) ...[_divider(), _selectionBar(entries)],
          ],
        );
      },
    );
  }

  Widget _list(List<JournalEntry> entries) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: entries.length,
      separatorBuilder: (context, _) => Divider(
        height: 1,
        thickness: 0.5,
        indent: 32,
        endIndent: 32,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
      ),
      itemBuilder: (context, i) {
        final entry = entries[i];
        final tile = EntryTile(
          entry: entry,
          selectionMode: _selecting,
          selected: _selected?.contains(entry.id) ?? false,
          onTap: () => _selecting ? _toggle(entry) : _openEntry(entry),
          onLongPress: _selecting ? null : () => _startSelection(entry),
        );
        // No swipe-to-delete while selecting — the row belongs to the picker.
        if (_selecting) return KeyedSubtree(key: ValueKey(entry.id), child: tile);
        return SwipeToDelete(
          key: ValueKey(entry.id),
          onDelete: () async {
            final ok = await showConfirmDialog(
              context,
              title: 'In den Papierkorb?',
              message: 'Du kannst den Eintrag im Papierkorb wiederherstellen.',
            );
            if (ok) _journal.delete(entry);
          },
          child: tile,
        );
      },
    );
  }

  Widget _selectionBar(List<JournalEntry> entries) {
    final count = _selected?.length ?? 0;
    final all = count == entries.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: _endSelection,
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Auswahl beenden',
          ),
          Text('$count', style: TEXT_STYLE_SETTING),
          const Spacer(),
          TextButton(
            onPressed: () => _toggleAll(entries),
            child: Text(all ? 'Keine' : 'Alle', style: TEXT_STYLE_SETTING),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: count == 0 ? null : () => _copySelected(entries),
            child: Text('Kopieren', style: TEXT_STYLE_SETTING),
          ),
        ],
      ),
    );
  }
}
