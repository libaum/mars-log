import 'package:flutter/material.dart';
import 'package:mars_log/logic/recording_manager.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// The single primary action: a large circular tap target that starts/pauses/
/// resumes recording. Shows a live timer while recording, and while paused
/// offers to cancel or send the recording for analysis.
class RecordButton extends StatelessWidget {
  final VoidCallback onCircleTap;
  final VoidCallback onCancel;
  final VoidCallback onSend;
  const RecordButton({
    super.key,
    required this.onCircleTap,
    required this.onCancel,
    required this.onSend,
  });

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final recording = getIt<RecordingManager>();
    final primary = Theme.of(context).colorScheme.primary;

    return ValueListenableBuilder<bool>(
      valueListenable: recording.recordingNotifier,
      builder: (context, isRecording, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: recording.pausedNotifier,
          builder: (context, isPaused, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: onCircleTap,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 132,
                    height: 132,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: primary
                            .withValues(alpha: isRecording ? 1.0 : 0.4),
                        width: isRecording ? 2.0 : 1.0,
                      ),
                    ),
                    child: Icon(
                      !isRecording
                          ? Icons.mic_none
                          : (isPaused ? Icons.play_arrow : Icons.pause),
                      size: 44,
                      color: primary,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (isRecording)
                  ValueListenableBuilder<Duration>(
                    valueListenable: recording.elapsedNotifier,
                    builder: (context, elapsed, _) => Text(
                      _fmt(elapsed),
                      style: TEXT_STYLE_SCORE.copyWith(fontSize: 22),
                    ),
                  )
                else
                  Text('Tap to record', style: TEXT_STYLE_STATUS),
                if (isPaused) ...[
                  const SizedBox(height: 20),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: onCancel,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          child: Text('Abbrechen', style: TEXT_STYLE_STATUS),
                        ),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: onSend,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          child: Text('Senden', style: TEXT_STYLE_STATUS),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}
