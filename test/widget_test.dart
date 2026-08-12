import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docnote/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docnote/features/drawing/presentation/drawing_editor.dart';
import 'package:docnote/features/drawing/domain/stroke.dart';
import 'package:docnote/features/pdf/presentation/pdf_editor.dart';

void main() {
  testWidgets('홈 화면과 하단 내비게이션을 표시한다', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: DocNoteApp()));
    await tester.pump();
    expect(find.text('DocNote'), findsAtLeastNWidgets(1));
    expect(find.text('홈'), findsOneWidget);
    expect(find.text('문서'), findsOneWidget);
    expect(find.text('설정'), findsOneWidget);
  });

  testWidgets('필기 캔버스를 표시한다', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: DrawingCanvas(
                strokes: [],
                activePoints: [],
                tool: StrokeTool.pen,
                color: Colors.black,
                width: 3,
                onStart: _noopStart,
                onMove: _noopMove,
                onEnd: _noopEnd))));
    expect(find.byType(DrawingCanvas), findsOneWidget);
    expect(find.byType(CustomPaint), findsAtLeastNWidgets(1));
  });

  testWidgets('PDF 공통 도구 모음은 한 번만 표시한다', (tester) async {
    final state = PdfEditingState()..mode = PdfInteractionMode.draw;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            bottomNavigationBar: PdfDrawingToolbar(
                state: state,
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
                onClear: () {}))));
    expect(find.byType(PdfDrawingToolbar), findsOneWidget);
  });
}

void _noopStart(Offset _, double __, Size ___) {}
void _noopMove(Offset _, double __, Size ___) {}
void _noopEnd() {}
