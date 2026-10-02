import 'package:mars_log/domain/journal_entry.dart';

/// Bump when the people prompt changes: the backfill then extracts every
/// entry again, so old and new entries come from the same method.
/// 1: Gemini, its own call, with the known people in the prompt.
const kPeopleVersion = 1;

/// Sync item id of the people aliases. Same module as the entries; an older
/// build reads it as an entry, fails to parse it and skips it.
const kPeopleAliasesId = 'people:aliases';

/// Which names the analysis wrote down are the same person, and what that
/// person is called — "Bruder", "Wincent" → "Vincent".
///
/// Applied when reading, never written into the entries: a re-analysis
/// brings the raw names back, and the aliases simply apply again. The whole
/// map is one sync item, last-write-wins by [changedAt] — edited rarely and
/// by hand, so a merge per name isn't worth it.
class PeopleAliases {
  /// Lower-cased name as written by the analysis → the name shown. Values
  /// are always final (no chains), which [merge] and [rename] maintain.
  /// A name mapped to itself was split off by hand: it stays its own person,
  /// and [learn] doesn't fold it back in.
  final Map<String, String> map;
  final DateTime? changedAt;

  const PeopleAliases([this.map = const {}, this.changedAt]);

  static String _key(String name) => name.trim().toLowerCase();

  /// The name [name] is shown as.
  String canonical(String name) {
    final shown = map[_key(name)];
    // Split off ([split]): itself, spelled as the entry spells it.
    return shown == null || _key(shown) == _key(name) ? name.trim() : shown;
  }

  /// [names] as shown: mapped, and one person once.
  List<String> apply(Iterable<String> names) {
    final seen = <String>{};
    return [
      for (final n in names)
        if (canonical(n) case final c when seen.add(_key(c))) c,
    ];
  }

  /// Other names that are shown as [person] (excluding its own spelling).
  List<String> aliasesOf(String person) {
    final c = _key(canonical(person));
    return [
      for (final MapEntry(:key, :value) in map.entries)
        if (_key(value) == c && key != c) key,
    ]..sort();
  }

  /// [from] is the same person as [into]: everything shown as [from] is
  /// shown as [into] from now on.
  PeopleAliases merge(String from, String into) => mergeAll([from], into);

  /// Every one of [names] is the same person as [into] — one edit, one
  /// stamp.
  PeopleAliases mergeAll(Iterable<String> names, String into) {
    final target = canonical(into);
    final next = {...map};
    var changed = false;
    for (final from in names) {
      final source = canonical(from);
      if (_key(source) == _key(target)) continue;
      next.updateAll((_, value) => _key(value) == _key(source) ? target : value);
      next[_key(from)] = target;
      next[_key(source)] = target;
      changed = true;
    }
    return changed ? PeopleAliases(next, DateTime.now()) : this;
  }

  /// Shows [person] — and every name merged into it — as [name].
  PeopleAliases rename(String person, String name) {
    final to = name.trim();
    final old = canonical(person);
    if (to.isEmpty || to == old) return this;
    final next = {
      for (final MapEntry(:key, :value) in map.entries)
        key: _key(value) == _key(old) ? to : value,
    };
    next[_key(old)] = to;
    // The new name, if the analysis ever writes it, is this person too.
    next[_key(to)] = to;
    return PeopleAliases(next, DateTime.now());
  }

  /// [alias] is its own person again — and stays one: the extraction may
  /// not merge it back ([learn]).
  PeopleAliases split(String alias) =>
      PeopleAliases({...map, _key(alias): alias.trim()}, DateTime.now());

  /// Takes the extraction's word that a [PersonMention.mention] is a known
  /// person: from now on that spelling is shown as them. Only for spellings
  /// nobody decided on yet — a name split off or merged by hand stays as it
  /// is. Returns this when nothing is new.
  PeopleAliases learn(Iterable<PersonMention> mentions, Iterable<String> known) {
    final knownKeys = {for (final k in known) _key(k): k};
    final next = {...map};
    for (final m in mentions) {
      if (m.isNew || m.mention.isEmpty) continue;
      final person = knownKeys[_key(m.person)];
      if (person == null) continue; // "known", but not on the list: new after all
      final key = _key(m.mention);
      if (next.containsKey(key)) continue;
      if (_key(canonical(m.mention)) == _key(canonical(person))) continue;
      next[key] = canonical(person);
    }
    return next.length == map.length ? this : PeopleAliases(next, DateTime.now());
  }

  Map<String, dynamic> toJson() => {
        'id': kPeopleAliasesId,
        'map': map,
        'changedAt': changedAt?.toIso8601String(),
      };

  factory PeopleAliases.fromJson(Map<String, dynamic> json) => PeopleAliases(
        (json['map'] as Map<String, dynamic>? ?? const {})
            .map((k, v) => MapEntry(k, v as String)),
        json['changedAt'] == null ? null : DateTime.parse(json['changedAt'] as String),
      );
}

/// The people an entry is about, as shown: the extracted names minus those
/// removed by hand, plus those added by hand, through [aliases]. A
/// tombstone matches the extracted spelling and the name shown, so a person
/// removed by hand stays removed whatever spelling a later extraction picks.
List<String> effectivePeople(JournalEntry e, PeopleAliases aliases) {
  final removed = {for (final r in e.peopleRemoved) r.trim().toLowerCase()};
  bool gone(String name) =>
      removed.contains(name.trim().toLowerCase()) ||
      removed.contains(aliases.canonical(name).toLowerCase());
  return aliases.apply([
    ...?e.people?.where((p) => !gone(p)),
    ...e.peopleAdded,
  ]);
}

/// A person the extraction already knows of, for its prompt.
class KnownPerson {
  final String name;

  /// Other spellings shown as [name].
  final List<String> aliases;
  const KnownPerson(this.name, [this.aliases = const []]);
}

/// Everyone in [entries], most mentioned first, with their aliases.
List<KnownPerson> knownPeople(Iterable<JournalEntry> entries, PeopleAliases aliases) {
  final counts = <String, int>{};
  final shown = <String, String>{};
  for (final e in entries) {
    for (final name in effectivePeople(e, aliases)) {
      final key = name.toLowerCase();
      shown.putIfAbsent(key, () => name);
      counts[key] = (counts[key] ?? 0) + 1;
    }
  }
  final keys = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  return [for (final k in keys) KnownPerson(shown[k]!, aliases.aliasesOf(shown[k]!))];
}

/// One person found in an entry.
class PersonMention {
  /// A known person's name, or the name of a new one.
  final String person;

  /// How the text names them ("Bruder").
  final String mention;
  final bool isNew;
  const PersonMention({required this.person, required this.mention, required this.isNew});
}

/// What the people extraction found, and which model found it.
class PeopleResult {
  final List<PersonMention> mentions;
  final String model;
  const PeopleResult(this.mentions, {required this.model});

  /// The names to store on the entry: how the text names each person.
  List<String> get names => cleanPeople([
        for (final m in mentions) m.mention.isNotEmpty ? m.mention : m.person,
      ]);
}
