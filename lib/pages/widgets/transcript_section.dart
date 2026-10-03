import 'package:flutter/material.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// The TRANSKRIPT label and the text. A long transcript starts folded to
/// its first [collapsedLines]; a tap on the label or the text unfolds it,
/// another folds it again. A short one is just shown.
class TranscriptSection extends StatefulWidget {
  final String transcript;
  final int collapsedLines;
  const TranscriptSection({super.key, required this.transcript, this.collapsedLines = 8});

  @override
  State<TranscriptSection> createState() => _TranscriptSectionState();
}

class _TranscriptSectionState extends State<TranscriptSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final style = DefaultTextStyle.of(context).style.merge(TEXT_STYLE_BODY);
      final painter = TextPainter(
        text: TextSpan(text: widget.transcript, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: widget.collapsedLines,
      )..layout(maxWidth: constraints.maxWidth);
      final foldable = painter.didExceedMaxLines;
      painter.dispose();

      final folded = foldable && !_expanded;
      final section = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('TRANSKRIPT', style: TEXT_STYLE_LABEL),
          const SizedBox(height: 10),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: Text(
              widget.transcript,
              style: TEXT_STYLE_BODY,
              maxLines: folded ? widget.collapsedLines : null,
              overflow: folded ? TextOverflow.ellipsis : null,
            ),
          ),
        ],
      );
      if (!foldable) return section;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = !_expanded),
        child: section,
      );
    });
  }
}
