import 'dart:ui';

class AnnotationCoordinateTransformer {
  const AnnotationCoordinateTransformer(
      {required this.pageSize, this.rotation = 0});
  final Size pageSize;
  final int rotation;
  Offset normalizedToCanvas(Offset normalized, Size canvasSize) => Offset(
      normalized.dx * canvasSize.width, normalized.dy * canvasSize.height);
  Offset canvasToNormalized(Offset canvas, Size canvasSize) => Offset(
      (canvas.dx / canvasSize.width).clamp(0.0, 1.0),
      (canvas.dy / canvasSize.height).clamp(0.0, 1.0));
  Offset normalizedToPdf(Offset normalized) => switch (rotation % 360) {
        90 => Offset((1 - normalized.dy) * pageSize.width,
            normalized.dx * pageSize.height),
        180 => Offset((1 - normalized.dx) * pageSize.width,
            (1 - normalized.dy) * pageSize.height),
        270 => Offset(normalized.dy * pageSize.width,
            (1 - normalized.dx) * pageSize.height),
        _ => Offset(normalized.dx * pageSize.width,
            (1 - normalized.dy) * pageSize.height)
      };
  Offset pdfToNormalized(Offset pdf) {
    final p = switch (rotation % 360) {
      90 => Offset(pdf.dy / pageSize.height, 1 - pdf.dx / pageSize.width),
      180 => Offset(1 - pdf.dx / pageSize.width, 1 - pdf.dy / pageSize.height),
      270 => Offset(1 - pdf.dy / pageSize.height, pdf.dx / pageSize.width),
      _ => Offset(pdf.dx / pageSize.width, 1 - pdf.dy / pageSize.height)
    };
    return Offset(p.dx.clamp(0.0, 1.0), p.dy.clamp(0.0, 1.0));
  }

  double strokeWidthToPdf(double normalizedWidth) =>
      normalizedWidth * pageSize.shortestSide;
}
