import 'package:docnote/core/widgets/destination_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(int index, {bool reduceMotion = false}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: DestinationTransition(
            selectedIndex: index,
            child: IndexedStack(index: index, children: const [
              Scaffold(body: TextField()),
              Scaffold(body: Text('Library')),
            ]),
          ),
        ),
      );

  double opacity(WidgetTester tester) => tester
      .widget<FadeTransition>(find.descendant(
        of: find.byType(DestinationTransition),
        matching: find.byType(FadeTransition),
      ))
      .opacity
      .value;

  testWidgets('rapid destination changes retain input and finish cleanly',
      (tester) async {
    await tester.pumpWidget(host(0));
    expect(opacity(tester), 1);
    await tester.enterText(find.byType(TextField), '유지할 검색어');
    final fieldState = tester.state(find.byType(TextField));
    await tester.pumpWidget(host(1));
    expect(opacity(tester), lessThan(1));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(host(0));
    await tester.pumpAndSettle();
    expect(find.text('유지할 검색어'), findsOneWidget);
    expect(tester.state(find.byType(TextField)), same(fieldState));
    expect(opacity(tester), 1);
    // Re-selecting the current destination must not restart the fade.
    await tester.pumpWidget(host(0));
    expect(opacity(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion skips transitions and stops an active fade',
      (tester) async {
    await tester.pumpWidget(host(0));
    await tester.pumpWidget(host(1));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(host(1, reduceMotion: true));
    expect(opacity(tester), 1);
    await tester.pumpWidget(host(0, reduceMotion: true));
    expect(opacity(tester), 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
