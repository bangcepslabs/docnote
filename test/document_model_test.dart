import 'package:flutter_test/flutter_test.dart';
import 'package:docnote/core/database/document_model.dart';

void main() {
  test('문서 메타데이터와 휴지통 상태를 직렬화한다', () {
    final created = DateTime(2026, 1, 2);
    final document = DocumentItem(
      id: 'doc-1',
      title: '회의 노트',
      type: DocumentType.textNote,
      attachments: ['/documents/doc-1/attachments/image.png'],
      folderId: 'work',
      created: created,
      modified: created,
    )..trashed = true;

    final restored = DocumentItem.fromJson(document.toJson());

    expect(restored.id, 'doc-1');
    expect(restored.title, '회의 노트');
    expect(restored.attachments,
        contains('/documents/doc-1/attachments/image.png'));
    expect(restored.folderId, 'work');
    expect(restored.trashed, isTrue);
    expect(restored.created, created);
  });

  test('첨부 파일이 있으면 빈 문서로 판단하지 않는다', () {
    final document = DocumentItem(
      id: 'doc-2',
      title: '',
      type: DocumentType.textNote,
      attachments: ['image.png'],
    );

    expect(document.isEmpty, isFalse);
  });

  test('기존 문서의 null 또는 숫자형 플래그를 안전하게 읽는다', () {
    final document = DocumentItem.fromJson({
      'id': 'legacy',
      'title': '기존 문서',
      'type': 'textNote',
      'favorite': null,
      'trashed': 0,
    });

    expect(document.favorite, isFalse);
    expect(document.trashed, isFalse);
  });
}
