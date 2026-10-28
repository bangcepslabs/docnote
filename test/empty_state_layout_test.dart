import 'package:docnote/core/theme/docnote_theme.dart';
import 'package:docnote/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('empty states remain readable in short and wide viewports',
      (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final size in [const Size(320, 160), const Size(1000, 700)]) {
      for (final theme in [DocNoteTheme.light(), DocNoteTheme.dark()]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
            ),
            child: child!,
          ),
          home: const Scaffold(
              body: EmptyState(
            title: '검색 결과가 없습니다',
            message: '다른 제목이나 메모 내용으로 검색해 보세요.',
            icon: Icons.search_off_outlined,
          )),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('다른 제목이나 메모 내용으로 검색해 보세요.'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.text('다른 제목이나 메모 내용으로 검색해 보세요.')).width,
            lessThanOrEqualTo(420));
      }
    }
  });
}
