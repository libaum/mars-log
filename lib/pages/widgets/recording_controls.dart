import 'package:flutter/material.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/logic/recording_manager.dart';
import 'package:mars_log/pages/widgets/confirm_dialog.dart';
import 'package:mars_log/pages/widgets/record_button.dart';
import 'package:mars_log/pages/widgets/self_rating_sheet.dart';
import 'package:mars_log/services/service_locator.dart';

/// Wires [RecordButton] to [RecordingManager]/[JournalManager]: start/pause/
/// resume via the circle tap, cancel (with confirmation) or send while paused.
///
/// If [appendTo] is set, a sent recording is folded into that existing entry
/// (same screen, merged transcript/analysis) instead of creating a new one.
///
/// A new entry asks for the self-rating: after the recording, or before it
/// (Settings). An appended recording doesn't, the entry has one already.
class RecordingControls extends StatelessWidget {
  final JournalEntry? appendTo;
  final VoidCallback? onSent;
  const RecordingControls({super.key, this.appendTo, this.onSent});

  @override
  Widget build(BuildContext context) {
    final recording = getIt<RecordingManager>();
    final journal = getIt<JournalManager>();
    final ratesBefore =
        appendTo == null && getIt<LocalStorageService>().getSelfRatingTiming() == kRatedBefore;

    return RecordButton(
      onCircleTap: () async {
        if (recording.pausedNotifier.value) {
          await recording.resume();
        } else if (recording.recordingNotifier.value) {
          await recording.pause();
        } else {
          if (ratesBefore) {
            journal.ratingForNextRecording = await showSelfRatingSheet(context);
            if (!context.mounted) return;
          }
          final started = await recording.start();
          if (!started) journal.ratingForNextRecording = null;
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
        if (!confirmed) return;
        await recording.cancel();
        journal.ratingForNextRecording = null;
      },
      onSend: () async {
        final result = await recording.stop();
        if (result != null) {
          // Fire-and-forget: the manager flips the entry to ready/failed itself.
          final target = appendTo;
          if (target != null) {
            journal.appendRecording(target, result);
            onSent?.call();
            return;
          }
          // The entry exists as soon as this returns its future (see
          // createFromAudio), so the rating can follow while it processes.
          journal.createFromAudio(result);
          onSent?.call();
          if (!ratesBefore && context.mounted) {
            final rating = await showSelfRatingSheet(context);
            if (rating != null) await journal.setSelfRating(result.id, rating);
          }
        }
      },
    );
  }
}
