import 'dart:io';

import 'package:docnote/core/database/document_model.dart';
import 'package:docnote/core/storage/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late BackupService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'docnote.settings.theme': 'dark',
      'docnote.settings.autoSave': true,
      'docnote.editor.tool.penColor': 0xff123456,
      'docnote.pageBookmarks.doc-a': <String>['1', '3'],
      'docnote.pageBookmarks.doc-b': <String>['2'],
      'docnote.pageSections.doc-a': '[{"title":"Chapter 1"}]',
      'docnote.pageRotation.doc-a.page_1': 90,
      'unrelated.preference': 'do-not-copy',
    });
    root = await Directory.systemTemp.createTemp('docnote-backup-test-');
    service = BackupService(documentsDirectoryProvider: () async => root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('backs up selected document files and restores metadata/preferences',
      () async {
    final docs = Directory('${root.path}/documents');
    final annotation = File('${docs.path}/doc-a/annotations/page_1.json');
    await annotation.create(recursive: true);
    await annotation.writeAsString('{"strokes":[]}');
    final source = File('${docs.path}/doc-b/original/source.pdf');
    await source.create(recursive: true);
    await source.writeAsString('pdf-b');
    final orphan = File('${docs.path}/orphan/unknown.bin');
    await orphan.create(recursive: true);
    await orphan.writeAsString('not part of the library');

    final backup = await service.createBackup([
      DocumentItem(
          id: 'doc-a',
          title: 'Notebook',
          type: DocumentType.drawingNote,
          pageCount: 1,
          internalPath: '${docs.path}/doc-a'),
    ]);
    await Directory('${docs.path}/doc-b').delete(recursive: true);
    await Directory('${docs.path}/orphan').delete(recursive: true);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('docnote.settings.theme', 'light');
    await prefs.remove('docnote.pageBookmarks.doc-a');
    final preview = await service.restoreBackup(backup, writeFiles: false);
    expect(preview.single.title, 'Notebook');
    expect(prefs.getString('docnote.settings.theme'), 'light');

    final restored = await service.restoreBackup(
      backup,
      documentIds: {'doc-a'},
      restoreGlobalPreferences: true,
    );
    expect(restored.single.internalPath,
        contains('documents${Platform.pathSeparator}doc-a'));
    expect(await File('${docs.path}/doc-a/annotations/page_1.json').exists(),
        isTrue);
    expect(await Directory('${docs.path}/doc-b').exists(), isFalse);
    expect(await Directory('${docs.path}/orphan').exists(), isFalse);
    expect(prefs.getString('docnote.settings.theme'), 'dark');
    expect(prefs.getStringList('docnote.pageBookmarks.doc-a'), ['1', '3']);
    expect(prefs.getStringList('docnote.pageBookmarks.doc-b'), ['2']);
    expect(prefs.getString('unrelated.preference'), 'do-not-copy');
  });

  test('partial restore does not overwrite global preferences', () async {
    final docs = Directory('${root.path}/documents');
    final annotation = File('${docs.path}/doc-a/annotations/page_1.json');
    await annotation.create(recursive: true);
    await annotation.writeAsString('annotation');
    final backup = await service.createBackup([
      DocumentItem(
          id: 'doc-a',
          title: 'A',
          type: DocumentType.drawingNote,
          pageCount: 1),
    ]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('docnote.settings.theme', 'light');
    await service.restoreBackup(backup, documentIds: {'doc-a'});
    expect(prefs.getString('docnote.settings.theme'), 'light');
  });
}
