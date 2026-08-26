import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../features/drawing/domain/stroke.dart';
import '../../features/drawing/domain/drawing_shape.dart';
import '../../features/drawing/domain/drawing_text.dart';
import '../../features/drawing/domain/drawing_image.dart';

class AnnotationStore {
  Future<Directory> _documentDirectory(String documentId) async {
    final root = await getApplicationDocumentsDirectory();
    final directory =
        Directory('${root.path}/documents/$documentId/annotations');
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> _file(String documentId, String pageId) async =>
      File('${(await _documentDirectory(documentId)).path}/$pageId.json');

  /// Keeps drawing images in the same document-owned attachment area used by
  /// note attachments, rather than retaining a fragile gallery/cache URI.
  Future<File> copyImageAttachment(String documentId, File source) async {
    final root = await getApplicationDocumentsDirectory();
    final directory =
        Directory('${root.path}/documents/$documentId/attachments');
    await directory.create(recursive: true);
    final extension = source.path.split('.').last.toLowerCase();
    final target = File(
        '${directory.path}/${DateTime.now().microsecondsSinceEpoch}.${extension.isEmpty ? 'png' : extension}');
    return source.copy(target.path);
  }

  Future<List<Stroke>> load(String documentId, String pageId) async {
    return (await loadPage(documentId, pageId)).strokes;
  }

  Future<DrawingPageData> loadPage(String documentId, String pageId) async {
    try {
      final file = await _file(documentId, pageId);
      if (!await file.exists()) return const DrawingPageData();
      final json = jsonDecode(await file.readAsString());
      // Legacy pages are a raw stroke array. Keep them readable without a
      // migration, while new drawing-note pages add an independent shapes list.
      if (json is List) {
        return DrawingPageData(
          strokes: json
              .map((item) => Stroke.fromJson(item as Map<String, dynamic>))
              .toList(),
        );
      }
      final page = json as Map<String, dynamic>;
      return DrawingPageData(
        strokes: ((page['strokes'] as List?) ?? const [])
            .map((item) => Stroke.fromJson(item as Map<String, dynamic>))
            .toList(),
        shapes: ((page['shapes'] as List?) ?? const [])
            .map((item) => DrawingShape.fromJson(item as Map<String, dynamic>))
            .toList(),
        texts: ((page['texts'] as List?) ?? const [])
            .map((item) => DrawingText.fromJson(item as Map<String, dynamic>))
            .toList(),
        images: ((page['images'] as List?) ?? const [])
            .map((item) => DrawingImage.fromJson(item as Map<String, dynamic>))
            .toList(),
      );
    } catch (_) {
      return const DrawingPageData();
    }
  }

  Future<void> save(
      String documentId, String pageId, List<Stroke> strokes) async {
    final existing = await loadPage(documentId, pageId);
    await savePage(
        documentId,
        pageId,
        DrawingPageData(
            strokes: strokes,
            shapes: existing.shapes,
            texts: existing.texts,
            images: existing.images));
  }

  Future<void> savePage(
      String documentId, String pageId, DrawingPageData page) async {
    final file = await _file(documentId, pageId);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
        jsonEncode({
          'strokes': page.strokes.map((stroke) => stroke.toJson()).toList(),
          'shapes': page.shapes.map((shape) => shape.toJson()).toList(),
          'texts': page.texts.map((text) => text.toJson()).toList(),
          'images': page.images.map((image) => image.toJson()).toList(),
        }),
        flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  /// Drawing notebooks use sequential page file names. When a page is removed,
  /// shift later files down so the visible page order and persisted data never
  /// diverge (for example, deleting page 1 of a three-page notebook).
  Future<void> deleteNotebookPageAndShift(
    String documentId, {
    required int removedPage,
    required int pageCount,
  }) async {
    final directory = await _documentDirectory(documentId);
    for (var page = removedPage; page < pageCount; page++) {
      final target = File('${directory.path}/page_$page.json');
      final source = File('${directory.path}/page_${page + 1}.json');
      if (await target.exists()) await target.delete();
      if (await source.exists()) await source.rename(target.path);
    }
    final finalFile = File('${directory.path}/page_$pageCount.json');
    if (await finalFile.exists()) await finalFile.delete();
  }
}
