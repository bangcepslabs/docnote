import 'dart:io';
import 'dart:ui';

import 'package:docnote/core/storage/annotation_store.dart';
import 'package:docnote/features/drawing/domain/drawing_shape.dart';
import 'package:docnote/features/drawing/domain/stroke.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late AnnotationStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('docnote-pages-');
    store = AnnotationStore(documentsDirectoryProvider: () async => root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> seedPages() async {
    for (var page = 1; page <= 3; page++) {
      await store.savePage(
          'doc',
          'page_$page',
          DrawingPageData(
            strokes: [_stroke('stroke-$page', page)],
          ));
    }
  }

  test('page reorder swaps persisted page contents', () async {
    await seedPages();

    await store.swapNotebookPages('doc', firstPage: 1, secondPage: 2);

    expect((await store.load('doc', 'page_1')).single.id, 'stroke-2');
    expect((await store.load('doc', 'page_2')).single.id, 'stroke-1');
    expect((await store.load('doc', 'page_3')).single.id, 'stroke-3');
  });

  test('duplicate and blank insertion preserve sequential page data', () async {
    await seedPages();

    await store.insertNotebookPage('doc', sourcePage: 1, pageCount: 3);
    expect((await store.load('doc', 'page_1')).single.id, 'stroke-1');
    expect((await store.load('doc', 'page_2')).single.id, 'stroke-1');
    expect((await store.load('doc', 'page_3')).single.id, 'stroke-2');
    expect((await store.load('doc', 'page_4')).single.id, 'stroke-3');

    await store.insertBlankNotebookPage('doc', sourcePage: 2, pageCount: 4);
    expect((await store.load('doc', 'page_3')), isEmpty);
    expect((await store.load('doc', 'page_4')).single.id, 'stroke-2');
    expect((await store.load('doc', 'page_5')).single.id, 'stroke-3');
  });

  test('page deletion shifts later contents and removes final slot', () async {
    await seedPages();

    await store.deleteNotebookPageAndShift('doc', removedPage: 2, pageCount: 3);

    expect((await store.load('doc', 'page_1')).single.id, 'stroke-1');
    expect((await store.load('doc', 'page_2')).single.id, 'stroke-3');
    expect(
        await File('${root.path}/documents/doc/annotations/page_3.json')
            .exists(),
        isFalse);
  });
}

Stroke _stroke(String id, int page) => Stroke(
      id: id,
      documentId: 'doc',
      pageId: 'page_$page',
      tool: StrokeTool.pen,
      points: const [StrokePoint(0.2, 0.3, 1)],
      color: const Color(0xff17202a),
      width: 2,
      opacity: 1,
      order: 0,
      createdAt: DateTime.utc(2025),
    );
