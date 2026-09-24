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
/// The transcript is the permanent source of truth. Audio is kept alongside it
/// but may be discarded once transcribed (see [audioDeleted] and the
/// "delete audio after transcription" setting); re-analysis then works from the
/// transcript text. Everything derived (summary, mood, tags, dimensions) may be
/// recomputed later with a better prompt/model — see [analysisModel] /
/// [analysisVersion].
class JournalEntry {
  final String id;
  final DateTime createdAt;
  DateTime day;

  /// When *anything* about this entry last changed — transcript, summary,
  /// day, place, tags, trash, restore. [createdAt] is fixed and [day] is
  /// user-chosen, so neither can order edits; this is the clock the sync
  /// layer resolves last-write-wins with.
  ///
  /// Stamped centrally in [JournalRepository], not at each call site, so a
  /// new mutation cannot forget it. Remote edits keep the stamp they arrive
  /// with — see `JournalRepository.applySynced`.
  DateTime changedAt;

  /// One or more recordings for this entry, oldest first. Usually just one;
  /// more than one when further recordings were added for the same day via
  /// "Weitere Aufnahme für diesen Tag".
  List<String> audioFileNames;

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

  /// True once the audio file has been discarded after transcription. The entry
  /// then lives on the transcript alone; playback is unavailable.
  bool audioDeleted;

  /// Optional location where the entry was recorded. [place] is a human-readable
  /// label (reverse-geocoded, user-editable); the coordinates are kept for
  /// reference. All three may be null (permission denied, offline, old entry).
  double? latitude;
  double? longitude;
  String? place;

  /// When non-null, the entry lives in the trash (soft-deleted). Audio +
  /// transcript are kept until it is purged (manually or after retention).
  DateTime? deletedAt;

  JournalEntry({
    required this.id,
    required this.createdAt,
    required this.day,
    required this.audioFileNames,
    DateTime? changedAt,
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
    this.audioDeleted = false,
    this.latitude,
    this.longitude,
    this.place,
  })  : tags = tags ?? const [],
        // Entries written before sync existed get their creation time, which
        // is the oldest stamp they could honestly claim.
        changedAt = changedAt ?? createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'day': day.toIso8601String(),
        'changedAt': changedAt.toIso8601String(),
        'audioFileNames': audioFileNames,
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
        'audioDeleted': audioDeleted,
        'latitude': latitude,
        'longitude': longitude,
        'place': place,
      };

  factory JournalEntry.fromJson(Map<String, dynamic> json) {
    final dims = json['dimensions'];
    return JournalEntry(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      day: DateTime.parse(json['day'] as String),
      changedAt: json['changedAt'] == null
          ? null
          : DateTime.parse(json['changedAt'] as String),
      // Back-compat: entries written before multi-recording support stored a
      // single 'audioFileName' string instead of the 'audioFileNames' list.
      audioFileNames: (json['audioFileNames'] as List<dynamic>?)
              ?.cast<String>() ??
          [json['audioFileName'] as String],
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
      audioDeleted: json['audioDeleted'] as bool? ?? false,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      place: json['place'] as String?,
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
