import 'package:flutter/material.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// Two rows of 1–10: how you are, how much energy you have. Closes by
/// itself once both are picked — two taps. Returns null when skipped
/// (stored as null, never as a default).
Future<SelfRating?> showSelfRatingSheet(BuildContext context, {SelfRating? initial}) =>
    showModalBottomSheet<SelfRating>(
      context: context,
      builder: (_) => _SelfRating(initial: initial),
    );

class _SelfRating extends StatefulWidget {
  final SelfRating? initial;
  const _SelfRating({this.initial});

  @override
  State<_SelfRating> createState() => _SelfRatingState();
}

class _SelfRatingState extends State<_SelfRating> {
  late int? _valence = widget.initial?.valence;
  late int? _arousal = widget.initial?.arousal;
  bool _closing = false;

  void _pick({int? valence, int? arousal}) {
    setState(() {
      _valence = valence ?? _valence;
      _arousal = arousal ?? _arousal;
    });
    final v = _valence, a = _arousal;
    if (v == null || a == null || _closing) return;
    // Long enough to see the second pick land.
    _closing = true;
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (mounted) Navigator.pop(context, (valence: v, arousal: a));
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row("Wie geht's dir?", 'schlecht', 'gut', _valence, (n) => _pick(valence: n)),
            const SizedBox(height: 28),
            _row('Wie viel Energie hast du?', 'erschöpft', 'energiegeladen', _arousal,
                (n) => _pick(arousal: n)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Überspringen',
                    style: TEXT_STYLE_SETTING.copyWith(color: COLOR_SECONDARY)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String question, String low, String high, int? value, ValueChanged<int> onPick) {
    final primary = Theme.of(context).colorScheme.primary;
    final background = Theme.of(context).scaffoldBackgroundColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(question, style: TEXT_STYLE_SUMMARY),
        const SizedBox(height: 12),
        Row(
          children: [
            for (var n = 1; n <= 10; n++)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onPick(n),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Center(
                      child: Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: value == n ? primary : Colors.transparent,
                        ),
                        child: Text(
                          '$n',
                          style: TEXT_STYLE_STATUS.copyWith(
                            color: value == n ? background : primary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(low, style: TEXT_STYLE_SETTINGS_DESCRIPTION),
            const Spacer(),
            Text(high, style: TEXT_STYLE_SETTINGS_DESCRIPTION),
          ],
        ),
      ],
    );
  }
}
