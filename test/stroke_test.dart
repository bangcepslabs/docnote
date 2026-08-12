import 'dart:ui';

import 'package:docnote/features/drawing/domain/stroke.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('좌표를 정규화하고 복원한다', () {
    const size = Size(200, 100);
    final point = normalizePoint(const Offset(50, 25), size, pressure: .6);
    expect(point.x, .25);
    expect(point.y, .25);
    expect(restorePoint(point, size), const Offset(50, 25));
  });

  test('Stroke를 직렬화하고 역직렬화한다', () {
    final original = Stroke(
        id: 's1',
        documentId: 'd1',
        pageId: 'page_1',
        tool: StrokeTool.highlighter,
        points: const [StrokePoint(.1, .2, .8)],
        color: const Color(0x80ff0000),
        width: 6,
        opacity: .35,
        order: 2,
        createdAt: DateTime.utc(2024));
    final restored = Stroke.fromJson(original.toJson());
    expect(restored.id, original.id);
    expect(restored.tool, StrokeTool.highlighter);
    expect(restored.points.single.x, .1);
    expect(restored.color, original.color);
  });

  test('펜 종류를 Stroke에 보존한다', () {
    final original = Stroke(
        id: 's2',
        documentId: 'd1',
        pageId: 'page_1',
        tool: StrokeTool.pen,
        penType: PenType.fountain,
        points: const [StrokePoint(.1, .2, .8)],
        color: const Color(0xff000000),
        width: 3.5,
        opacity: .92,
        order: 1,
        createdAt: DateTime.utc(2024));
    expect(Stroke.fromJson(original.toJson()).penType, PenType.fountain);
  });
}
