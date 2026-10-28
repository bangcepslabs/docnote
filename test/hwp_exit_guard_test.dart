import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docnote/features/hwp/presentation/hwp_exit_guard.dart';

void main() {
  testWidgets('save in flight cannot close twice', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    final completion = Completer<bool>();
    var saves = 0;
    await tester.pumpWidget(MaterialApp(
        navigatorKey: nav, home: const Scaffold(body: Text('library'))));
    nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => HwpExitGuard(
            dirty: true,
            saving: false,
            onSave: () {
              saves++;
              return completion.future;
            },
            child: const Scaffold(body: Text('editor')))));
    await tester.pumpAndSettle();
    nav.currentState!.maybePop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장 후 닫기'));
    await tester.pumpAndSettle();
    nav.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(find.text('editor'), findsOneWidget);
    expect(find.text('변경 내용을 저장할까요?'), findsNothing);
    completion.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('library'), findsOneWidget);
  });
  for (final brightness in Brightness.values) {
    for (final width in [320.0, 840.0]) {
      testWidgets('exit choices $width $brightness', (tester) async {
        tester.view.physicalSize = Size(width, width == 320 ? 640 : 420);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final nav = GlobalKey<NavigatorState>();
        var saves = 0;
        var succeed = false;
        await tester.pumpWidget(MaterialApp(
            navigatorKey: nav,
            theme: ThemeData(brightness: brightness),
            home: const Scaffold(body: Text('library'))));
        nav.currentState!.push(MaterialPageRoute<void>(
            builder: (_) => HwpExitGuard(
                dirty: true,
                saving: false,
                onSave: () async {
                  saves++;
                  return succeed;
                },
                child: const Scaffold(body: Text('editor')))));
        await tester.pumpAndSettle();
        nav.currentState!.maybePop();
        nav.currentState!.maybePop();
        await tester.pumpAndSettle();
        expect(find.text('변경 내용을 저장할까요?'), findsOneWidget);
        await tester.tap(find.text('계속 편집'));
        await tester.pumpAndSettle();
        expect(find.text('editor'), findsOneWidget);
        nav.currentState!.maybePop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('저장 후 닫기'));
        await tester.pumpAndSettle();
        expect(saves, 1);
        expect(find.text('editor'), findsOneWidget);
        succeed = true;
        nav.currentState!.maybePop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('저장 후 닫기'));
        await tester.pumpAndSettle();
        expect(saves, 2);
        expect(find.text('library'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('discard closes nested first route; clean closes without dialog',
      (tester) async {
    for (final dirty in [true, false]) {
      final nav = GlobalKey<NavigatorState>();
      var popped = false;
      await tester.pumpWidget(MaterialApp(
          home: Navigator(
              key: nav,
              observers: [_PopObserver(() => popped = true)],
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => HwpExitGuard(
                      dirty: dirty,
                      saving: false,
                      onSave: () async => throw StateError('must not save'),
                      child: const Scaffold(body: Text('editor')))))));
      await tester.pumpAndSettle();
      nav.currentState!.maybePop();
      await tester.pumpAndSettle();
      if (dirty) {
        await tester.tap(find.text('저장하지 않고 닫기'));
        await tester.pumpAndSettle();
      }
      expect(popped, isTrue);
      // A production workspace removes the empty nested Navigator on pop.
      await tester.pumpWidget(const SizedBox());
    }
  });
}

class _PopObserver extends NavigatorObserver {
  _PopObserver(this.onPop);
  final VoidCallback onPop;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => onPop();
}
