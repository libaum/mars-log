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
  final Map<String, String> map;
  final DateTime? changedAt;

  const PeopleAliases([this.map = const {}, this.changedAt]);

  static String _key(String name) => name.trim().toLowerCase();

  /// The name [name] is shown as.
  String canonical(String name) => map[_key(name)] ?? name.trim();

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
  PeopleAliases merge(String from, String into) {
    final source = canonical(from);
    final target = canonical(into);
    if (_key(source) == _key(target)) return this;
    final next = {
      for (final MapEntry(:key, :value) in map.entries)
        key: _key(value) == _key(source) ? target : value,
    };
    next[_key(from)] = target;
    next[_key(source)] = target;
    return PeopleAliases(next, DateTime.now());
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

  /// [alias] is its own person again.
  PeopleAliases split(String alias) =>
      PeopleAliases({...map}..remove(_key(alias)), DateTime.now());

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
