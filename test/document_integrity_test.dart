import 'dart:io';

import 'package:docnote/core/database/document_model.dart';
import 'package:docnote/core/storage/document_integrity_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('존재하는 원본과 첨부 파일은 정합성 오류로 보고하지 않는다', () async {
    final directory =
        await Directory.systemTemp.createTemp('docnote_integrity');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.pdf')
      ..writeAsStringSync('pdf');
    final attachment = File('${directory.path}/attachment.png')
      ..writeAsBytesSync([1, 2, 3]);
    final document = DocumentItem(
      id: 'doc-1',
      title: '테스트',
      type: DocumentType.pdf,
      sourcePath: source.path,
      attachments: [attachment.path],
    );

    final issues = await const DocumentIntegrityService().scan([document]);

    expect(issues, isEmpty);
  });

  test('누락된 원본과 첨부 파일을 각각 보고한다', () async {
    final document = DocumentItem(
      id: 'doc-2',
      title: '누락 테스트',
      type: DocumentType.pdf,
      sourcePath: '${Directory.systemTemp.path}/missing-source.pdf',
      attachments: ['${Directory.systemTemp.path}/missing-attachment.png'],
    );

    final issues = await const DocumentIntegrityService().scan([document]);

    expect(issues.map((issue) => issue.kind),
        containsAll(<String>['원본 파일', '첨부 파일']));
  });
}
