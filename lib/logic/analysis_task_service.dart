import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the process alive while an analysis is in flight.
///
/// Android moves a backgrounded app into the cached bucket and freezes it after
/// a few seconds, which would stop a running transcription request midway. A
/// foreground service lifts the process out of that bucket for as long as it
/// runs, so the transcription and analysis survive the app being sent to the
/// background.
///
/// The work itself stays in the main isolate; the service is only there for the
/// priority bump, so it needs no task handler. Calls are ref-counted, so
/// several analyses running at once share a single service (and notification).
class AnalysisTaskService {
  static const _title = 'Mars Log';
  static const _text = 'Eintrag wird analysiert …';

  int _active = 0;
  bool _initialized = false;

  /// Runs [body] with the foreground service held. If the service can't be
  /// started (permission denied, unsupported platform) the work still runs —
  /// just without the background guarantee.
  Future<T> run<T>(Future<T> Function() body) async {
    await _acquire();
    try {
      return await body();
    } finally {
      await _release();
    }
  }

  Future<void> _acquire() async {
    _active++;
    if (!Platform.isAndroid || _active > 1) return;
    _init();
    await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: _title,
      notificationText: _text,
    );
  }

  Future<void> _release() async {
    _active--;
    if (!Platform.isAndroid || _active > 0) return;
    await FlutterForegroundTask.stopService();
  }

  void _init() {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'mars_log_analysis',
        channelName: 'Analyse',
        channelDescription:
            'Erscheint, solange ein Eintrag analysiert wird.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No repeating callback — the service exists purely to keep the
        // process unfrozen while the main isolate does the work.
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        // Nothing to resume without a task handler; a killed process picks
        // pending entries back up via JournalManager.resumePending().
        allowAutoRestart: false,
      ),
    );
    _initialized = true;
  }
}
