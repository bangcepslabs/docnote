import 'dart:developer' as developer;
import 'dart:io';

class PdfFileValidator {
  static Future<void> validate(File file, {String? documentId}) async {
    final exists = await file.exists();
    final length = exists ? await file.length() : 0;
    developer.log(
        'PDF validation path=${file.path} exists=$exists size=$length documentId=$documentId',
        name: 'docnote.pdf');
    if (!exists) {
      throw const FileSystemException('PDF 파일이 존재하지 않습니다.');
    }
    if (length == 0) {
      throw const FormatException('PDF 파일이 비어 있습니다.');
    }
    if (!file.path.toLowerCase().endsWith('.pdf')) {
      throw const FormatException('PDF 확장자가 아닙니다.');
    }
    final header = await file
        .openRead(0, 5)
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    if (String.fromCharCodes(header) != '%PDF-') {
      throw const FormatException('PDF 헤더가 올바르지 않습니다.');
    }
  }
}
