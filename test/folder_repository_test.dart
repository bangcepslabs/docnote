import 'dart:convert';

import 'package:docnote/core/database/document_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('손상된 폴더 항목이 있어도 유효한 폴더는 복원한다', () async {
    SharedPreferences.setMockInitialValues({
      FolderRepository.key: jsonEncode([
        {'id': 'work', 'name': '업무'},
        {'id': 7, 'name': '손상된 폴더'},
        {'id': 'study', 'name': '공부'},
      ]),
    });

    final folders = await const FolderRepository().load();

    expect(folders.map((folder) => folder.id), ['work', 'study']);
  });
}
