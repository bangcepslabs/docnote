import 'dart:convert';

import 'package:docnote/core/database/document_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('손상된 항목 하나가 있어도 유효한 로컬 문서 목록을 복원한다', () async {
    final newer = DocumentItem(
      id: 'newer',
      title: '최근 문서',
      type: DocumentType.pdf,
      modified: DateTime(2026, 2, 2),
    );
    final older = DocumentItem(
      id: 'older',
      title: '이전 문서',
      type: DocumentType.textNote,
      modified: DateTime(2026, 1, 1),
    );
    SharedPreferences.setMockInitialValues({
      DocumentRepository.key: jsonEncode([
        older.toJson(),
        {'id': 42, 'title': '손상된 항목', 'type': 'pdf'},
        newer.toJson(),
      ]),
    });

    final documents = await DocumentRepository().load();

    expect(documents.map((item) => item.id), ['newer', 'older']);
  });

  test('기존 별칭과 알 수 없는 유형은 목록을 깨지 않고 복원한다', () async {
    SharedPreferences.setMockInitialValues({
      DocumentRepository.key: jsonEncode([
        {'id': 'memo', 'title': '메모', 'type': 'memo'},
        {'id': 'unknown', 'title': '이전 문서', 'type': 'legacyScan'},
      ]),
    });

    final documents = await DocumentRepository().load();

    expect(documents, hasLength(2));
    expect(
        documents.every((item) => item.type == DocumentType.textNote), isTrue);
  });
}
