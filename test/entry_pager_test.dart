import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/pages/widgets/entry_pager.dart';

void main() {
  late PageController pages;

  Future<void> pump(WidgetTester tester) async {
    pages = PageController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EntryPager(
          controller: pages,
          itemCount: 3,
          onPageChanged: (_) {},
          pageKey: (i) => i,
          itemBuilder: (context, i, list) => ListView(
            controller: list,
            children: [
              for (var row = 0; row < 60; row++)
                SizedBox(height: 50, child: Text('Seite $i, Zeile $row')),
            ],
          ),
        ),
      ),
    ));
  }

  testWidgets('a plain swipe still turns the page', (tester) async {
    await pump(tester);
    await tester.fling(find.byType(EntryPager), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(pages.page, 1);
  });

  testWidgets('a vertical drag right after a swipe scrolls, without sideways wobble',
      (tester) async {
    await pump(tester);
    await tester.fling(find.byType(EntryPager), const Offset(-300, 0), 1000);
    // The snap is under way, not done.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(pages.page, isNot(1.0));

    final gesture = await tester.startGesture(tester.getCenter(find.byType(EntryPager)));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
      expect(pages.page, 1.0, reason: 'landed on the page at once and stays there');
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(pages.page, 1.0);
    expect(tester.widget<Text>(find.textContaining('Seite 1, Zeile').first).data,
        isNot('Seite 1, Zeile 0'),
        reason: 'the touch scrolled the new page');
    expect(find.text('Seite 0, Zeile 0'), findsNothing);
  });

  testWidgets('a second swipe during the snap goes on to the next page', (tester) async {
    await pump(tester);
    await tester.fling(find.byType(EntryPager), const Offset(-300, 0), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.fling(find.byType(EntryPager), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(pages.page, 2);
  });

  testWidgets('a diagonal drag scrolls, the page stays put', (tester) async {
    await pump(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.byType(EntryPager)));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(-12, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(pages.page, 0);
    expect(find.text('Seite 0, Zeile 0'), findsNothing);
  });
}
