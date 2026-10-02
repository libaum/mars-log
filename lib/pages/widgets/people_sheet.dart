import 'package:flutter/material.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/people_aliases.dart';
import 'package:mars_log/domain/stats.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// A person as a pill — same look as the tags.
class PersonChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  /// Fainter, for the "+ Person" pill.
  final bool faint;
  const PersonChip({super.key, required this.label, required this.onTap, this.faint = false});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: primary.withValues(alpha: faint ? 0.15 : 0.3)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TEXT_STYLE_STATUS.copyWith(color: faint ? COLOR_SECONDARY : primary),
        ),
      ),
    );
  }
}

/// "Person hinzufügen": suggestions as pills, most likely first (recent and
/// frequent — see suggestedPeople), a search over names and aliases, and
/// "Neue Person …" when nothing matches. Stays open, so several people can
/// be added one tap each.
Future<void> showAddPeopleSheet(BuildContext context, String entryId) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => Padding(
        padding: EdgeInsets.fromLTRB(32, 32, 32, MediaQuery.of(sheet).viewInsets.bottom + 32),
        child: _AddPeople(entryId: entryId),
      ),
    );

class _AddPeople extends StatefulWidget {
  final String entryId;
  const _AddPeople({required this.entryId});

  @override
  State<_AddPeople> createState() => _AddPeopleState();
}

class _AddPeopleState extends State<_AddPeople> {
  final _journal = getIt<JournalManager>();
  final _repo = getIt<JournalRepository>();
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _add(String name) async {
    await _journal.addPerson(widget.entryId, name);
    if (_search.text.isNotEmpty) _search.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<JournalEntry>>(
      valueListenable: _journal.entriesNotifier,
      builder: (context, entries, _) {
        final entry = _repo.byId(widget.entryId);
        if (entry == null) return const SizedBox.shrink();
        final aliases = _repo.aliases;
        final inEntry = {
          for (final p in effectivePeople(entry, aliases)) p.toLowerCase(),
        };
        final query = _search.text.trim();
        final q = query.toLowerCase();
        final suggestions = [
          for (final name in suggestedPeople(entries, aliases))
            if (!inEntry.contains(name.toLowerCase()) &&
                (q.isEmpty ||
                    name.toLowerCase().contains(q) ||
                    aliases.aliasesOf(name).any((a) => a.contains(q))))
              name,
        ];
        final exact = q.isNotEmpty &&
            (inEntry.contains(aliases.canonical(query).toLowerCase()) ||
                suggestions.any((s) => s.toLowerCase() == q));
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Person hinzufügen', style: TEXT_STYLE_SUMMARY),
            const SizedBox(height: 16),
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (suggestions.isNotEmpty) {
                  _add(suggestions.first);
                } else if (query.isNotEmpty) {
                  _add(query);
                }
              },
              textCapitalization: TextCapitalization.words,
              style: TEXT_STYLE_BODY,
              decoration: const InputDecoration(hintText: 'Suchen'),
            ),
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final name in suggestions)
                      PersonChip(label: name, onTap: () => _add(name)),
                    if (query.isNotEmpty && !exact)
                      PersonChip(
                        label: 'Neue Person „$query“',
                        faint: true,
                        onTap: () => _add(query),
                      ),
                  ],
                ),
              ),
            ),
            if (suggestions.isEmpty && query.isEmpty)
              const Text('Noch niemand bekannt — tippe einen Namen.', style: TEXT_STYLE_STATUS),
          ],
        );
      },
    );
  }
}
