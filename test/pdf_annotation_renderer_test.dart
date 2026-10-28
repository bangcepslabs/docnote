import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:docnote/features/drawing/domain/stroke.dart';
import 'package:docnote/features/drawing/presentation/drawing_editor.dart';
import 'package:docnote/features/pdf/data/pdf_annotation_renderer.dart';

Future<Uint8List> render(List<Stroke> strokes, {required bool export}) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  if (export) {
    paintPdfAnnotations(canvas, const Size(600, 800), 300, strokes);
  } else {
    canvas.scale(2);
    StrokePainter(strokes, const [], const Size(300, 400), StrokeTool.pen,
            const Color(0xff000000), 1)
        .paintCommitted(canvas);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(600, 800);
  try {
    return (await image.toByteData())!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final tool in [
    StrokeTool.pen,
    StrokeTool.highlighter,
    StrokeTool.shapeArrow,
    StrokeTool.shapeEllipse,
    StrokeTool.shapeTriangle
  ]) {
    for (final pen in PenType.values) {
      test('export matches editor: ${tool.name}/${pen.name}', () async {
        final stroke = Stroke(
          id: 'qa',
          documentId: 'qa',
          pageId: 'page_1',
          tool: tool,
          penType: pen,
          color: const Color(0xff3276b4),
          width: 6,
          opacity: tool == StrokeTool.highlighter ? .35 : 1,
          order: 0,
          createdAt: DateTime(2026),
          points: const [
            StrokePoint(.1, .2, .1),
            StrokePoint(.2, .4, .8),
            StrokePoint(.4, .2, 1),
            StrokePoint(.6, .5, .3),
            StrokePoint(.8, .3, .6)
          ],
        );
        final expected = await render([stroke], export: false);
        final actual = await render([stroke], export: true);
        expect(actual, orderedEquals(expected));
        expect(actual.any((byte) => byte != 0), isTrue);
      });
    }
  }
}
