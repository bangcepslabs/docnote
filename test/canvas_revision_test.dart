import 'package:docnote/features/drawing/domain/stroke.dart';
import 'package:docnote/features/drawing/presentation/drawing_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mutable PDF-style input repaints active and committed layers',
      (tester) async {
    final strokes = <Stroke>[];
    final active = <StrokePoint>[];
    var staticPaints = 0;
    var activePaints = 0;
    Future<void> render(int revision, int staticRevision) async {
      await tester.pumpWidget(MaterialApp(
          home: SizedBox(
        width: 300,
        height: 400,
        child: DrawingCanvas(
          strokes: strokes,
          activePoints: active,
          tool: StrokeTool.pen,
          color: Colors.black,
          width: 3,
          revision: revision,
          staticRevision: staticRevision,
          onStart: (_, __, ___) {},
          onMove: (_, __, ___) {},
          onEnd: () {},
          onStaticPaint: () => staticPaints++,
          onPaint: () => activePaints++,
        ),
      )));
    }

    await render(1, 1);
    final initialStatic = staticPaints;
    final initialActive = activePaints;
    active.addAll([const StrokePoint(.1, .1, 1), const StrokePoint(.8, .8, 1)]);
    await render(2, 1);
    expect(activePaints, greaterThan(initialActive));
    expect(staticPaints, greaterThanOrEqualTo(initialStatic));
    final beforeCommit = staticPaints;
    strokes.add(Stroke(
        id: 'qa',
        documentId: 'qa',
        pageId: 'page_1',
        tool: StrokeTool.pen,
        points: List.of(active),
        color: Colors.black,
        width: 3,
        opacity: 1,
        order: 0,
        createdAt: DateTime.utc(2026)));
    active.clear();
    await render(3, 2);
    expect(staticPaints, greaterThan(beforeCommit));
    final committedPaints = staticPaints;
    strokes.clear();
    await render(4, 3);
    expect(staticPaints, greaterThan(committedPaints));
    expect(tester.takeException(), isNull);
  });
}
