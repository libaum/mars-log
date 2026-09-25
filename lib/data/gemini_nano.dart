import 'package:flutter/services.dart';

/// Gemini Nano on the device, through the app's own platform channel
/// (`NanoChannel.kt`, ML Kit GenAI Prompt API / AICore).
///
/// Failures come back as [NanoException] with ML Kit's error code, and a
/// German message that says what to do — "not available" alone told the user
/// nothing.
class GeminiNano {
  static const _channel = MethodChannel('mars_log/nano');

  /// "AVAILABLE", "DOWNLOADABLE", "DOWNLOADING" or "UNAVAILABLE".
  Future<String> status() => _call<String>('status').then((s) => s ?? 'UNAVAILABLE');

  /// Makes sure the model is on the device, downloading it if AICore offers
  /// it. Throws [NanoException] if the device can't run it at all.
  Future<void> ensureReady() async {
    final s = await status();
    if (s == 'AVAILABLE') return;
    if (s == 'UNAVAILABLE') throw NanoException('UNAVAILABLE', null);
    await _call<void>('download');
  }

  Future<String> generate(
    String prompt, {
    double temperature = 0.4,
    int maxOutputTokens = 256,
  }) async {
    await ensureReady();
    final text = await _call<String>('generate', {
      'prompt': prompt,
      'temperature': temperature,
      'maxOutputTokens': maxOutputTokens,
    });
    return text?.trim() ?? '';
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw NanoException(e.code, e.message);
    } on MissingPluginException {
      throw NanoException('NO_PLATFORM', null);
    }
  }
}

class NanoException implements Exception {
  /// ML Kit's error-code name (e.g. `BACKGROUND_USE_BLOCKED`), or
  /// `UNAVAILABLE` / `NO_PLATFORM` / `UNKNOWN`.
  final String code;
  final String? detail;
  NanoException(this.code, this.detail);

  /// Nano refused because the app wasn't in the foreground — worth retrying
  /// once the user is back.
  bool get isBackground => code == 'BACKGROUND_USE_BLOCKED';

  @override
  String toString() {
    final text = switch (code) {
      'BACKGROUND_USE_BLOCKED' =>
        'Gemini Nano läuft nur, solange die App offen ist — wird beim nächsten Öffnen wiederholt.',
      'UNAVAILABLE' || 'NOT_SUPPORTED' =>
        'AICore meldet Gemini Nano als nicht unterstützt. Play Store: „AICore“ und „Private Compute Services“ aktualisieren, dann erneut versuchen.',
      'NEEDS_SYSTEM_UPDATE' =>
        'Gemini Nano braucht ein Systemupdate (Einstellungen → System → Softwareupdate).',
      'AICORE_INCOMPATIBLE' =>
        'AICore ist veraltet — im Play Store „AICore“ aktualisieren.',
      'NOT_ENOUGH_DISK_SPACE' =>
        'Zu wenig Speicher für das Gemini-Nano-Modell.',
      'BUSY' || 'QUOTA_EXCEEDED' =>
        'Gemini Nano ist gerade ausgelastet — später erneut versuchen.',
      'REQUEST_TOO_LARGE' =>
        'Der Text ist zu lang für Gemini Nano.',
      'NO_PLATFORM' => 'Gemini Nano gibt es nur auf Android.',
      _ => 'Gemini Nano ist fehlgeschlagen.',
    };
    return detail == null || detail!.isEmpty ? '$text [$code]' : '$text [$code: $detail]';
  }
}
