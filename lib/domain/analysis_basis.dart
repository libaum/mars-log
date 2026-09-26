import 'dart:convert';
import 'package:crypto/crypto.dart';

/// A short fingerprint of the transcript an analysis was made from. An
/// analysis whose basis no longer matches the entry's transcript is stale —
/// the laptop analyses it again.
String transcriptBasis(String? transcript) =>
    sha256.convert(utf8.encode((transcript ?? '').trim())).toString().substring(0, 16);

/// Who produced an entry's analysis. The laptop's model is the better one:
/// its analysis replaces the phone's quick pre-analysis, never the other way
/// round unless the phone re-analyses on purpose.
abstract final class AnalysisSource {
  static const phone = 'phone';
  static const laptop = 'laptop';
}
