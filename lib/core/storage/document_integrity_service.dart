import 'dart:io';

import '../database/document_model.dart';

class DocumentIntegrityIssue {
  const DocumentIntegrityIssue(this.documentId, this.path, this.kind);

  final String documentId;
  final String path;
  final String kind;
}

/// Read-only consistency check for the local document store.
/// It never deletes or mutates user data.
class DocumentIntegrityService {
  const DocumentIntegrityService();

  Future<List<DocumentIntegrityIssue>> scan(
      Iterable<DocumentItem> documents) async {
    final issues = <DocumentIntegrityIssue>[];
    for (final document in documents) {
      final paths = <String, String>{
        if (document.sourcePath case final path?) path: '원본 파일',
        if (document.internalPath case final path?) path: '작업 파일',
        if (document.thumbnailPath case final path?) path: '썸네일',
        for (final path in document.attachments) path: '첨부 파일',
      };
      for (final entry in paths.entries) {
        if (entry.key.isEmpty || !await File(entry.key).exists()) {
          issues
              .add(DocumentIntegrityIssue(document.id, entry.key, entry.value));
        }
      }
    }
    return issues;
  }
}
