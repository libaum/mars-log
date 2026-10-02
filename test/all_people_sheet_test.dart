import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mars_log/pages/widgets/all_people_sheet.dart';

void main() {
  testWidgets('four names merged in one go, the most mentioned as main name', (tester) async {
    List<String>? merged;
    String? into;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AllPeopleSheet(
          people: const [
            MapEntry('Vincent', 9),
            MapEntry('Lena', 5),
            MapEntry('Wincent', 2),
            MapEntry('Bruder', 2),
            MapEntry('Vince', 1),
          ],
          onPick: (_) => fail('a tap while picking must not open the person'),
          onMerge: (names, main) {
            merged = names;
            into = main;
          },
        ),
      ),
    ));

    await tester.longPress(find.text('Wincent'));
    await tester.pump();
    for (final name in ['Vincent', 'Bruder', 'Vince']) {
      await tester.tap(find.text(name));
      await tester.pump();
    }
    await tester.tap(find.text('Zusammenführen (4)'));
    await tester.pumpAndSettle();
    expect(find.text('● Vincent'), findsOneWidget, reason: 'most mentioned picked first');
    await tester.tap(find.text('Zusammenführen').last);
    await tester.pumpAndSettle();

    expect(merged, ['Vincent', 'Wincent', 'Bruder', 'Vince']);
    expect(into, 'Vincent');
  });
}
