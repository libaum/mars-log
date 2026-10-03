import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/pages/widgets/transcript_section.dart';

Widget _host(String text) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: TranscriptSection(transcript: text))),
    );

int _maxLines(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).maxLines ?? 0;

void main() {
  testWidgets('a long transcript starts folded, a tap unfolds and folds it', (tester) async {
    final long = List.filled(200, 'Heute war ein langer Tag.').join(' ');
    await tester.pumpWidget(_host(long));
    expect(_maxLines(tester, long), 8);

    await tester.tap(find.text('TRANSKRIPT'));
    await tester.pumpAndSettle();
    expect(_maxLines(tester, long), 0);

    await tester.tap(find.text('TRANSKRIPT'));
    await tester.pumpAndSettle();
    expect(_maxLines(tester, long), 8);
  });

  testWidgets('a short transcript is just shown', (tester) async {
    await tester.pumpWidget(_host('Kurz.'));
    expect(_maxLines(tester, 'Kurz.'), 0);
  });
}
