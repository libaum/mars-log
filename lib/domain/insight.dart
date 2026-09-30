/// Item-id prefix of the evaluations that look at many entries at once. They
/// sync in the journal's module next to the entries; an older build reads
/// one as an entry, fails to parse it and skips it.
const kInsightPrefix = 'insight:';

/// The one evaluation over the whole journal ("Muster über alles"), made on
/// the laptop by the hub.
const kOverallInsightId = '${kInsightPrefix}all';

/// One headed part of an [Insight].
class InsightSection {
  final String title;
  final String text;
  const InsightSection(this.title, this.text);

  Map<String, dynamic> toJson() => {'title': title, 'text': text};

  factory InsightSection.fromJson(Map<String, dynamic> json) =>
      InsightSection(json['title'] as String? ?? '', json['text'] as String? ?? '');
}

/// A written evaluation over many entries — too big for the phone's model,
/// so it is made on the laptop (Claude Code, run by the hub) and synced.
/// Recomputable like every analysis: a new one simply replaces the old.
class Insight {
  final String id;
  final List<InsightSection> sections;

  /// Who wrote it, e.g. `claude-code`.
  final String model;

  /// When it was made — also its last-write-wins clock.
  final DateTime createdAt;

  /// How many entries it was made from, and the days they span.
  final int entryCount;
  final DateTime? firstDay;
  final DateTime? lastDay;

  const Insight({
    required this.id,
    required this.sections,
    required this.model,
    required this.createdAt,
    required this.entryCount,
    this.firstDay,
    this.lastDay,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'sections': sections.map((s) => s.toJson()).toList(),
        'model': model,
        'createdAt': createdAt.toIso8601String(),
        'entryCount': entryCount,
        'firstDay': firstDay?.toIso8601String(),
        'lastDay': lastDay?.toIso8601String(),
      };

  factory Insight.fromJson(Map<String, dynamic> json) => Insight(
        id: json['id'] as String,
        sections: [
          for (final s in json['sections'] as List<dynamic>? ?? const [])
            InsightSection.fromJson((s as Map).cast<String, dynamic>()),
        ],
        model: json['model'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        entryCount: json['entryCount'] as int? ?? 0,
        firstDay: json['firstDay'] == null ? null : DateTime.parse(json['firstDay'] as String),
        lastDay: json['lastDay'] == null ? null : DateTime.parse(json['lastDay'] as String),
      );
}
