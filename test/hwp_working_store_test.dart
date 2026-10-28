import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:docnote/features/hwp/data/hwp_working_store.dart';

void main() {
  test('HWP saves and reopens working copy without touching original',
      () async {
    final root = await Directory.systemTemp.createTemp('docnote_hwp_qa_');
    addTearDown(() => root.delete(recursive: true));
    final original = File('${root.path}/original/sample.hwpx');
    await original.parent.create();
    await original.writeAsBytes([1, 2, 3]);
    final store = HwpWorkingStore(original.path);
    expect((await store.fileToOpen()).path, original.path);
    await store.save([4, 5, 6]);
    expect(await (await store.fileToOpen()).readAsBytes(), [4, 5, 6]);
    await store.save([7, 8]);
    expect(await (await store.fileToOpen()).readAsBytes(), [7, 8]);
    await expectLater(store.save([]), throwsFormatException);
    expect(await original.readAsBytes(), [1, 2, 3]);
    expect(await store.working.readAsBytes(), [7, 8]);
    expect(await File('${store.working.path}.tmp').exists(), isFalse);
  });
}
