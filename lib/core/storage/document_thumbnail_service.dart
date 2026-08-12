import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:flutter_rhwp/flutter_rhwp.dart';

import '../database/document_model.dart';

/// Produces one persistent, content-based preview per imported document.
/// PDF previews are PNGs; rhwp exposes HWP/HWPX pages as SVG, which is kept
/// intact so list cards can show the exact first-page vector rendering.
class DocumentThumbnailService {
  const DocumentThumbnailService();
  static const currentVersion = 2;

  Future<String?> ensure(DocumentItem document) async {
    final currentPath = document.thumbnailPath;
    if (currentPath != null &&
        document.thumbnailVersion >= currentVersion &&
        await File(currentPath).exists()) {
      return currentPath;
    }
    final sourcePath = document.sourcePath;
    if (sourcePath == null || !await File(sourcePath).exists()) return null;

    return switch (document.type) {
      DocumentType.pdf => _renderPdf(document.id, sourcePath),
      DocumentType.hwp || DocumentType.hwpx => _renderHwp(document.id, sourcePath),
      _ => null,
    };
  }

  Future<Directory> _thumbnailDirectory(String documentId) async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/documents/$documentId/thumbnails');
    await directory.create(recursive: true);
    return directory;
  }

  Future<String?> _renderPdf(String documentId, String sourcePath) async {
    PdfDocument? pdf;
    PdfPage? page;
    try {
      pdf = await PdfDocument.openFile(sourcePath);
      if (pdf.pagesCount < 1) return null;
      page = await pdf.getPage(1, autoCloseAndroid: false);
      // Cards are small, but a high-density source keeps text and thin lines
      // legible on modern Android displays and after image cache scaling.
      final width = 720.0;
      final rendered = await page.render(
        width: width,
        height: width * page.height / page.width,
        format: PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      final bytes = rendered?.bytes;
      if (bytes == null || bytes.isEmpty) return null;
      return _writeBytes(documentId, 'page_1.png', bytes);
    } finally {
      await page?.close();
      await pdf?.close();
    }
  }

  Future<String?> _renderHwp(String documentId, String sourcePath) async {
    dynamic document;
    try {
      final file = File(sourcePath);
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      document = await Rhwp.open(
        bytes,
        fileName: file.uri.pathSegments.last,
      );
      final count = (await document.pageCount) as int;
      if (count < 1) return null;
      final svg = await document.renderPageSvg(0) as String;
      if (svg.trim().isEmpty) return null;
      final directory = await _thumbnailDirectory(documentId);
      final target = File('${directory.path}/page_1.svg');
      await target.writeAsString(svg, flush: true);
      return target.path;
    } finally {
      await document?.close();
    }
  }

  Future<String> _writeBytes(
    String documentId,
    String fileName,
    Uint8List bytes,
  ) async {
    final directory = await _thumbnailDirectory(documentId);
    final target = File('${directory.path}/$fileName');
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }
}
