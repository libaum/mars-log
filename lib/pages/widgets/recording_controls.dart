import 'package:flutter/material.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/logic/recording_manager.dart';
import 'package:mars_log/pages/widgets/confirm_dialog.dart';
import 'package:mars_log/pages/widgets/record_button.dart';
import 'package:mars_log/services/service_locator.dart';

/// Wires [RecordButton] to [RecordingManager]/[JournalManager]: start/pause/
/// resume via the circle tap, cancel (with confirmation) or send while paused.
///
/// [day] pins a sent recording to a specific day (e.g. adding a second
/// recording to an existing day) instead of the recording's own date.
class RecordingControls extends StatelessWidget {
  final DateTime? day;
  final VoidCallback? onSent;
  const RecordingControls({super.key, this.day, this.onSent});

  @override
  Widget build(BuildContext context) {
    final recording = getIt<RecordingManager>();
    final journal = getIt<JournalManager>();

    return RecordButton(
      onCircleTap: () async {
        if (recording.pausedNotifier.value) {
          await recording.resume();
        } else if (recording.recordingNotifier.value) {
          await recording.pause();
        } else {
          final started = await recording.start();
          if (!started && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Mikrofon-Zugriff wird benötigt.')),
            );
          }
        }
      },
      onCancel: () async {
        final confirmed = await showConfirmDialog(
          context,
          title: 'Aufnahme verwerfen?',
          confirmLabel: 'Verwerfen',
        );
        if (confirmed) await recording.cancel();
      },
      onSend: () async {
        final result = await recording.stop();
        if (result != null) {
          // Fire-and-forget: the manager flips the entry to ready/failed itself.
          journal.createFromAudio(result, day: day);
          onSent?.call();
        }
      },
    );
  }
}
