/// Processing state of an entry.
enum EntryStatus { analyzing, ready, failed }

/// The six mood dimensions Gemini estimates (0..100 each).
/// Stored on every entry for future trend analysis, even if V1 barely shows them.
const kMoodDimensions = <String>[
  'positivity',
  'energy',
  'calm',
  'stress',
  'focus',
  'social',
];

/// A single journal entry.
///
/// Audio + transcript are the permanent source of truth. Everything derived
/// (summary, mood, tags, dimensions) may be recomputed later with a better
/// prompt/model — see [analysisModel] / [analysisVersion].
class JournalEntry {
  final String id;
  final DateTime createdAt;
  DateTime day;
  final String audioFileName;

  EntryStatus status;
  String? transcript;
  String? summary;
  String? moodLabel;
  double? moodScore; // 0..10
  Map<String, int>? dimensions; // 0..100 per kMoodDimensions
  List<String> tags;
  String? analysisModel;
  int? analysisVersion;
  String? errorMessage;

  /// When non-null, the entry lives in the trash (soft-deleted). Audio +
  /// transcript are kept until it is purged (manually or after retention).
  DateTime? deletedAt;

  JournalEntry({
    required this.id,
    required this.createdAt,
    required this.day,
    required this.audioFileName,
    this.status = EntryStatus.analyzing,
    this.transcript,
    this.summary,
    this.moodLabel,
    this.moodScore,
    this.dimensions,
    List<String>? tags,
    this.analysisModel,
    this.analysisVersion,
    this.errorMessage,
    this.deletedAt,
  }) : tags = tags ?? const [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'day': day.toIso8601String(),
        'audioFileName': audioFileName,
        'status': status.name,
        'transcript': transcript,
        'summary': summary,
        'moodLabel': moodLabel,
        'moodScore': moodScore,
        'dimensions': dimensions,
        'tags': tags,
        'analysisModel': analysisModel,
        'analysisVersion': analysisVersion,
        'errorMessage': errorMessage,
        'deletedAt': deletedAt?.toIso8601String(),
      };

  factory JournalEntry.fromJson(Map<String, dynamic> json) {
    final dims = json['dimensions'];
    return JournalEntry(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      day: DateTime.parse(json['day'] as String),
      audioFileName: json['audioFileName'] as String,
      status: EntryStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => EntryStatus.ready,
      ),
      transcript: json['transcript'] as String?,
      summary: json['summary'] as String?,
      moodLabel: json['moodLabel'] as String?,
      moodScore: (json['moodScore'] as num?)?.toDouble(),
      dimensions: dims == null
          ? null
          : (dims as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, (v as num).toInt())),
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? const [],
      analysisModel: json['analysisModel'] as String?,
      analysisVersion: json['analysisVersion'] as int?,
      errorMessage: json['errorMessage'] as String?,
      deletedAt: json['deletedAt'] == null
          ? null
          : DateTime.parse(json['deletedAt'] as String),
    );
  }
}

/// Result of a Gemini analysis pass — the recomputable interpretation of one entry.
class AnalysisResult {
  final String transcript;
  final String summary;
  final String moodLabel;
  final double moodScore;
  final Map<String, int> dimensions;
  final List<String> tags;

  AnalysisResult({
    required this.transcript,
    required this.summary,
    required this.moodLabel,
    required this.moodScore,
    required this.dimensions,
    required this.tags,
  });
}
