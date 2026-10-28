import 'dart:ui';

import '../../drawing/domain/stroke.dart';
import '../../drawing/presentation/drawing_editor.dart';

/// Use the editor's committed renderer at its logical page size, then scale
/// the complete ink layer to the export raster. Never resample stored points.
void paintPdfAnnotations(Canvas canvas, Size outputSize, double referenceWidth,
    List<Stroke> strokes) {
  if (!referenceWidth.isFinite || referenceWidth <= 0) {
    throw ArgumentError.value(referenceWidth, 'referenceWidth');
  }
  final scale = outputSize.width / referenceWidth;
  final logicalSize = Size(referenceWidth, outputSize.height / scale);
  canvas.save();
  canvas.scale(scale);
  // Clear-blend legacy eraser strokes must not erase the PDF background.
  final isolateInk = strokes.any((stroke) => stroke.tool == StrokeTool.eraser);
  if (isolateInk) canvas.saveLayer(Offset.zero & logicalSize, Paint());
  try {
    StrokePainter(strokes, const [], logicalSize, StrokeTool.pen,
            const Color(0xff000000), 1)
        .paintCommitted(canvas);
  } finally {
    if (isolateInk) canvas.restore();
    canvas.restore();
  }
}
