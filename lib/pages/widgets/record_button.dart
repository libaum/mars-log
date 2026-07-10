import 'package:flutter/material.dart';
import 'package:mars_log/logic/recording_manager.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// The single primary action: a large circular tap target that starts/stops
/// recording. Shows a live timer while recording.
class RecordButton extends StatelessWidget {
  final VoidCallback onToggle;
  const RecordButton({super.key, required this.onToggle});

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
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: onToggle,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 132,
                height: 132,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: primary.withValues(alpha: isRecording ? 1.0 : 0.4),
                    width: isRecording ? 2.0 : 1.0,
                  ),
                ),
                child: Icon(
                  isRecording ? Icons.stop : Icons.mic_none,
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
          ],
        );
      },
    );
  }
}
