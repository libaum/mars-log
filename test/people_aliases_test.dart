import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/people_aliases.dart';
import 'package:mars_log/domain/stats.dart';

JournalEntry _e(String id, List<String> people, double mood) => JournalEntry(
      id: id,
      createdAt: DateTime(2026, 9, 1),
      day: DateTime(2026, 9, 1),
      audioFileNames: const [],
      status: EntryStatus.ready,
      moodScore: mood,
      people: people,
    );

void main() {
  test('merging folds every name shown as one person into the other', () {
    var a = const PeopleAliases().merge('Wincent', 'Vincent');
    a = a.merge('Bruder', 'Wincent'); // picks the person, not the spelling
    expect(a.apply(['Bruder', 'wincent', 'Vincent', 'Lena']), ['Vincent', 'Lena']);
    expect(a.aliasesOf('Vincent'), ['bruder', 'wincent']);
  });

  test('renaming carries the merged names along, no chains', () {
    final a = const PeopleAliases()
        .merge('Wincent', 'Vincent')
        .rename('Vincent', 'Vincent (Bruder)');
    expect(a.canonical('wincent'), 'Vincent (Bruder)');
    expect(a.canonical('Vincent'), 'Vincent (Bruder)');
    expect(a.map.values.toSet(), {'Vincent (Bruder)'});
  });

  test('a name split off is its own person again', () {
    final a = const PeopleAliases().merge('Bruder', 'Vincent').split('Bruder');
    expect(a.canonical('Bruder'), 'Bruder');
  });

  test('survives the round trip', () {
    final a = const PeopleAliases().merge('Wincent', 'Vincent');
    final b = PeopleAliases.fromJson(a.toJson());
    expect(b.map, a.map);
    expect(b.changedAt, a.changedAt);
  });

  test('the stats count a merged person once per entry', () {
    final entries = [
      _e('1', ['Vincent'], 8),
      _e('2', ['Wincent'], 8),
      _e('3', ['Bruder', 'Vincent'], 8),
      _e('4', ['Lena'], 2),
    ];
    final raw = AllTimeStats(entries);
    expect(raw.personMoods, isEmpty, reason: 'split, nobody reaches 3');

    final aliases =
        const PeopleAliases().merge('Wincent', 'Vincent').merge('Bruder', 'Vincent');
    final merged = AllTimeStats(entries, aliases: aliases);
    expect(merged.personMoods.single.name, 'Vincent');
    expect(merged.personMoods.single.count, 3);
    expect(merged.allPeople.first, isA<MapEntry<String, int>>());
    expect(merged.allPeople.map((p) => p.key), ['Vincent', 'Lena']);
  });

  test('suggestions: recent beats frequent long ago', () {
    final now = DateTime(2026, 10, 2);
    JournalEntry at(String id, DateTime day, List<String> people) => JournalEntry(
          id: id,
          createdAt: day,
          day: day,
          audioFileNames: const [],
          people: people,
        );
    final entries = [
      for (var i = 0; i < 5; i++) at('old$i', DateTime(2026, 1, i + 1), ['Oma']),
      at('r1', DateTime(2026, 9, 30), ['Lena']),
      at('r2', DateTime(2026, 10, 1), ['Lena']),
      at('r3', DateTime(2026, 6, 1), ['Tom']),
    ];
    // Lena: 2 recent × 3 + 2 = 8; Oma: 5; Tom: 1.
    expect(suggestedPeople(entries, const PeopleAliases(), now: now), ['Lena', 'Oma', 'Tom']);
    expect(suggestedPeople(entries, const PeopleAliases(), now: now, recentWeight: 1),
        ['Oma', 'Lena', 'Tom']);
  });

  test('overrides: removed stays out, added comes in, both through the aliases', () {
    final aliases = const PeopleAliases().merge('Bruder', 'Vincent');
    final e = _e('1', ['Bruder', 'Lena'], 5)
      ..peopleRemoved = ['Lena']
      ..peopleAdded = ['Mia', 'Vincent'];
    expect(effectivePeople(e, aliases), ['Vincent', 'Mia']);
  });

  test('four names merged in one go, then split again: back where it started', () {
    final entries = [
      _e('1', ['Vincent'], 5),
      _e('2', ['Wincent'], 5),
      _e('3', ['Bruder', 'Lena'], 5),
      _e('4', ['Vince'], 5),
    ];
    const original = PeopleAliases();
    List<List<String>> shown(PeopleAliases a) =>
        [for (final e in entries) effectivePeople(e, a)];

    final merged = original.mergeAll(['Wincent', 'Bruder', 'Vince'], 'Vincent');
    expect(shown(merged), [
      ['Vincent'],
      ['Vincent'],
      ['Vincent', 'Lena'],
      ['Vincent'],
    ]);
    expect(merged.aliasesOf('Vincent'), ['bruder', 'vince', 'wincent']);

    var split = merged;
    for (final alias in merged.aliasesOf('Vincent')) {
      split = split.split(alias);
    }
    expect(shown(split), shown(original));
    expect(split.aliasesOf('Vincent'), isEmpty);
  });

  test('the extraction learns new spellings but never undoes a split', () {
    const known = ['Vincent'];
    final learned = const PeopleAliases().learn(
      const [PersonMention(person: 'Vincent', mention: 'Bruder', isNew: false)],
      known,
    );
    expect(learned.canonical('Bruder'), 'Vincent');

    final split = learned.split('bruder');
    final again = split.learn(
      const [PersonMention(person: 'Vincent', mention: 'Bruder', isNew: false)],
      known,
    );
    expect(identical(again, split), isTrue);
    expect(again.canonical('Bruder'), 'Bruder');

    // New people and names not on the list teach nothing.
    final none = const PeopleAliases().learn(const [
      PersonMention(person: 'Lena', mention: 'Lenchen', isNew: true),
      PersonMention(person: 'Nobody', mention: 'X', isNew: false),
    ], known);
    expect(none.map, isEmpty);
  });
}
