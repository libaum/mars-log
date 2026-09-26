import 'dart:convert';
import 'package:crypto/crypto.dart';

/// A short fingerprint of the transcript an analysis was made from. An
/// analysis whose basis no longer matches the entry's transcript is stale —
/// the laptop analyses it again.
String transcriptBasis(String? transcript) =>
    sha256.convert(utf8.encode((transcript ?? '').trim())).toString().substring(0, 16);

/// Who produced an entry's analysis.
///
/// - [phone]: the on-device model's quick pre-analysis — the laptop replaces it.
/// - [laptop]: the laptop's local model (Ollama).
/// - [cloud]: Gemini from the transcript (the phone's cloud option) — better
///   than the laptop's model, so the laptop keeps it.
abstract final class AnalysisSource {
  static const phone = 'phone';
  static const laptop = 'laptop';
  static const cloud = 'cloud';
}
