import 'package:flutter/material.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/logic/recording_manager.dart';
import 'package:mars_log/pages/entry_detail_screen.dart';
import 'package:mars_log/pages/settings_screen.dart';
import 'package:mars_log/pages/widgets/confirm_dialog.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
import 'package:mars_log/pages/widgets/entry_tile.dart';
import 'package:mars_log/pages/widgets/record_button.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _recording = getIt<RecordingManager>();
  final _journal = getIt<JournalManager>();

  /// Starts when idle, pauses when recording, resumes when paused.
  Future<void> _onCircleTap() async {
    if (_recording.pausedNotifier.value) {
      await _recording.resume();
    } else if (_recording.recordingNotifier.value) {
      await _recording.pause();
    } else {
      final started = await _recording.start();
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mikrofon-Zugriff wird benötigt.')),
        );
      }
    }
  }

  Future<void> _cancelRecording() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Aufnahme verwerfen?',
      confirmLabel: 'Verwerfen',
    );
    if (confirmed) await _recording.cancel();
  }

  Future<void> _sendRecording() async {
    final result = await _recording.stop();
    if (result != null) {
      // Fire-and-forget: the manager flips the entry to ready/failed itself.
      _journal.createFromAudio(result);
    }
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  void _openEntry(JournalEntry entry) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EntryDetailScreen(entryId: entry.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DoubleTapThemeToggle(
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              GestureDetector(
                onLongPress: _openSettings,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(top: 24, bottom: 28),
                  child: Column(
                    children: [
                      RecordButton(
                        onCircleTap: _onCircleTap,
                        onCancel: _cancelRecording,
                        onSend: _sendRecording,
                      ),
                    ],
                  ),
                ),
              ),
              Divider(
                height: 1,
                thickness: 0.5,
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.1),
              ),
              Expanded(child: _timeline()),
            ],
          ),
        ),
      ),
    );
  }

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
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: entries.length,
          separatorBuilder: (context, _) => Divider(
            height: 1,
            thickness: 0.5,
            indent: 32,
            endIndent: 32,
            color:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
          ),
          itemBuilder: (context, i) {
            final entry = entries[i];
            return Dismissible(
              key: ValueKey(entry.id),
              direction: DismissDirection.endToStart,
              confirmDismiss: (_) => showConfirmDialog(
                context,
                title: 'In den Papierkorb?',
                message:
                    'Du kannst den Eintrag im Papierkorb wiederherstellen.',
              ),
              onDismissed: (_) => _journal.delete(entry),
              background: const SizedBox.shrink(),
              child: EntryTile(entry: entry, onTap: () => _openEntry(entry)),
            );
          },
        );
      },
    );
  }
}
