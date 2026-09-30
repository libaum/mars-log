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
}
