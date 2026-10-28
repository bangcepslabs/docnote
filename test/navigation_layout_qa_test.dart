import 'package:docnote/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final size in [
      const Size(320, 640),
      const Size(360, 640),
      const Size(390, 844),
      const Size(412, 915),
      const Size(430, 932),
      const Size(840, 420),
      const Size(1200, 800)
    ]) {
      testWidgets('main destinations fit $size $brightness with enlarged text',
          (tester) async {
        await tester.binding.setSurfaceSize(size);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(() {
          tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          tester.platformDispatcher.clearPlatformBrightnessTestValue();
        });
        await tester.pumpWidget(const ProviderScope(child: DocNoteApp()));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Home');
        for (final label in ['문서', '검색', '설정', '홈']) {
          await tester.tap(find.text(label).last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: label);
        }
        await tester.tap(find.text('새로 만들기').last);
        await tester.pumpAndSettle();
        expect(find.text('빠르게 시작하기'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'Create sheet');
      });
    }
  }
}
