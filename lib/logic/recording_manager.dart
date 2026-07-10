import 'dart:async';
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
  final ValueNotifier<Duration> elapsedNotifier = ValueNotifier(Duration.zero);

  Timer? _timer;
  DateTime? _startedAt;
  String? _id;

  Future<bool> hasPermission() => _rec.hasPermission();

  /// Returns false if microphone permission was denied.
  Future<bool> start() async {
    if (!await _rec.hasPermission()) return false;
    final now = DateTime.now();
    _startedAt = now;
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
    elapsedNotifier.value = Duration.zero;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      elapsedNotifier.value = DateTime.now().difference(_startedAt!);
    });
    return true;
  }

  /// Stops and returns the recording metadata, or null on failure.
  Future<RecordingResult?> stop() async {
    _timer?.cancel();
    final path = await _rec.stop();
    recordingNotifier.value = false;
    elapsedNotifier.value = Duration.zero;
    if (path == null || _id == null || _startedAt == null) return null;
    return RecordingResult(
      id: _id!,
      fileName: '$_id.wav',
      createdAt: _startedAt!,
    );
  }
}
