/// Processing state of an entry.
///
/// [pending]: waiting to be (further) processed — no connection, a rate
/// limit, a server error. Retried by itself; never lost.
enum EntryStatus { analyzing, ready, failed, pending }

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

  /// Recordings of [audioFileNames] whose words aren't in [transcript] yet —
  /// a recording made offline, or added while the transcription failed.
  /// Kept until transcribed, so a recording is never lost to a dropped
  /// connection. Belongs to the device holding the files, like the files.
  List<String> untranscribed;

  EntryStatus status;
  String? transcript;

  /// The model that wrote [transcript]. Null: Whisper on the phone (before
  /// Gemini transcribed), or typed.
  String? transcriptionModel;

  /// A few words for what the day was — the entry's name in every list.
  /// Written by the analysis, or by hand ([titleByHand]).
  String? title;
  String? summary;
  String? moodLabel;
  double? moodScore; // 0..10
  Map<String, int>? dimensions; // 0..100 per kMoodDimensions
  List<String> tags;

  /// People the entry mentions, as the text names them ("Bruder", "Lena").
  /// Null: never extracted — tells "not yet extracted" apart from "nobody
  /// mentioned" (empty). Shown through PeopleAliases and the two override
  /// lists below — see effectivePeople.
  List<String>? people;

  /// Model and prompt version of the extraction that wrote [people].
  String? peopleModel;
  int? peopleVersion;

  /// Corrections by hand, which every later extraction leaves alone. They
  /// are the human's, so they travel with the entry item, not the analysis.
  ///
  /// [peopleAdded]: names added by hand. [peopleRemoved]: tombstones — the
  /// names (as extracted, and as shown) of people removed by hand; a later
  /// extraction that finds them again doesn't bring them back.
  List<String> peopleAdded;
  List<String> peopleRemoved;
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

  /// How the user rated themselves for this entry, 1..10 each — ground
  /// truth to calibrate the model's mood against. Null: skipped, never a
  /// default. Never part of any prompt.
  ///
  /// [selfValence]: "Wie geht's dir?" [selfArousal]: "Wie viel Energie hast
  /// du?" (erschöpft ↔ energiegeladen). [selfRatingTiming]: asked
  /// [kRatedBefore] or [kRatedAfter] the recording — kept per entry, so both
  /// can be compared later.
  int? selfValence;
  int? selfArousal;
  DateTime? selfRatedAt;
  String? selfRatingTiming;

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
    List<String>? untranscribed,
    DateTime? changedAt,
    this.status = EntryStatus.analyzing,
    this.transcript,
    this.title,
    this.summary,
    this.moodLabel,
    this.moodScore,
    this.dimensions,
    List<String>? tags,
    this.people,
    this.peopleModel,
    this.peopleVersion,
    List<String>? peopleAdded,
    List<String>? peopleRemoved,
    this.transcriptionModel,
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
    this.selfValence,
    this.selfArousal,
    this.selfRatedAt,
    this.selfRatingTiming,
    this.latitude,
    this.longitude,
    this.place,
  })  : tags = tags ?? const [],
        untranscribed = untranscribed ?? const [],
        peopleAdded = peopleAdded ?? const [],
        peopleRemoved = peopleRemoved ?? const [],
        // Entries written before sync existed get their creation time, which
        // is the oldest stamp they could honestly claim.
        changedAt = changedAt ?? createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'day': day.toIso8601String(),
        'changedAt': changedAt.toIso8601String(),
        'audioFileNames': audioFileNames,
        'untranscribed': untranscribed,
        'status': status.name,
        'transcript': transcript,
        'transcriptionModel': transcriptionModel,
        'title': title,
        'summary': summary,
        'moodLabel': moodLabel,
        'moodScore': moodScore,
        'dimensions': dimensions,
        'tags': tags,
        'people': people,
        'peopleModel': peopleModel,
        'peopleVersion': peopleVersion,
        'peopleAdded': peopleAdded,
        'peopleRemoved': peopleRemoved,
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
        'selfValence': selfValence,
        'selfArousal': selfArousal,
        'selfRatedAt': selfRatedAt?.toIso8601String(),
        'selfRatingTiming': selfRatingTiming,
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
        'people': people,
        'peopleModel': peopleModel,
        'peopleVersion': peopleVersion,
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
    // An item from a build without the field leaves ours alone.
    if (json.containsKey('people')) people = _people(json['people']);
    if (json.containsKey('peopleModel')) peopleModel = json['peopleModel'] as String?;
    if (json.containsKey('peopleVersion')) peopleVersion = json['peopleVersion'] as int?;
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
      untranscribed: _people(json['untranscribed']),
      status: EntryStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => EntryStatus.ready,
      ),
      transcript: json['transcript'] as String?,
      transcriptionModel: json['transcriptionModel'] as String?,
      title: json['title'] as String?,
      summary: json['summary'] as String?,
      moodLabel: json['moodLabel'] as String?,
      moodScore: (json['moodScore'] as num?)?.toDouble(),
      dimensions: dims == null
          ? null
          : (dims as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, (v as num).toInt())),
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? const [],
      people: _people(json['people']),
      peopleModel: json['peopleModel'] as String?,
      peopleVersion: json['peopleVersion'] as int?,
      peopleAdded: _people(json['peopleAdded']),
      peopleRemoved: _people(json['peopleRemoved']),
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
      selfValence: json['selfValence'] as int?,
      selfArousal: json['selfArousal'] as int?,
      selfRatedAt: json['selfRatedAt'] == null
          ? null
          : DateTime.parse(json['selfRatedAt'] as String),
      selfRatingTiming: json['selfRatingTiming'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      place: json['place'] as String?,
    );
  }
}

List<String>? _people(Object? json) =>
    (json as List<dynamic>?)?.map((p) => p.toString()).toList();

/// A self-rating: valence and arousal, 1..10 each.
typedef SelfRating = ({int valence, int arousal});

/// [JournalEntry.selfRatingTiming] values.
const kRatedBefore = 'before';
const kRatedAfter = 'after';

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
  'people',
  'peopleModel',
  'peopleVersion',
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

  /// Who produced it, for [JournalEntry.analysisModel] / analysisSource —
  /// set by the engine that answered.
  final String? model;
  final String? source;

  AnalysisResult({
    required this.transcript,
    this.title = '',
    required this.summary,
    required this.moodLabel,
    required this.moodScore,
    required this.dimensions,
    required this.tags,
    this.model,
    this.source,
  });
}

/// Cleans a model's `people` answer: trimmed, no empties, no duplicates
/// (case-insensitive, first spelling wins), never the narrator.
List<String> cleanPeople(Object? raw) {
  const self = {'ich', 'mich', 'mir', 'selbst', 'ich selbst'};
  final seen = <String>{};
  return [
    for (final p in (raw as List<dynamic>? ?? const []))
      if (p.toString().trim() case final name
          when name.isNotEmpty &&
              !self.contains(name.toLowerCase()) &&
              seen.add(name.toLowerCase()))
        name,
  ];
}

/// Who counts as a person — the rule of the people extraction.
const kPeoplePromptRule =
    'Nur Menschen: mit Namen (z. B. "Lena", "Herr Maier") oder als feste '
    'Bezugsperson ohne Namen (z. B. "Mama", "Oma", "mein Chef" → "Chef"). '
    'Nicht ich selbst (der Erzähler). Keine Gruppen ("Freunde", "Kollegen"). '
    'Keine Marken, Firmen, Produkte, Apps, Orte, Haustiere, fiktiven Figuren '
    'und keine Prominenten, über die nur gesprochen wird. Jede Person einmal.';
