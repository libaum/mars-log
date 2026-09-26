/// Processing state of an entry.
enum EntryStatus { analyzing, ready, failed }

/// The six mood dimensions the analysis estimates (0..100 each).
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

  /// A few words for what the day was — the entry's name in every list.
  /// Written by the analysis, or by hand ([titleByHand]).
  String? title;
  String? summary;
  String? moodLabel;
  double? moodScore; // 0..10
  Map<String, int>? dimensions; // 0..100 per kMoodDimensions
  List<String> tags;
  String? analysisModel;
  int? analysisVersion;
  String? errorMessage;

  // ── The analysis as a sync item of its own ────────────────────────────────
  //
  // The phone makes a quick pre-analysis, the laptop a better one that
  // replaces it. Both would otherwise write the same sync item as the human
  // edits (transcript, place, trash …), and last-write-wins would let an
  // analysis silently undo an edit made meanwhile on the other device. So
  // the analysis-owned fields — summary, moodLabel, moodScore, dimensions,
  // tags, analysisModel/Version and the three below — sync as a second item
  // (`<id>:analysis`, see JournalSyncRepository) with its own clock.
  //
  // A summary or tags edited by hand are the human's: [summaryByHand] /
  // [tagsByHand] move them into the entry item, and no analysis overwrites
  // them afterwards.

  /// The analysis item's last-write-wins clock. Null: no analysis yet, or one
  /// from before the split that never synced as its own item.
  DateTime? analysisChangedAt;

  /// [AnalysisSource.phone] or [AnalysisSource.laptop]; null for analyses
  /// from before the split (Gemini API, first on-device builds).
  String? analysisSource;

  /// [transcriptBasis] of the transcript the analysis was made from.
  String? analysisBasis;

  bool summaryByHand;
  bool tagsByHand;
  bool titleByHand;

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
    this.title,
    this.summary,
    this.moodLabel,
    this.moodScore,
    this.dimensions,
    List<String>? tags,
    this.analysisModel,
    this.analysisVersion,
    this.errorMessage,
    this.analysisChangedAt,
    this.analysisSource,
    this.analysisBasis,
    this.summaryByHand = false,
    this.tagsByHand = false,
    this.titleByHand = false,
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
        'title': title,
        'summary': summary,
        'moodLabel': moodLabel,
        'moodScore': moodScore,
        'dimensions': dimensions,
        'tags': tags,
        'analysisModel': analysisModel,
        'analysisVersion': analysisVersion,
        'errorMessage': errorMessage,
        'analysisChangedAt': analysisChangedAt?.toIso8601String(),
        'analysisSource': analysisSource,
        'analysisBasis': analysisBasis,
        'summaryByHand': summaryByHand,
        'tagsByHand': tagsByHand,
        'titleByHand': titleByHand,
        'deletedAt': deletedAt?.toIso8601String(),
        'audioDeleted': audioDeleted,
        'latitude': latitude,
        'longitude': longitude,
        'place': place,
      };

  /// The entry sync item: everything but the analysis ([kAnalysisKeys]) —
  /// except a summary / tags edited by hand, which are the human's.
  /// `v: 2` tells it apart from items written before the split, which carried
  /// the analysis inside.
  Map<String, dynamic> toEntryItemJson() {
    final json = toJson()..removeWhere((k, _) => kAnalysisKeys.contains(k));
    if (summaryByHand) json['summary'] = summary;
    if (tagsByHand) json['tags'] = tags;
    if (titleByHand) json['title'] = title;
    return json..['v'] = 2;
  }

  /// The analysis sync item (`<id>:analysis`). Summary / tags edited by hand
  /// are left out: they travel with the entry item.
  Map<String, dynamic> toAnalysisItemJson() => {
        'id': '$id$kAnalysisItemSuffix',
        if (!titleByHand) 'title': title,
        if (!summaryByHand) 'summary': summary,
        'moodLabel': moodLabel,
        'moodScore': moodScore,
        'dimensions': dimensions,
        if (!tagsByHand) 'tags': tags,
        'analysisModel': analysisModel,
        'analysisVersion': analysisVersion,
        'analysisSource': analysisSource,
        'analysisBasis': analysisBasis,
      };

  /// Writes the analysis fields of an analysis item's [json] (see
  /// [toAnalysisItemJson]) onto this entry. Summary / tags edited by hand
  /// stay. Returns nothing to stamp — the caller owns the clock.
  void takeAnalysisFrom(Map<String, dynamic> json) {
    if (!titleByHand && json.containsKey('title')) {
      title = json['title'] as String?;
    }
    if (!summaryByHand && json.containsKey('summary')) {
      summary = json['summary'] as String?;
    }
    if (!tagsByHand && json.containsKey('tags')) {
      tags = (json['tags'] as List<dynamic>?)?.cast<String>() ?? const [];
    }
    final dims = json['dimensions'];
    moodLabel = json['moodLabel'] as String?;
    moodScore = (json['moodScore'] as num?)?.toDouble();
    dimensions = dims == null
        ? null
        : (dims as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as num).toInt()));
    analysisModel = json['analysisModel'] as String?;
    analysisVersion = json['analysisVersion'] as int?;
    analysisSource = json['analysisSource'] as String?;
    analysisBasis = json['analysisBasis'] as String?;
  }

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
      title: json['title'] as String?,
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
      analysisChangedAt: json['analysisChangedAt'] == null
          ? null
          : DateTime.parse(json['analysisChangedAt'] as String),
      analysisSource: json['analysisSource'] as String?,
      analysisBasis: json['analysisBasis'] as String?,
      summaryByHand: json['summaryByHand'] as bool? ?? false,
      tagsByHand: json['tagsByHand'] as bool? ?? false,
      titleByHand: json['titleByHand'] as bool? ?? false,
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

/// Item-id suffix of an entry's analysis sync item.
const kAnalysisItemSuffix = ':analysis';

/// The keys of [JournalEntry.toJson] that belong to the analysis item —
/// summary and tags only while not edited by hand.
const kAnalysisKeys = <String>{
  'title',
  'summary',
  'moodLabel',
  'moodScore',
  'dimensions',
  'tags',
  'analysisModel',
  'analysisVersion',
  'analysisChangedAt',
  'analysisSource',
  'analysisBasis',
};

/// Result of an analysis pass — the recomputable interpretation of one entry.
class AnalysisResult {
  final String transcript;

  /// 2–5 words for what the day was. Empty from engines that don't make one.
  final String title;
  final String summary;
  final String moodLabel;
  final double moodScore;
  final Map<String, int> dimensions;
  final List<String> tags;

  AnalysisResult({
    required this.transcript,
    this.title = '',
    required this.summary,
    required this.moodLabel,
    required this.moodScore,
    required this.dimensions,
    required this.tags,
  });
}
