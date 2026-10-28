import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docnote/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docnote/features/drawing/presentation/drawing_editor.dart';
import 'package:docnote/features/drawing/domain/drawing_shape.dart';
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

  testWidgets('넓은 화면은 기능을 유지한 NavigationRail을 사용한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ProviderScope(child: DocNoteApp()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text('문서'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('문서'), findsAtLeastNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home 라이브러리 정렬 메뉴는 선택값을 적용한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1280));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ProviderScope(child: DocNoteApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('최근 수정'));
    await tester.pumpAndSettle();
    expect(find.text('최근 열람'), findsOneWidget);
    expect(find.text('제목순'), findsOneWidget);
    await tester.tap(find.text('제목순'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('제목순'), findsOneWidget);
    expect(find.text('최근 수정'), findsNothing);
    expect(tester.takeException(), isNull);
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

  testWidgets('통합 필기 툴바는 모바일과 태블릿 폭에서 overflow 없이 표시한다', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final size in const [
      Size(320, 720),
      Size(360, 800),
      Size(800, 1280)
    ]) {
      await tester.binding.setSurfaceSize(size);
      for (final tool in const [
        StrokeTool.pen,
        StrokeTool.highlighter,
        StrokeTool.eraser,
        StrokeTool.lasso,
        StrokeTool.shapeLine,
        StrokeTool.text,
        StrokeTool.image,
      ]) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: _toolbarForTest(tool)),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull,
            reason: '${size.width}px에서 $tool 툴바가 예외 없이 표시되어야 합니다.');
      }
    }
  });

  testWidgets('선택한 펜의 빠른 옵션은 진입 직후 표시된다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: _toolbarForTest(StrokeTool.pen)),
    ));

    expect(find.byTooltip('펜 종류'), findsOneWidget);
    expect(find.bySemanticsLabel('색상 팔레트 열기'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('통합 툴바는 도구와 컨텍스트 옵션을 하나의 tray에 연결한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1280));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: _toolbarForTest(StrokeTool.pen)),
    ));

    final options = find.byKey(const ValueKey('active-options-pen'));
    final penTool = find.byTooltip('펜');
    final surface = find.byKey(const ValueKey('editor-toolbar-surface'));
    expect(options, findsOneWidget);
    expect(surface, findsOneWidget);
    expect(tester.getSize(surface).width, greaterThan(700),
        reason: '태블릿에서는 도구가 가운데 좁은 카드에 몰리지 않아야 합니다.');
    expect(
        tester.getRect(options).top, greaterThan(tester.getRect(penTool).top));
    expect(tester.getRect(options).left,
        greaterThanOrEqualTo(tester.getRect(surface).left));
    expect(tester.getRect(options).right,
        lessThanOrEqualTo(tester.getRect(surface).right));

    await tester.tap(penTool);
    await tester.pumpAndSettle();
    expect(tester.getSize(options).height, 0);

    await tester.tap(penTool);
    await tester.pumpAndSettle();
    expect(tester.getSize(options).height, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('펜 색상 프리셋은 빠른 적용과 재선택 편집 진입을 지원한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1280));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Color? selectedColor;
    var paletteRequests = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _toolbarForTest(
          StrokeTool.pen,
          onColorChanged: (value) => selectedColor = value,
          onPaletteRequested: () => paletteRequests++,
        ),
      ),
    ));

    final chips = find.byType(ColorChip);
    expect(chips, findsNWidgets(3));
    await tester.tap(chips.at(1));
    expect(selectedColor, const Color(0xff3f6f9f));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _toolbarForTest(
          StrokeTool.pen,
          color: const Color(0xff3f6f9f),
          onPaletteRequested: () => paletteRequests++,
        ),
      ),
    ));
    await tester.tap(find.byType(ColorChip).at(1));
    expect(paletteRequests, 1, reason: '현재 색상 슬롯을 다시 누르면 프리셋 편집으로 연결되어야 합니다.');
    expect(tester.takeException(), isNull);
  });

  testWidgets('펜 종류 팝오버에서 기존 렌더링 타입을 선택할 수 있다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    PenType? selectedType;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: _toolbarForTest(StrokeTool.pen,
              onPenTypeChanged: (value) => selectedType = value)),
    ));

    await tester.tap(find.byTooltip('펜 종류'));
    await tester.pumpAndSettle();

    expect(find.text('볼펜'), findsOneWidget);
    expect(find.text('만년필'), findsOneWidget);
    expect(find.text('연필'), findsOneWidget);
    expect(find.text('마커'), findsOneWidget);
    await tester.tap(find.text('연필'));
    await tester.pumpAndSettle();
    expect(selectedType, PenType.pencil);
    expect(tester.takeException(), isNull);
  });
}

void _noopStart(Offset _, double __, Size ___) {}
void _noopMove(Offset _, double __, Size ___) {}
void _noopEnd() {}

DrawingToolbar _toolbarForTest(StrokeTool tool,
        {ValueChanged<PenType>? onPenTypeChanged,
        ValueChanged<Color>? onColorChanged,
        VoidCallback? onPaletteRequested,
        Color color = Colors.black}) =>
    DrawingToolbar(
      selectedTool: tool,
      penType: PenType.ballpoint,
      width: 3,
      color: color,
      highlighterOpacity: .35,
      eraserMode: EraserMode.partial,
      lassoMode: LassoMode.freeform,
      lassoIncludeStrokes: true,
      lassoIncludeTexts: true,
      lassoIncludeImages: true,
      onToolChanged: (_) {},
      onPenTypeChanged: onPenTypeChanged ?? (_) {},
      onWidthChanged: (_) {},
      onColorChanged: onColorChanged ?? (_) {},
      onHighlighterOpacityChanged: (_) {},
      onEraserModeChanged: (_) {},
      onLassoModeChanged: (_) {},
      onLassoIncludeStrokesChanged: (_) {},
      onLassoIncludeTextsChanged: (_) {},
      onLassoIncludeImagesChanged: (_) {},
      onPaletteRequested: onPaletteRequested ?? () {},
      colorPresets: const [
        Colors.black,
        Color(0xff3f6f9f),
        Color(0xffc95656),
      ],
      shapeType: DrawingShapeType.line,
      onShapeTypeChanged: (_) {},
      hasSelection: false,
      hasShapeSelection: false,
      hasSingleImageSelection: false,
      onDeleteSelection: () {},
      onDuplicateSelection: () {},
      onShapeStyleRequested: () {},
      onCropRequested: () {},
      textBold: false,
      textItalic: false,
      textUnderline: false,
      textAlignment: 'left',
      onTextBoldChanged: (_) {},
      onTextItalicChanged: (_) {},
      onTextUnderlineChanged: (_) {},
      onTextAlignmentChanged: (_) {},
    );
