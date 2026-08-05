import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/services/service_locator.dart';

/// Metadata for one finished recording, handed to the JournalManager.
class RecordingResult {
  final String id;
  final String fileName;
  final DateTime createdAt;
  RecordingResult(
      {required this.id, required this.fileName, required this.createdAt});
}

/// Owns the microphone lifecycle. Records to WAV (16 kHz mono) — small enough
/// to inline into a Gemini request and a format Gemini always accepts.
class RecordingManager {
  final _repo = getIt<JournalRepository>();
  final AudioRecorder _rec = AudioRecorder();

  final ValueNotifier<bool> recordingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> pausedNotifier = ValueNotifier(false);
  final ValueNotifier<Duration> elapsedNotifier = ValueNotifier(Duration.zero);

  Timer? _timer;
  DateTime? _recordingStartedAt;
  DateTime? _segmentStartedAt;
  Duration _pausedElapsed = Duration.zero;
  String? _id;

  Future<bool> hasPermission() => _rec.hasPermission();

  /// Returns false if microphone permission was denied.
  Future<bool> start() async {
    if (!await _rec.hasPermission()) return false;
    final now = DateTime.now();
    _recordingStartedAt = now;
    _segmentStartedAt = now;
    _pausedElapsed = Duration.zero;
    _id = now.millisecondsSinceEpoch.toString();

    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: _repo.audioPath('$_id.wav'),
    );

    recordingNotifier.value = true;
    pausedNotifier.value = false;
    elapsedNotifier.value = Duration.zero;
    _startTimer();
    return true;
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      elapsedNotifier.value =
          _pausedElapsed + DateTime.now().difference(_segmentStartedAt!);
    });
  }

  /// Pauses recording, keeping the elapsed timer frozen.
  Future<void> pause() async {
    if (!recordingNotifier.value || pausedNotifier.value) return;
    await _rec.pause();
    _timer?.cancel();
    _pausedElapsed = elapsedNotifier.value;
    pausedNotifier.value = true;
  }

  /// Resumes a paused recording.
  Future<void> resume() async {
    if (!pausedNotifier.value) return;
    await _rec.resume();
    _segmentStartedAt = DateTime.now();
    pausedNotifier.value = false;
    _startTimer();
  }

  /// Stops and returns the recording metadata, or null on failure.
  Future<RecordingResult?> stop() async {
    _timer?.cancel();
    final path = await _rec.stop();
    recordingNotifier.value = false;
    pausedNotifier.value = false;
    elapsedNotifier.value = Duration.zero;
    if (path == null || _id == null || _recordingStartedAt == null) {
      return null;
    }
    return RecordingResult(
      id: _id!,
      fileName: '$_id.wav',
      createdAt: _recordingStartedAt!,
    );
  }

  /// Stops recording and discards the audio file, as if it never happened.
  Future<void> cancel() async {
    _timer?.cancel();
    final path = await _rec.stop();
    recordingNotifier.value = false;
    pausedNotifier.value = false;
    elapsedNotifier.value = Duration.zero;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }
}
