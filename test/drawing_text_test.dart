import 'dart:ui';

import 'package:docnote/features/drawing/domain/drawing_text.dart';
import 'package:docnote/features/drawing/domain/stroke.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('텍스트 서식은 직렬화 후에도 보존된다', () {
    final original = DrawingText(
      id: 'text-1',
      documentId: 'doc-1',
      pageId: 'page_1',
      text: 'DocNote',
      position: StrokePoint(.2, .3, 1),
      fontSize: 22,
      color: Color(0xff3f6f9f),
      maxWidth: .6,
      order: 0,
      createdAt: DateTime(2024),
      bold: true,
      alignment: 'center',
    );

    final restored = DrawingText.fromJson(original.toJson());

    expect(restored.text, original.text);
    expect(restored.fontSize, original.fontSize);
    expect(restored.color, original.color);
    expect(restored.bold, isTrue);
    expect(restored.alignment, 'center');
  });

  test('기존 텍스트 데이터는 기본 서식으로 호환된다', () {
    const legacy = {
      'id': 'text-legacy',
      'documentId': 'doc-1',
      'pageId': 'page_1',
      'text': 'legacy',
      'position': {'x': .1, 'y': .2, 'pressure': 1.0},
      'fontSize': 18.0,
      'color': 0xff000000,
      'maxWidth': .7,
      'order': 0,
      'createdAt': '2024-01-01T00:00:00.000Z',
    };

    final restored = DrawingText.fromJson(legacy);

    expect(restored.bold, isFalse);
    expect(restored.alignment, 'left');
  });
}
