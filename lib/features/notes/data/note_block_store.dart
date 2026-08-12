import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/note_block.dart';

class NoteBlockStore {
  Future<File> _file(String documentId) async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/documents/$documentId/notes');
    await directory.create(recursive: true);
    return File('${directory.path}/blocks.json');
  }

  Future<List<NoteBlock>> load(String documentId) async {
    try {
      final file = await _file(documentId);
      if (!await file.exists()) return [];
      final json = jsonDecode(await file.readAsString()) as List;
      return json
          .map((item) => NoteBlock.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(String documentId, List<NoteBlock> blocks) async {
    final file = await _file(documentId);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(blocks.map((block) => block.toJson()).toList()),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
