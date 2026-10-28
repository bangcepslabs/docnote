import 'package:docnote/core/theme/docnote_theme.dart';
import 'package:docnote/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('primary button text is readable in both themes', () {
    for (final theme in [DocNoteTheme.light(), DocNoteTheme.dark()]) {
      final a = theme.colorScheme.primary.computeLuminance();
      final b = theme.colorScheme.onPrimary.computeLuminance();
      final contrast = ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
      expect(contrast, greaterThanOrEqualTo(4.5));
      final textButton =
          theme.textButtonTheme.style!.foregroundColor!.resolve({})!;
      final foreground = textButton.computeLuminance();
      final background = theme.colorScheme.surface.computeLuminance();
      expect(
        ((foreground > background ? foreground : background) + .05) /
            ((foreground < background ? foreground : background) + .05),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  testWidgets(
      'creation CTA remains visible above the keyboard on small screens',
      (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final size in [const Size(320, 640), const Size(800, 600)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(MaterialApp(
        theme: DocNoteTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            viewInsets: const EdgeInsets.only(bottom: 260),
            textScaler: const TextScaler.linear(1.3),
          ),
          child: child!,
        ),
        home: const Scaffold(
          resizeToAvoidBottomInset: false,
          body: Align(
            alignment: Alignment.bottomCenter,
            child: NotebookCreateSheet(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final cta = find.widgetWithText(FilledButton, '노트 만들기');
      expect(cta, findsOneWidget);
      expect(tester.getRect(cta).bottom, lessThanOrEqualTo(size.height - 260));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('cover and paper pickers fit narrow dark and wide light screens',
      (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final size in [const Size(320, 640), const Size(1000, 700)]) {
      await tester.binding.setSurfaceSize(size);
      for (final theme in [DocNoteTheme.light(), DocNoteTheme.dark()]) {
        for (final page in [
          const NotebookCoverPickerPage(initialCoverId: 'simple'),
          const NotebookPaperPickerPage(initialTemplateId: 'blank'),
        ]) {
          await tester.pumpWidget(MaterialApp(
            theme: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.3),
              ),
              child: child!,
            ),
            home: page,
          ));
          await tester.pumpAndSettle();
          expect(find.text('선택됨'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
    }
  });

  testWidgets('picker return preserves title, cover and paper in the draft',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    NotebookDraft? draft;
    await tester.pumpWidget(MaterialApp(
      theme: DocNoteTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              draft = await showModalBottomSheet<NotebookDraft>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const NotebookCreateSheet(),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '나의 새 노트');
    await tester.tap(find.text('전체 보기').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('비즈니스 블루'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('전체 보기').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('전체 보기').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('넓은 줄 노트'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '노트 만들기'));
    await tester.pumpAndSettle();
    expect(draft?.title, '나의 새 노트');
    expect(draft?.coverId, 'work');
    expect(draft?.templateId, 'ruledWide');
    expect(tester.takeException(), isNull);
  });
}
