import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../features/drawing/domain/stroke.dart';

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

  Future<List<Stroke>> load(String documentId, String pageId) async {
    try {
      final file = await _file(documentId, pageId);
      if (!await file.exists()) return [];
      final json = jsonDecode(await file.readAsString()) as List;
      return json
          .map((item) => Stroke.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(
      String documentId, String pageId, List<Stroke> strokes) async {
    final file = await _file(documentId, pageId);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
        jsonEncode(strokes.map((stroke) => stroke.toJson()).toList()),
        flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
