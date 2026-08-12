import 'dart:ui';

import 'package:docnote/features/pdf/domain/annotation_coordinate_transformer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('정규화 좌표를 캔버스와 PDF 좌표로 변환하고 복원한다', () {
    const transformer = AnnotationCoordinateTransformer(pageSize: Size(600, 800));
    expect(transformer.normalizedToCanvas(const Offset(.25, .5), const Size(300, 400)), const Offset(75, 200));
    expect(transformer.canvasToNormalized(const Offset(75, 200), const Size(300, 400)), const Offset(.25, .5));
    final pdf = transformer.normalizedToPdf(const Offset(.25, .5));
    expect(pdf, const Offset(150, 400));
    expect(transformer.pdfToNormalized(pdf), const Offset(.25, .5));
  });

  test('90도 회전 페이지 좌표를 처리한다', () {
    const transformer = AnnotationCoordinateTransformer(pageSize: Size(600, 800), rotation: 90);
    final normalized = transformer.pdfToNormalized(transformer.normalizedToPdf(const Offset(.2, .3)));
    expect(normalized.dx, closeTo(.2, .0001));
    expect(normalized.dy, closeTo(.3, .0001));
  });
}
