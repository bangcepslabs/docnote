import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdf/pdf.dart' as pw_pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../../core/storage/annotation_store.dart';
import '../../drawing/domain/stroke.dart';

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
      void Function(PdfExportProgress progress)? onProgress}) async {
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
        final composite = await _composite(
            rendered?.bytes, width.toInt(), height.toInt(), strokes);
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

  Future<Uint8List> _composite(
      Uint8List? pageBytes, int width, int height, List<Stroke> strokes) async {
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
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = ui.Paint()
        ..color = stroke.color.withValues(alpha: _opacityFor(stroke))
        ..strokeCap = ui.StrokeCap.round
        ..strokeJoin = ui.StrokeJoin.round
        ..style = ui.PaintingStyle.stroke;
      if (stroke.tool == StrokeTool.shapeLine ||
          stroke.tool == StrokeTool.shapeRectangle ||
          stroke.tool == StrokeTool.shapeEllipse ||
          stroke.tool == StrokeTool.shapeArrow) {
        final start = ui.Offset(
            stroke.points.first.x * width, stroke.points.first.y * height);
        final end = ui.Offset(
            stroke.points.last.x * width, stroke.points.last.y * height);
        paint.strokeWidth = stroke.width * width / 1000;
        final rect = ui.Rect.fromPoints(start, end);
        switch (stroke.tool) {
          case StrokeTool.shapeLine:
            canvas.drawLine(start, end, paint);
          case StrokeTool.shapeRectangle:
            canvas.drawRect(rect, paint);
          case StrokeTool.shapeEllipse:
            canvas.drawOval(rect, paint);
          case StrokeTool.shapeArrow:
            canvas.drawLine(start, end, paint);
            final direction = end - start;
            final angle = math.atan2(direction.dy, direction.dx);
            const wing = math.pi / 7;
            final length = 12.0 + paint.strokeWidth * 1.5;
            final left = end -
                ui.Offset(math.cos(angle - wing) * length,
                    math.sin(angle - wing) * length);
            final right = end -
                ui.Offset(math.cos(angle + wing) * length,
                    math.sin(angle + wing) * length);
            canvas.drawLine(end, left, paint);
            canvas.drawLine(end, right, paint);
          case StrokeTool.text:
          case StrokeTool.image:
          case StrokeTool.pen:
          case StrokeTool.highlighter:
          case StrokeTool.eraser:
          case StrokeTool.lasso:
            break;
        }
        continue;
      }
      for (var index = 0; index < stroke.points.length - 1; index++) {
        final start = stroke.points[index];
        final end = stroke.points[index + 1];
        paint.strokeWidth = _widthFor(stroke, start, width.toDouble(), end);
        canvas.drawLine(ui.Offset(start.x * width, start.y * height),
            ui.Offset(end.x * width, end.y * height), paint);
      }
      if (stroke.points.length == 1) {
        final point = stroke.points.first;
        paint.strokeWidth = _widthFor(stroke, point, width.toDouble(), point);
        canvas.drawCircle(ui.Offset(point.x * width, point.y * height),
            paint.strokeWidth / 2, paint);
      }
    }
    final image = await recorder.endRecording().toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  double _widthFor(
      Stroke stroke, StrokePoint start, double width, StrokePoint end) {
    double pointWidth(StrokePoint point) => stroke.tool == StrokeTool.pen
        ? stroke.width *
            _penWidthFactor(stroke.penType) *
            (.65 + point.pressure * .7) *
            width /
            1000
        : stroke.width * width / 1000;
    return (pointWidth(start) + pointWidth(end)) / 2;
  }

  double _penWidthFactor(PenType type) => switch (type) {
        PenType.ballpoint => 1,
        PenType.fountain => 1.15,
        PenType.pencil => .85,
        PenType.marker => 1.25,
      };

  double _opacityFor(Stroke stroke) => stroke.tool == StrokeTool.pen
      ? stroke.opacity *
          switch (stroke.penType) {
            PenType.pencil => .78,
            _ => 1,
          }
      : stroke.opacity;
}
