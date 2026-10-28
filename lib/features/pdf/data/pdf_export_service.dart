import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdf/pdf.dart' as pw_pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../../core/storage/annotation_store.dart';
import '../../drawing/domain/stroke.dart';
import 'pdf_annotation_renderer.dart';

class PdfExportProgress {
  const PdfExportProgress(this.current, this.total, this.message);
  final int current;
  final int total;
  final String message;
}

class PdfExportService {
  PdfExportService(this.annotationStore);
  final AnnotationStore annotationStore;

  Future<File> export(
      {required String sourcePath,
      required String documentId,
      required String title,
      required double annotationReferenceWidth,
      void Function(PdfExportProgress progress)? onProgress}) async {
    if (!annotationReferenceWidth.isFinite || annotationReferenceWidth <= 0) {
      throw ArgumentError.value(
          annotationReferenceWidth, 'annotationReferenceWidth');
    }
    final source = await pdfx.PdfDocument.openFile(sourcePath);
    final exports = Directory('${File(sourcePath).parent.parent.path}/exports');
    await exports.create(recursive: true);
    final safeTitle = title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    final output = File('${exports.path}/${safeTitle}_annotated_$stamp.pdf');
    final temporary = File('${output.path}.tmp');
    final result = pw.Document();
    try {
      for (var number = 1; number <= source.pagesCount; number++) {
        onProgress?.call(PdfExportProgress(number, source.pagesCount,
            '페이지 $number/${source.pagesCount} 처리 중'));
        // The export loop opens several pages from the same document. Keep the
        // Android document handle alive until the whole export is complete.
        final page = await source.getPage(number, autoCloseAndroid: false);
        final width = 1600.0;
        final height = width * page.height / page.width;
        final rendered = await page.render(
            width: width,
            height: height,
            format: pdfx.PdfPageImageFormat.png,
            backgroundColor: '#FFFFFF');
        final strokes = await annotationStore.load(documentId, 'page_$number');
        final composite = await _composite(rendered?.bytes, width.toInt(),
            height.toInt(), strokes, annotationReferenceWidth);
        result.addPage(pw.Page(
            pageFormat: pw_pdf.PdfPageFormat(page.width, page.height),
            margin: pw.EdgeInsets.zero,
            build: (_) =>
                pw.Image(pw.MemoryImage(composite), fit: pw.BoxFit.fill)));
        await page.close();
      }
      onProgress?.call(
          PdfExportProgress(source.pagesCount, source.pagesCount, '파일 저장 중'));
      await temporary.writeAsBytes(await result.save(), flush: true);
      if (await output.exists()) await output.delete();
      await temporary.rename(output.path);
      return output;
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    } finally {
      await source.close();
    }
  }

  Future<Uint8List> _composite(Uint8List? pageBytes, int width, int height,
      List<Stroke> strokes, double referenceWidth) async {
    if (pageBytes == null) throw StateError('PDF 페이지 렌더링 결과가 없습니다.');
    final codec = await ui.instantiateImageCodec(pageBytes);
    final pageImage = (await codec.getNextFrame()).image;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
        pageImage,
        ui.Rect.fromLTWH(
            0, 0, pageImage.width.toDouble(), pageImage.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint());
    paintPdfAnnotations(canvas, ui.Size(width.toDouble(), height.toDouble()),
        referenceWidth, strokes);
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
      pageImage.dispose();
      codec.dispose();
    }
  }
}
