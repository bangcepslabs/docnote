import 'dart:io';

/// Imported original files are immutable; edits live next to annotations.
class HwpWorkingStore {
  HwpWorkingStore(String sourcePath)
      : original = File(sourcePath),
        working =
            File('${File(sourcePath).parent.parent.path}/working/edited.hwp');

  final File original;
  final File working;

  Future<File> fileToOpen() async =>
      await working.exists() ? working : original;

  Future<void> save(List<int> bytes) async {
    if (bytes.isEmpty) throw const FormatException('Empty HWP export');
    await working.parent.create(recursive: true);
    final temporary = File('${working.path}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(working.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
