import 'dart:io';
import 'package:docnote/features/pdf/data/pdf_file_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PDF 헤더와 파일 크기를 검증한다', () async {
    final directory = await Directory.systemTemp.createTemp('docnote_pdf_test');
    final file = File('${directory.path}/한글 파일.pdf');
    await file.writeAsBytes('%PDF-1.7\n'.codeUnits);
    await PdfFileValidator.validate(file, documentId: 'test');
    await directory.delete(recursive: true);
  });

  test('0바이트 PDF를 거부한다', () async {
    final directory = await Directory.systemTemp.createTemp('docnote_pdf_empty');
    final file = File('${directory.path}/empty.pdf');
    await file.writeAsBytes([]);
    expect(() => PdfFileValidator.validate(file), throwsA(isA<FormatException>()));
    await directory.delete(recursive: true);
  });
}
