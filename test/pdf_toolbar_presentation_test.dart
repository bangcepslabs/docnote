import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docnote/features/pdf/presentation/pdf_editor.dart';

void main() {
  for (final width in [320.0, 412.0, 840.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('PDF toolbar $width $brightness', (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var cleared = false;
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
              body: Align(
            alignment: Alignment.topCenter,
            child: PdfDrawingToolbar(
              state: PdfEditingState(),
              onView: () {},
              onPenTypeChanged: (_) {},
              onPenWidthChanged: (_) {},
              onPresetChanged: (_) {},
              onShapeChanged: (_) {},
              onToolChanged: (_) {},
              onColorChanged: (_) {},
              onWidthChanged: (_) {},
              onOpacityChanged: (_) {},
              onUndo: () {},
              onRedo: () {},
              onClear: () => cleared = true,
            ),
          )),
        ));
        expect(tester.getSize(find.byType(PdfDrawingToolbar)).height, 52);
        await tester.ensureVisible(find.byTooltip('페이지 작업'));
        await tester.tap(find.byTooltip('페이지 작업'));
        await tester.pumpAndSettle();
        expect(find.text('텍스트 도구'), findsNothing);
        expect(find.text('이미지'), findsNothing);
        await tester.tap(find.text('현재 페이지 필기 지우기'));
        await tester.pumpAndSettle();
        expect(cleared, isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
