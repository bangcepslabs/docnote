import 'dart:ui';

import 'package:docnote/features/drawing/domain/drawing_shape.dart';
import 'package:docnote/features/drawing/domain/stroke.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DrawingShape shape({Color? fillColor, bool isDashed = false}) => DrawingShape(
        id: 'shape-1',
        documentId: 'document-1',
        pageId: 'page-1',
        type: DrawingShapeType.rectangle,
        startPoint: const StrokePoint(.1, .1, 1),
        endPoint: const StrokePoint(.5, .5, 1),
        color: const Color(0xff3f6f9f),
        strokeWidth: 3,
        fillColor: fillColor,
        isDashed: isDashed,
        order: 0,
        createdAt: DateTime.utc(2024),
      );

  test('도형 채우기와 점선 스타일을 저장하고 복원한다', () {
    final original = shape(
      fillColor: const Color(0xff4e8b68),
      isDashed: true,
    );
    final restored = DrawingShape.fromJson(original.toJson());

    expect(restored.fillColor, const Color(0xff4e8b68));
    expect(restored.isDashed, isTrue);
  });

  test('기존 outline 도형은 새 스타일 필드 없이도 호환된다', () {
    final json = shape().toJson()
      ..remove('fillColor')
      ..remove('isDashed');
    final restored = DrawingShape.fromJson(json);

    expect(restored.fillColor, isNull);
    expect(restored.isDashed, isFalse);
  });

  test('채우기 제거는 outline-only 상태로 되돌린다', () {
    final cleared =
        shape(fillColor: const Color(0xffc95656)).copyWith(clearFill: true);

    expect(cleared.fillColor, isNull);
  });
}
