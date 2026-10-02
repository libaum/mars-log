import 'package:flutter/material.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// "Namen": every name with how often it came up. A tap opens the person;
/// a long-press (or "Auswählen") starts picking several, which are then
/// merged into one in a single step.
class AllPeopleSheet extends StatefulWidget {
  /// Most mentioned first.
  final List<MapEntry<String, int>> people;
  final void Function(String name) onPick;

  /// [names] (all picked, including [into]) become one person, [into].
  final void Function(List<String> names, String into) onMerge;

  const AllPeopleSheet({
    super.key,
    required this.people,
    required this.onPick,
    required this.onMerge,
  });

  @override
  State<AllPeopleSheet> createState() => _AllPeopleSheetState();
}

class _AllPeopleSheetState extends State<AllPeopleSheet> {
  /// Null: not picking.
  Set<String>? _picked;

  void _toggle(String name) => setState(() {
        final picked = _picked!;
        if (!picked.remove(name)) picked.add(name);
      });

  Future<void> _merge() async {
    // In list order: most mentioned first — the likely main name.
    final names = [
      for (final p in widget.people)
        if (_picked!.contains(p.key)) p.key,
    ];
    final into = await showDialog<String>(
      context: context,
      builder: (context) => _MainNameDialog(names: names),
    );
    if (into == null) return;
    widget.onMerge(names, into);
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final picked = _picked;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Namen', style: TEXT_STYLE_SUMMARY)),
                    if (picked == null)
                      TextButton(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero),
                        onPressed: () => setState(() => _picked = {}),
                        child: const Text('Auswählen', style: TEXT_STYLE_SETTING),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  picked == null
                      ? 'Tippen, um umzubenennen oder zu trennen. Gedrückt '
                          'halten, um mehrere zusammenzuführen.'
                      : 'Namen antippen, die dieselbe Person sind.',
                  style: TEXT_STYLE_STATUS,
                ),
                const SizedBox(height: 16),
                for (final p in widget.people)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => picked == null ? widget.onPick(p.key) : _toggle(p.key),
                    onLongPress: picked == null
                        ? () => setState(() => _picked = {p.key})
                        : null,
                    child: Opacity(
                      opacity: picked == null || picked.contains(p.key) ? 1 : 0.4,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            if (picked != null) ...[
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: primary.withValues(alpha: 0.5), width: 0.8),
                                  color: picked.contains(p.key) ? primary : Colors.transparent,
                                ),
                              ),
                              const SizedBox(width: 16),
                            ],
                            Expanded(child: Text(p.key, style: TEXT_STYLE_BODY)),
                            Text('${p.value}×', style: TEXT_STYLE_STATUS),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (picked != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => setState(() => _picked = null),
                    child: Text('Abbrechen',
                        style: TEXT_STYLE_SETTING.copyWith(color: COLOR_SECONDARY)),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: picked.length < 2 ? null : _merge,
                    child: Text(
                      'Zusammenführen (${picked.length})',
                      style: TEXT_STYLE_SETTING.copyWith(
                        color: picked.length < 2 ? COLOR_SECONDARY : primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Which of the picked names the person is called from now on — the most
/// mentioned one picked to begin with.
class _MainNameDialog extends StatefulWidget {
  final List<String> names;
  const _MainNameDialog({required this.names});

  @override
  State<_MainNameDialog> createState() => _MainNameDialogState();
}

class _MainNameDialogState extends State<_MainNameDialog> {
  late String _main = widget.names.first;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Hauptname', style: TEXT_STYLE_SETTING),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final name in widget.names)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _main = name),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  name == _main ? '● $name' : '○ $name',
                  style: TEXT_STYLE_BODY,
                ),
              ),
            ),
          const SizedBox(height: 8),
          const Text(
            'Die anderen werden zu Namen dieser Person. Einzeln trennen geht '
            'jederzeit wieder.',
            style: TEXT_STYLE_SETTINGS_DESCRIPTION,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _main),
          child: const Text('Zusammenführen'),
        ),
      ],
    );
  }
}
