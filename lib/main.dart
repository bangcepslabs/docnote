import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:uuid/uuid.dart';
import 'core/database/document_model.dart';
import 'core/settings/app_settings.dart';
import 'core/storage/annotation_store.dart';
import 'core/storage/document_thumbnail_service.dart';
import 'core/theme/docnote_theme.dart';
import 'features/notes/presentation/unified_note_editor.dart';
import 'features/drawing/presentation/drawing_editor.dart';
import 'features/drawing/domain/stroke.dart';
import 'features/pdf/data/pdf_file_validator.dart';
import 'features/pdf/presentation/pdf_editor.dart';
import 'features/hwp/presentation/hwp_editor.dart';
export 'core/database/document_model.dart';

final repositoryProvider = Provider((ref) => DocumentRepository());
final documentsProvider =
    StateNotifierProvider<DocumentsController, List<DocumentItem>>(
        (ref) => DocumentsController(ref.read(repositoryProvider))..restore());

class DocumentsController extends StateNotifier<List<DocumentItem>> {
  DocumentsController(this.repo) : super([]);
  final DocumentRepository repo;
  Future<void> restore() async => state = await repo.load();
  Future<void> add(DocumentItem d) async {
    state = [...state, d];
    await repo.save(state);
  }

  Future<void> update(DocumentItem d) async {
    state = [...state.where((x) => x.id != d.id), d]
      ..sort((a, b) => b.modified.compareTo(a.modified));
    await repo.save(state);
  }

  Future<void> remove(String id) async {
    final document = state.firstWhere((x) => x.id == id);
    document.trashed = true;
    document.favorite = false;
    document.modified = DateTime.now();
    await update(document);
  }

  Future<void> restoreFromTrash(String id) async {
    final document = state.firstWhere((x) => x.id == id);
    document.trashed = false;
    document.modified = DateTime.now();
    await update(document);
  }

  Future<void> permanentlyRemove(String id) async {
    state = state.where((x) => x.id != id).toList();
    await repo.save(state);
  }

  Future<int> collapseDuplicatePdfs() async {
    final kept = <List<int>>[];
    var removed = 0;
    final next = <DocumentItem>[];
    for (final document in state) {
      if (document.type != DocumentType.pdf ||
          document.trashed ||
          document.sourcePath == null) {
        next.add(document);
        continue;
      }
      final file = File(document.sourcePath!);
      if (!await file.exists()) {
        next.add(document);
        continue;
      }
      final bytes = await file.readAsBytes();
      final duplicate = kept.any((existing) =>
          existing.length == bytes.length && _bytesEqual(existing, bytes));
      if (duplicate) {
        document.trashed = true;
        document.modified = DateTime.now();
        removed++;
      } else {
        kept.add(bytes);
        next.add(document);
      }
    }
    if (removed > 0) {
      state = next;
      await repo.save(state);
    }
    return removed;
  }

  bool _bytesEqual(List<int> first, List<int> second) {
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }
}

final routerProvider = Provider((ref) => GoRouter(
    routes: [GoRoute(path: '/', builder: (_, __) => const AppShell())]));
void main() => runApp(const ProviderScope(child: DocNoteApp()));

class DocNoteApp extends ConsumerWidget {
  const DocNoteApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final themeMode = switch (settings.theme) {
      AppThemeChoice.system => ThemeMode.system,
      AppThemeChoice.light => ThemeMode.light,
      AppThemeChoice.dark => ThemeMode.dark,
    };
    return MaterialApp.router(
        title: 'DocNote',
        themeMode: themeMode,
        theme: DocNoteTheme.light(),
        darkTheme: DocNoteTheme.dark(),
        routerConfig: ref.watch(routerProvider));
  }
}

void openDocument(BuildContext context, DocumentItem document, WidgetRef ref) {
  document.lastOpened = DateTime.now();
  ref.read(documentsProvider.notifier).update(document);
  if (document.type == DocumentType.pdf) {
    final path = document.sourcePath;
    if (path == null || !File(path).existsSync()) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('원본 PDF 파일을 찾을 수 없습니다.')));
      return;
    }
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => PdfEditorPage(
                documentId: document.id, title: document.title, path: path)));
    return;
  }
  if (document.type == DocumentType.hwp || document.type == DocumentType.hwpx) {
    final path = document.sourcePath;
    if (path == null || !File(path).existsSync()) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('원본 HWP 파일을 찾을 수 없습니다.')));
      return;
    }
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => HwpEditorPage(
                documentId: document.id, title: document.title, path: path)));
    return;
  }
  if (document.type == DocumentType.drawingNote) {
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => DrawingEditorPage(
                documentId: document.id,
                title: document.title,
                initialPageCount: document.pageCount,
                pageTemplateId: document.pageStyle,
                onPageCountChanged: (count) {
                  document.pageCount = count;
                  document.modified = DateTime.now();
                  ref.read(documentsProvider.notifier).update(document);
                })));
    return;
  }
  Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => UnifiedNoteEditor(
              document: document,
              onSave: ref.read(documentsProvider.notifier).update,
              onDelete: ref.read(documentsProvider.notifier).remove)));
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});
  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int index = 0;
  bool creating = false;
  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(
          onQuickMemo: _quickMemo,
          onImportPdf: _pickPdf,
          onImportHwp: _pickHwp,
          onSearch: () => setState(() => index = 3),
          onOpenDocuments: () => setState(() => index = 1)),
      const DocumentsPage(),
      const SizedBox(),
      SearchPage(onClose: () => setState(() => index = 0)),
      SettingsPage(onClose: () => setState(() => index = 0)),
    ];
    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: _RefinedBottomNavigation(
        selectedIndex: index,
        onSelected: (value) {
          if (value == 2) {
            _createSheet();
          } else {
            setState(() => index = value);
          }
        },
      ),
    );
  }

  void _createSheet() => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _RefinedCreateSheet(
          onQuickMemo: _quickMemo,
          onDrawingNote: _drawingNote,
          onImportPdf: _pickPdf,
          onImportHwp: _pickHwp,
          onUnavailable: (message) =>
              ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message)),
          ),
        ),
      );
  Future<void> _quickMemo() async {
    if (creating) return;
    final draft = await showModalBottomSheet<NotebookDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const NotebookCreateSheet(),
    );
    if (draft == null) return;
    creating = true;
    final d = DocumentItem(
      id: const Uuid().v4(),
      title: draft.title.isEmpty ? '새 노트' : draft.title,
      // "새 노트" is a page-based notebook, distinct from the lightweight
      // text memo action in the create sheet.
      type: DocumentType.drawingNote,
      coverId: draft.coverId,
      templateId: draft.templateId,
    );
    await ref.read(documentsProvider.notifier).add(d);
    creating = false;
    if (mounted) openDocument(context, d, ref);
  }

  Future<void> _drawingNote() async {
    if (creating) return;
    creating = true;
    final d = DocumentItem(
        id: const Uuid().v4(), title: '', type: DocumentType.drawingNote);
    await ref.read(documentsProvider.notifier).add(d);
    creating = false;
    if (mounted) openDocument(context, d, ref);
  }

  Future<void> _pickPdf() async {
    try {
      final result = await FilePicker.platform.pickFiles(
          type: FileType.custom, allowedExtensions: ['pdf'], withData: true);
      if (result == null) return;
      final picked = result.files.single;
      developer.log(
          'picker name=${picked.name} path=${picked.path} bytes=${picked.bytes?.length}',
          name: 'docnote.pdf');
      final selectedBytes = picked.bytes ??
          (picked.path == null ? null : await File(picked.path!).readAsBytes());
      if (selectedBytes == null) {
        throw const FileSystemException('선택한 파일을 읽을 수 없습니다.');
      }
      final duplicate =
          await _findDuplicatePdf(selectedBytes, ref.read(documentsProvider));
      if (duplicate != null) {
        if (duplicate.trashed) {
          duplicate.trashed = false;
          await ref.read(documentsProvider.notifier).update(duplicate);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('이미 가져온 PDF입니다. 기존 문서를 엽니다.')));
          openDocument(context, duplicate, ref);
        }
        return;
      }
      final id = const Uuid().v4();
      final root = await getApplicationDocumentsDirectory();
      final directory = Directory('${root.path}/documents/$id/original');
      await directory.create(recursive: true);
      final target = File('${directory.path}/${picked.name}');
      developer.log('copy start id=$id target=${target.path}',
          name: 'docnote.pdf');
      if (picked.path != null) {
        await File(picked.path!).copy(target.path);
      } else {
        await target.writeAsBytes(selectedBytes, flush: true);
      }
      developer.log(
          'copy done exists=${await target.exists()} size=${await target.length()}',
          name: 'docnote.pdf');
      await PdfFileValidator.validate(target, documentId: id);
      final pdf = await PdfDocument.openFile(target.path);
      final pages = pdf.pagesCount;
      developer.log('pdf opened pages=$pages path=${target.path}',
          name: 'docnote.pdf');
      await pdf.close();
      final d = DocumentItem(
          id: id,
          title: picked.name,
          type: DocumentType.pdf,
          sourcePath: target.path,
          pageCount: pages);
      await ref.read(documentsProvider.notifier).add(d);
      if (mounted) openDocument(context, d, ref);
    } catch (error, stack) {
      developer.log('PDF import failed: $error',
          name: 'docnote.pdf', error: error, stackTrace: stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(error is FormatException
                ? error.message.toString()
                : 'PDF를 가져오지 못했습니다.')));
      }
    }
  }

  Future<void> _pickHwp() async {
    try {
      final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['hwp', 'hwpx'],
          withData: true);
      if (result == null) return;
      final picked = result.files.single;
      final bytes = picked.bytes ??
          (picked.path == null ? null : await File(picked.path!).readAsBytes());
      if (bytes == null) {
        throw const FileSystemException('선택한 HWP 파일을 읽을 수 없습니다.');
      }
      final id = const Uuid().v4();
      final root = await getApplicationDocumentsDirectory();
      final directory = Directory('${root.path}/documents/$id/original');
      await directory.create(recursive: true);
      final target = File('${directory.path}/${picked.name}');
      await target.writeAsBytes(bytes, flush: true);
      final extension = picked.name.toLowerCase().endsWith('.hwpx')
          ? DocumentType.hwpx
          : DocumentType.hwp;
      final document = DocumentItem(
          id: id, title: picked.name, type: extension, sourcePath: target.path);
      await ref.read(documentsProvider.notifier).add(document);
      if (mounted) openDocument(context, document, ref);
    } catch (error, stack) {
      developer.log('HWP import failed: $error',
          name: 'docnote.hwp', error: error, stackTrace: stack);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('HWP 파일을 가져오지 못했습니다.')));
      }
    }
  }

  Future<DocumentItem?> _findDuplicatePdf(
      List<int> selectedBytes, List<DocumentItem> documents) async {
    for (final document in documents.where((d) => d.type == DocumentType.pdf)) {
      final path = document.sourcePath;
      if (path == null) continue;
      final file = File(path);
      if (!await file.exists() || await file.length() != selectedBytes.length) {
        continue;
      }
      final existingBytes = await file.readAsBytes();
      if (existingBytes.length == selectedBytes.length &&
          _bytesEqual(existingBytes, selectedBytes)) {
        return document;
      }
    }
    return null;
  }

  bool _bytesEqual(List<int> first, List<int> second) {
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }
}

class _RefinedBottomNavigation extends StatelessWidget {
  const _RefinedBottomNavigation(
      {required this.selectedIndex, required this.onSelected});
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const items = <(IconData, IconData, String)>[
    (Icons.home_outlined, Icons.home, '홈'),
    (Icons.folder_outlined, Icons.folder, '문서'),
    (Icons.add, Icons.add, '새로 만들기'),
    (Icons.search_outlined, Icons.search, '검색'),
    (Icons.settings_outlined, Icons.settings, '설정'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 76 + MediaQuery.paddingOf(context).bottom,
      padding:
          EdgeInsets.fromLTRB(12, 8, 12, MediaQuery.paddingOf(context).bottom),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: .96),
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          for (var index = 0; index < items.length; index++)
            Expanded(
              child: _RefinedNavigationItem(
                index: index,
                selected: index == selectedIndex,
                icon: items[index].$1,
                label: items[index].$3,
                onTap: () => onSelected(index),
              ),
            ),
        ],
      ),
    );
  }
}

class _RefinedNavigationItem extends StatelessWidget {
  const _RefinedNavigationItem(
      {required this.index,
      required this.selected,
      required this.icon,
      required this.label,
      required this.onTap});
  final int index;
  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xffd9eafe) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: double.infinity,
          height: 60,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: index == 2 ? 22 : 18,
                  color: index == 2
                      ? DocNoteTheme.accent
                      : selected
                          ? DocNoteTheme.ink
                          : const Color(0xff737a83)),
              const SizedBox(height: 3),
              SizedBox(
                width: double.infinity,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? DocNoteTheme.ink
                          : const Color(0xff737a83)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RefinedCreateSheet extends StatelessWidget {
  const _RefinedCreateSheet({
    required this.onQuickMemo,
    required this.onDrawingNote,
    required this.onImportPdf,
    required this.onImportHwp,
    required this.onUnavailable,
  });
  final VoidCallback onQuickMemo;
  final VoidCallback onDrawingNote;
  final VoidCallback onImportPdf;
  final VoidCallback onImportHwp;
  final ValueChanged<String> onUnavailable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        constraints: const BoxConstraints(maxHeight: 620),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: .12),
                blurRadius: 18,
                offset: const Offset(0, -6)),
          ],
        ),
        child: SingleChildScrollView(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _RefinedSheetHandle(color: scheme.outlineVariant),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                  child: Text('새로 만들기',
                      style: Theme.of(context).textTheme.titleLarge)),
              IconButton(
                onPressed: () => Navigator.pop(context),
                tooltip: '닫기',
                icon: const Icon(Icons.close_outlined),
              ),
            ]),
            const SizedBox(height: 8),
            _CreateActionTile(
              icon: Icons.note_add_outlined,
              title: '새 노트',
              description: '표지와 속지를 골라 시작합니다.',
              primary: true,
              onTap: () {
                Navigator.pop(context);
                onQuickMemo();
              },
            ),
            _CreateActionTile(
              icon: Icons.draw_outlined,
              title: '필기 노트',
              description: '빈 페이지에 바로 필기합니다.',
              onTap: () {
                Navigator.pop(context);
                onDrawingNote();
              },
            ),
            _CreateActionTile(
              icon: Icons.picture_as_pdf_outlined,
              title: 'PDF 가져오기',
              description: 'PDF 문서를 불러옵니다.',
              onTap: () {
                Navigator.pop(context);
                onImportPdf();
              },
            ),
            _CreateActionTile(
              icon: Icons.description_outlined,
              title: 'HWP 가져오기',
              description: '한글 문서를 불러옵니다.',
              onTap: () {
                Navigator.pop(context);
                onImportHwp();
              },
            ),
            _CreateActionTile(
              icon: Icons.image_outlined,
              title: '이미지 가져오기',
              description: '메모 첨부 기능 준비 중',
              onTap: () {
                Navigator.pop(context);
                onUnavailable('이미지 첨부 기능은 준비 중입니다.');
              },
            ),
            _CreateActionTile(
              icon: Icons.document_scanner_outlined,
              title: '문서 스캔',
              description: '카메라 스캔 기능 준비 중',
              onTap: () {
                Navigator.pop(context);
                onUnavailable('문서 스캔 기능은 준비 중입니다.');
              },
            ),
          ]),
        ),
      ),
    );
  }
}

class _CreateActionTile extends StatelessWidget {
  const _CreateActionTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.primary = false,
  });
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: primary
            ? scheme.primaryContainer.withValues(alpha: .62)
            : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .72)),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
          child: ListTile(
            minVerticalPadding: 10,
            leading: DecoratedBox(
              decoration: BoxDecoration(
                color: primary ? scheme.primary : scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Padding(
                padding: const EdgeInsets.all(9),
                child: Icon(icon,
                    color:
                        primary ? scheme.onPrimary : scheme.onSurfaceVariant),
              ),
            ),
            title: Text(title),
            subtitle: Text(description),
            trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

class NotebookDraft {
  const NotebookDraft({
    required this.title,
    required this.coverId,
    required this.templateId,
  });
  final String title;
  final String coverId;
  final String templateId;
}

class NotebookCreateSheet extends StatefulWidget {
  const NotebookCreateSheet({super.key});

  @override
  State<NotebookCreateSheet> createState() => _NotebookCreateSheetState();
}

class _NotebookCreateSheetState extends State<NotebookCreateSheet> {
  final titleController = TextEditingController();
  var coverId = 'simple';
  var templateId = 'blank';
  static const covers = <String, String>{
    'simple': '심플',
    'work': '업무',
    'study': '공부',
    'planner': '플래너',
    'minimal': '미니멀',
    'dark': '다크',
    'mood': '감성',
    'ocean': '오션',
    'rose': '로즈',
    'forest': '포레스트',
    'sand': '샌드',
    'violet': '바이올렛',
  };
  static const templates = <String, String>{
    'blank': 'Blank',
    'ruled': 'Ruled',
    'ruledWide': 'Wide ruled',
    'grid': 'Grid',
    'graph5': '5mm graph',
    'dotted': 'Dotted',
    'cornell': 'Cornell',
    'checklist': 'Checklist',
    'meeting': 'Meeting Notes',
    'kanban': 'Kanban board',
    'timetable': 'Study timetable',
    'daily': 'Daily planner',
    'weekly': 'Weekly planner',
    'monthly': 'Monthly planner',
    'calendar': 'Calendar',
    'habit': 'Habit tracker',
  };

  @override
  void dispose() {
    titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final useRefinedDesign =
        Theme.of(context).platform != TargetPlatform.fuchsia;
    if (useRefinedDesign) {
      return _RefinedNotebookCreateBody(
        titleController: titleController,
        coverId: coverId,
        templateId: templateId,
        onCoverChanged: (value) => setState(() => coverId = value),
        onTemplateChanged: (value) => setState(() => templateId = value),
        onCreate: () => Navigator.pop(
          context,
          NotebookDraft(
            title: titleController.text.trim(),
            coverId: coverId,
            templateId: templateId,
          ),
        ),
      );
    }

    // Legacy combined picker retained below for a low-risk rollback.
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text('새 노트', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 14),
              TextField(
                controller: titleController,
                decoration: const InputDecoration(
                  hintText: '노트 제목 (선택)',
                  filled: true,
                  border: OutlineInputBorder(borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 18),
              _SheetSectionHeader(
                title: '표지 선택',
                subtitle: '노트북 서재에서 보이는 겉표지입니다.',
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 126,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: covers.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, index) {
                    final entry = covers.entries.elementAt(index);
                    return _CoverChoice(
                      id: entry.key,
                      label: entry.value,
                      selected: coverId == entry.key,
                      onTap: () => setState(() => coverId = entry.key),
                    );
                  },
                ),
              ),
              const SizedBox(height: 22),
              _SheetSectionHeader(
                title: '속지 선택',
                subtitle: '생성 후에도 같은 스타일의 페이지를 계속 추가할 수 있습니다.',
              ),
              const SizedBox(height: 10),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.34,
                ),
                itemCount: templates.length,
                itemBuilder: (_, index) {
                  final entry = templates.entries.elementAt(index);
                  return _TemplateChoice(
                    id: entry.key,
                    label: entry.value,
                    selected: templateId == entry.key,
                    onTap: () => setState(() => templateId = entry.key),
                  );
                },
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    NotebookDraft(
                      title: titleController.text.trim(),
                      coverId: coverId,
                      templateId: templateId,
                    ),
                  ),
                  child: const Text('노트 만들기'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RefinedNotebookCreateBody extends StatefulWidget {
  const _RefinedNotebookCreateBody({
    required this.titleController,
    required this.coverId,
    required this.templateId,
    required this.onCoverChanged,
    required this.onTemplateChanged,
    required this.onCreate,
  });
  final TextEditingController titleController;
  final String coverId;
  final String templateId;
  final ValueChanged<String> onCoverChanged;
  final ValueChanged<String> onTemplateChanged;
  final VoidCallback onCreate;

  @override
  State<_RefinedNotebookCreateBody> createState() =>
      _RefinedNotebookCreateBodyState();
}

class _RefinedNotebookCreateBodyState
    extends State<_RefinedNotebookCreateBody> {
  bool pickingPaper = false;
  String paperCategory = '기본';
  static const paperCategories = <String, List<String>>{
    '기본': ['ruled', 'ruledWide', 'blank'],
    '공부': ['grid', 'graph5', 'dotted', 'cornell', 'timetable'],
    '업무': ['checklist', 'meeting', 'kanban'],
    '플래너': ['weekly', 'daily', 'monthly', 'habit'],
  };
  static const paperNames = <String, String>{
    'ruled': '줄 노트',
    'ruledWide': '넓은 줄 노트',
    'blank': '빈 종이',
    'grid': '그리드',
    'graph5': '5mm 모눈',
    'dotted': '도트',
    'cornell': 'Cornell',
    'checklist': '체크리스트',
    'meeting': '회의 노트',
    'kanban': '칸반 보드',
    'timetable': '학습 시간표',
    'weekly': '주간 플래너',
    'daily': '데일리 플래너',
    'monthly': '월간 플래너',
    'habit': '습관 트래커',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 760),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _RefinedSheetHandle(color: scheme.outlineVariant),
            const SizedBox(height: 16),
            Row(children: [
              if (pickingPaper)
                IconButton(
                  onPressed: () => setState(() => pickingPaper = false),
                  tooltip: '새 노트로 돌아가기',
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: Text(pickingPaper ? '속지 선택' : '새 노트',
                    style: Theme.of(context).textTheme.titleLarge),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                tooltip: '닫기',
                icon: const Icon(Icons.close_outlined),
              ),
            ]),
            if (pickingPaper) _paperPicker(context) else _notebookForm(context),
          ]),
        ),
      ),
    );
  }

  Widget _notebookForm(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 4),
      const _RefinedStepIndicator(),
      const SizedBox(height: 22),
      Text('새 기록을 위한 공간', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8),
      Text('제목을 입력한 뒤 표지와 속지를 선택하세요.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              )),
      const SizedBox(height: 20),
      Text('노트북 이름', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      TextField(
        controller: widget.titleController,
        decoration: const InputDecoration(
          hintText: '새 노트북',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 16),
      _RefinedChoiceRow(
        icon: Icons.book_outlined,
        title: '표지',
        description: '${_coverName(widget.coverId)} · 선택하기',
        onTap: () => _openCoverPicker(context),
      ),
      const SizedBox(height: 8),
      _RefinedChoiceRow(
        icon: Icons.description_outlined,
        title: '속지',
        description: '${paperNames[widget.templateId] ?? '줄 노트'} · 선택하기',
        onTap: () => _openPaperPicker(context),
      ),
      const SizedBox(height: 20),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: FilledButton(
              onPressed: widget.onCreate, child: const Text('노트북 만들기')),
        ),
      ]),
    ]);
  }

  Widget _paperPicker(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ids = paperCategories[paperCategory]!;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text('쓰는 방식에 맞는 종이를 고르세요.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                )),
      ),
      const SizedBox(height: 20),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final category in paperCategories.keys)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(category),
                selected: category == paperCategory,
                onSelected: (_) => setState(() => paperCategory = category),
                showCheckmark: false,
                backgroundColor: Colors.transparent,
                selectedColor: scheme.onSurface,
                side: BorderSide(color: scheme.outlineVariant),
                labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: category == paperCategory
                          ? scheme.surface
                          : scheme.onSurfaceVariant,
                    ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 16),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: .92,
        ),
        itemCount: ids.length,
        itemBuilder: (_, index) {
          final id = ids[index];
          final selected = widget.templateId == id;
          return _RefinedPaperCard(
            id: id,
            label: paperNames[id] ?? id,
            group: paperCategory,
            selected: selected,
            onTap: () {
              widget.onTemplateChanged(id);
              setState(() => pickingPaper = false);
            },
          );
        },
      ),
    ]);
  }

  Future<void> _openPaperPicker(BuildContext context) async {
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            NotebookPaperPickerPage(initialTemplateId: widget.templateId),
      ),
    );
    if (selected != null) widget.onTemplateChanged(selected);
  }

  Future<void> _openCoverPicker(BuildContext context) async {
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => NotebookCoverPickerPage(initialCoverId: widget.coverId),
      ),
    );
    if (selected != null) widget.onCoverChanged(selected);
  }
}

class NotebookPaperPickerPage extends StatefulWidget {
  const NotebookPaperPickerPage({required this.initialTemplateId, super.key});
  final String initialTemplateId;

  @override
  State<NotebookPaperPickerPage> createState() =>
      _NotebookPaperPickerPageState();
}

class _NotebookPaperPickerPageState extends State<NotebookPaperPickerPage> {
  static const categories = <String, List<String>>{
    '기본': ['ruled', 'ruledWide', 'blank'],
    '공부': ['grid', 'graph5', 'dotted', 'cornell', 'timetable'],
    '업무': ['checklist', 'meeting', 'kanban'],
    '플래너': ['weekly', 'daily', 'monthly', 'habit'],
  };
  static const names = <String, String>{
    'ruled': '줄 노트',
    'ruledWide': '넓은 줄 노트',
    'blank': '빈 종이',
    'grid': '그리드',
    'graph5': '5mm 모눈',
    'dotted': '도트',
    'cornell': 'Cornell',
    'checklist': '체크리스트',
    'meeting': '회의 노트',
    'kanban': '칸반 보드',
    'timetable': '학습 시간표',
    'weekly': '주간 플래너',
    'daily': '데일리 플래너',
    'monthly': '월간 플래너',
    'habit': '습관 트래커',
  };
  late String selected = widget.initialTemplateId;
  late String category = categories.entries
      .firstWhere((entry) => entry.value.contains(selected),
          orElse: () => categories.entries.first)
      .key;

  @override
  Widget build(BuildContext context) => _PickerScaffold(
        title: '속지 선택',
        subtitle: '쓰는 방식에 맞는 종이를 고르세요.',
        onBack: () => Navigator.pop(context),
        categories: categories.keys.toList(),
        selectedCategory: category,
        onCategoryChanged: (value) => setState(() => category = value),
        gridBuilder: (columns) => GridView.builder(
          padding: const EdgeInsets.only(top: 16, bottom: 28),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: .84,
          ),
          itemCount: categories[category]!.length,
          itemBuilder: (_, index) {
            final id = categories[category]![index];
            return _PickerPaperCard(
              id: id,
              label: names[id] ?? id,
              category: category,
              selected: id == selected,
              onTap: () {
                setState(() => selected = id);
                Navigator.pop(context, id);
              },
            );
          },
        ),
      );
}

class NotebookCoverPickerPage extends StatefulWidget {
  const NotebookCoverPickerPage({required this.initialCoverId, super.key});
  final String initialCoverId;

  @override
  State<NotebookCoverPickerPage> createState() =>
      _NotebookCoverPickerPageState();
}

class _NotebookCoverPickerPageState extends State<NotebookCoverPickerPage> {
  static const covers =
      <String, ({String name, String category, String sample})>{
    'simple': (name: '차분한 블루', category: '전체', sample: '공부 기록'),
    'work': (name: '소프트 세이지', category: '업무', sample: '프로젝트'),
    'planner': (name: '코랄 플래너', category: '플래너', sample: '주간 플래너'),
    'mood': (name: '라벤더 메모', category: '미니멀', sample: '아이디어'),
    'dark': (name: '잉크 다크', category: '다크', sample: '회의 기록'),
    'study': (name: '페이퍼 샌드', category: '공부', sample: '오늘의 할 일'),
    'ocean': (name: '오션 블루', category: '공부', sample: '집중 노트'),
    'rose': (name: '로즈 에디션', category: '미니멀', sample: '아이디어'),
    'forest': (name: '포레스트 그린', category: '업무', sample: '프로젝트 기록'),
    'sand': (name: '페이퍼 샌드', category: '플래너', sample: '오늘의 계획'),
    'violet': (name: '바이올렛 스터디', category: '공부', sample: '학습 기록'),
  };
  static const categories = ['전체', '미니멀', '공부', '업무', '플래너', '다크'];
  late String selected = widget.initialCoverId;
  String category = '전체';

  @override
  Widget build(BuildContext context) {
    final ids = covers.entries
        .where((entry) => category == '전체' || entry.value.category == category)
        .map((entry) => entry.key)
        .toList();
    return _PickerScaffold(
      title: '표지 선택',
      subtitle: '노트북의 첫인상을 골라보세요.',
      onBack: () => Navigator.pop(context),
      categories: categories,
      selectedCategory: category,
      onCategoryChanged: (value) => setState(() => category = value),
      gridBuilder: (columns) => GridView.builder(
        padding: const EdgeInsets.only(top: 16, bottom: 28),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: .72,
        ),
        itemCount: ids.length,
        itemBuilder: (_, index) {
          final id = ids[index];
          final cover = covers[id]!;
          return _PickerCoverCard(
            id: id,
            name: cover.name,
            category: cover.category,
            sample: cover.sample,
            selected: selected == id,
            onTap: () {
              setState(() => selected = id);
              Navigator.pop(context, id);
            },
          );
        },
      ),
    );
  }
}

class _PickerScaffold extends StatelessWidget {
  const _PickerScaffold({
    required this.title,
    required this.subtitle,
    required this.onBack,
    required this.categories,
    required this.selectedCategory,
    required this.onCategoryChanged,
    required this.gridBuilder,
  });
  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final List<String> categories;
  final String selectedCategory;
  final ValueChanged<String> onCategoryChanged;
  final Widget Function(int columns) gridBuilder;

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xfff5f7f8);
    const surface = Color(0xfffcfdfd);
    const ink = Color(0xff26313e);
    const muted = Color(0xff6c7682);
    const border = Color(0xffd9e0e5);
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
              child: LayoutBuilder(builder: (context, constraints) {
                final columns = constraints.maxWidth >= 600 ? 3 : 2;
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 64,
                        child: Row(children: [
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: onBack,
                              borderRadius: BorderRadius.circular(22),
                              child: const SizedBox(
                                width: 44,
                                height: 44,
                                child: Center(
                                    child: Text('‹',
                                        style: TextStyle(fontSize: 28))),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(title,
                              style: const TextStyle(
                                  color: ink,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700)),
                        ]),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 56, top: 8),
                        child: Text(subtitle,
                            style: const TextStyle(color: muted, fontSize: 13)),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 34,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: categories.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (_, index) {
                            final item = categories[index];
                            final active = item == selectedCategory;
                            return OutlinedButton(
                              onPressed: () => onCategoryChanged(item),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 34),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                side: BorderSide(color: active ? ink : border),
                                backgroundColor:
                                    active ? ink : Colors.transparent,
                                foregroundColor: active ? surface : muted,
                                shape: const StadiumBorder(),
                              ),
                              child: Text(item,
                                  style: const TextStyle(fontSize: 13)),
                            );
                          },
                        ),
                      ),
                      Expanded(child: gridBuilder(columns)),
                    ]);
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _PickerPaperCard extends StatelessWidget {
  const _PickerPaperCard({
    required this.id,
    required this.label,
    required this.category,
    required this.selected,
    required this.onTap,
  });
  final String id;
  final String label;
  final String category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xfffcfdfd),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
              color: selected ? DocNoteTheme.accent : const Color(0xffd9e0e5),
              width: selected ? 2 : 1),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: EdgeInsets.all(selected ? 9 : 10),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                  height: 110,
                  width: double.infinity,
                  child: ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: _TemplatePaper(templateId: id))),
              const SizedBox(height: 8),
              Text(label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(selected ? '선택됨 · $category' : category,
                  style:
                      const TextStyle(color: Color(0xff6c7682), fontSize: 11)),
            ]),
          ),
        ),
      );
}

class _PickerCoverCard extends StatelessWidget {
  const _PickerCoverCard({
    required this.id,
    required this.name,
    required this.category,
    required this.sample,
    required this.selected,
    required this.onTap,
  });
  final String id;
  final String name;
  final String category;
  final String sample;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xfffcfdfd),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
              color: selected ? DocNoteTheme.accent : const Color(0xffd9e0e5),
              width: selected ? 2 : 1),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: EdgeInsets.all(selected ? 7 : 8),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: _NotebookCoverArt(coverId: id, title: sample),
              )),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
                child: Row(children: [
                  Expanded(
                      child: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700))),
                  Text(selected ? '선택됨' : category,
                      style: const TextStyle(
                          color: Color(0xff6c7682), fontSize: 11)),
                ]),
              ),
            ]),
          ),
        ),
      );
}

String _coverName(String id) => switch (id) {
      'work' => '소프트 세이지',
      'planner' => '코랄 플래너',
      'mood' => '라벤더 메모',
      'dark' => '잉크 다크',
      'study' => '페이퍼 샌드',
      'ocean' => '오션 블루',
      'rose' => '로즈 에디션',
      'forest' => '포레스트 그린',
      'sand' => '페이퍼 샌드',
      'violet' => '바이올렛 스터디',
      _ => '차분한 블루',
    };

class _RefinedSheetHandle extends StatelessWidget {
  const _RefinedSheetHandle({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(99)),
        ),
      );
}

class _RefinedStepIndicator extends StatelessWidget {
  const _RefinedStepIndicator();
  @override
  Widget build(BuildContext context) => Row(children: [
        for (var index = 1; index <= 3; index++) ...[
          if (index > 1)
            Expanded(
                child: Container(
                    height: 1,
                    color: Theme.of(context).colorScheme.outlineVariant)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: index == 1
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.surfaceContainerLow,
              child: Text('$index',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: index == 1
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      )),
            ),
            const SizedBox(width: 5),
            Text(switch (index) { 1 => '제목', 2 => '표지', _ => '속지' },
                style: Theme.of(context).textTheme.labelSmall),
          ]),
        ],
      ]);
}

class _RefinedChoiceRow extends StatelessWidget {
  const _RefinedChoiceRow(
      {required this.icon,
      required this.title,
      required this.description,
      required this.onTap});
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
          child: ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(description),
            trailing: const Icon(Icons.chevron_right),
          ),
        ),
      );
}

class _RefinedPaperCard extends StatelessWidget {
  const _RefinedPaperCard(
      {required this.id,
      required this.label,
      required this.group,
      required this.selected,
      required this.onTap});
  final String id;
  final String label;
  final String group;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
        side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
        child: Padding(
          padding: EdgeInsets.all(selected ? 9 : 10),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: ClipRRect(
              borderRadius: BorderRadius.circular(DocNoteTheme.radiusSm),
              child: _TemplatePaper(templateId: id),
            )),
            const SizedBox(height: 8),
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 2),
            Text(selected ? '선택됨 · $group' : group,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

class _SheetSectionHeader extends StatelessWidget {
  const _SheetSectionHeader({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      );
}

class _CoverChoice extends StatelessWidget {
  const _CoverChoice({
    required this.id,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String id;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: '$label 표지',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 86,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _NotebookCoverArt(
                    coverId: id,
                    title: label,
                    compact: true,
                  ),
                ),
              ),
              if (selected)
                Positioned(
                  top: 4,
                  right: 4,
                  child: CircleAvatar(
                    radius: 10,
                    backgroundColor: scheme.primary,
                    child: Icon(Icons.check, size: 13, color: scheme.onPrimary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TemplateChoice extends StatelessWidget {
  const _TemplateChoice({
    required this.id,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String id;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? scheme.primary
                : scheme.outlineVariant.withValues(alpha: .55),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Expanded(child: _TemplatePaper(templateId: id)),
            const SizedBox(height: 3),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

class _TemplatePaper extends StatelessWidget {
  const _TemplatePaper({required this.templateId});
  final String templateId;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _PaperPreviewPainter(templateId),
        child: const SizedBox.expand(),
      );
}

enum HomeDocumentCategory { all, memo, pdf, hwp }

class HomePage extends ConsumerStatefulWidget {
  const HomePage(
      {required this.onQuickMemo,
      required this.onImportPdf,
      required this.onImportHwp,
      required this.onSearch,
      required this.onOpenDocuments,
      super.key});
  final VoidCallback onQuickMemo;
  final VoidCallback onImportPdf;
  final VoidCallback onImportHwp;
  final VoidCallback onSearch;
  final VoidCallback onOpenDocuments;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  HomeDocumentCategory category = HomeDocumentCategory.all;
  bool grid = true;
  bool sortByLastOpened = false;

  @override
  Widget build(BuildContext context) {
    final useRefinedDesign =
        Theme.of(context).platform != TargetPlatform.fuchsia;
    if (useRefinedDesign) {
      return _RefinedHomeView(
        onQuickMemo: widget.onQuickMemo,
        onSearch: widget.onSearch,
        onOpenDocuments: widget.onOpenDocuments,
      );
    }

    // The legacy presentation below is intentionally retained during this
    // first visual migration so existing state wiring remains easy to compare.
    final docs = ref.watch(documentsProvider).where((d) => !d.trashed).toList()
      ..sort((left, right) {
        final leftDate =
            sortByLastOpened ? left.lastOpened ?? left.modified : left.modified;
        final rightDate = sortByLastOpened
            ? right.lastOpened ?? right.modified
            : right.modified;
        return rightDate.compareTo(leftDate);
      });
    final scheme = Theme.of(context).colorScheme;
    final notebooks = docs.where((document) => document.isNotebook).toList();
    final imported =
        docs.where((document) => document.isImportedDocument).toList();
    final recentDocs = imported
        .where((document) => switch (category) {
              HomeDocumentCategory.pdf => document.type == DocumentType.pdf,
              HomeDocumentCategory.hwp => document.type == DocumentType.hwp ||
                  document.type == DocumentType.hwpx,
              _ => true,
            })
        .toList();
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          toolbarHeight: 64,
          titleSpacing: 20,
          title: const Text('DocNote'),
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          actions: [
            IconButton(
                onPressed: widget.onSearch,
                tooltip: '검색',
                icon: const Icon(Icons.search_outlined)),
            const SizedBox(width: 8),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
            child: Row(
              children: [
                Expanded(
                  child: _QuickActionTile(
                    icon: Icons.note_add_outlined,
                    label: '새 노트',
                    primary: true,
                    onTap: widget.onQuickMemo,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _QuickActionTile(
                    icon: Icons.picture_as_pdf_outlined,
                    label: 'PDF 열기',
                    onTap: widget.onImportPdf,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _QuickActionTile(
                    icon: Icons.description_outlined,
                    label: 'HWP 열기',
                    onTap: widget.onImportHwp,
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: HeroFeatureSection(onCreateNotebook: widget.onQuickMemo),
        ),
        SliverToBoxAdapter(
          child: HomeNotebookSection(
            notebooks: notebooks,
            onCreate: widget.onQuickMemo,
          ),
        ),
        SliverToBoxAdapter(
          child: TemplateShortcutSection(onCreateNotebook: widget.onQuickMemo),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 16, 10),
            child: Row(
              children: [
                Text(
                  '최근 가져온 문서',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                PopupMenuButton<bool>(
                  tooltip: '정렬 기준',
                  onSelected: (value) =>
                      setState(() => sortByLastOpened = value),
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(
                      value: false,
                      checked: !sortByLastOpened,
                      child: const Text('최근 수정'),
                    ),
                    CheckedPopupMenuItem(
                      value: true,
                      checked: sortByLastOpened,
                      child: const Text('최근 열람'),
                    ),
                  ],
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      children: [
                        Text(sortByLastOpened ? '최근 열람' : '최근 수정',
                            style: Theme.of(context).textTheme.labelMedium),
                        const Icon(Icons.keyboard_arrow_down, size: 18),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => grid = !grid),
                  tooltip: grid ? '목록으로 보기' : '격자로 보기',
                  icon: Icon(grid
                      ? Icons.view_list_outlined
                      : Icons.grid_view_outlined),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      _categoryChip('전체', HomeDocumentCategory.all),
                      _categoryChip('PDF', HomeDocumentCategory.pdf),
                      _categoryChip('HWP', HomeDocumentCategory.hwp),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (recentDocs.isEmpty && notebooks.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              title: '첫 노트북을 만들어 보세요',
              message: '표지와 속지를 고르면 나만의 노트 공간이 시작됩니다.',
              icon: Icons.auto_stories_outlined,
            ),
          )
        else if (recentDocs.isEmpty)
          const SliverToBoxAdapter(child: SizedBox(height: 24))
        else if (!grid)
          SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverList.builder(
                  itemCount: recentDocs.length,
                  itemBuilder: (_, index) =>
                      DocumentTile(document: recentDocs[index])))
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.crossAxisExtent >= 620
                    ? 3
                    : recentDocs.length == 1
                        ? 1
                        : 2;
                return SliverGrid.builder(
                  itemCount: recentDocs.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: columns == 1 ? 1.18 : 0.78,
                  ),
                  itemBuilder: (_, index) =>
                      DocumentGridTile(document: recentDocs[index]),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _categoryChip(String label, HomeDocumentCategory value) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
          selectedColor: Theme.of(context).colorScheme.primary,
          labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: category == value
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
          side: BorderSide.none,
          shape: const StadiumBorder(),
          label: Text(label),
          selected: category == value,
          onSelected: (_) => setState(() => category = value),
          showCheckmark: false,
        ),
      );
}

// ignore: unused_element
class _StaticRefinedHomeView extends StatelessWidget {
  const _StaticRefinedHomeView(
      {required this.onQuickMemo,
      required this.onSearch,
      required this.onOpenDocuments});
  final VoidCallback onQuickMemo;
  final VoidCallback onSearch;
  final VoidCallback onOpenDocuments;

  static const bg = Color(0xfff7f8fa);
  static const border = Color(0xffe0e3e8);
  static const muted = Color(0xff6d7480);
  static const accent = Color(0xff3979bb);

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: bg,
        body: SafeArea(
          bottom: false,
          child: CustomScrollView(slivers: [
            SliverToBoxAdapter(child: _homeHeader()),
            SliverToBoxAdapter(child: _hero(context)),
            SliverToBoxAdapter(child: _notebooks(context)),
            SliverToBoxAdapter(child: _templates(context)),
            SliverToBoxAdapter(child: _recent(context)),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ]),
        ),
      );

  Widget _homeHeader() => SizedBox(
        height: 64,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child:
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('DocNote',
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w700, height: 1.35)),
            IconButton(
                onPressed: onSearch,
                icon: const Icon(Icons.search, size: 20),
                tooltip: '검색'),
          ]),
        ),
      );

  Widget _hero(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 720;
          return Flex(
              direction: wide ? Axis.horizontal : Axis.vertical,
              crossAxisAlignment:
                  wide ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Expanded(
                    flex: wide ? 1 : 0,
                    child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('오늘의 작업 공간',
                              style: TextStyle(
                                  color: muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  height: 1.55)),
                          SizedBox(height: 2),
                          Text('최근 작업을 이어가세요',
                              style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                  height: 1.4)),
                        ])),
                if (wide) const SizedBox(width: 32),
                Expanded(
                    flex: wide ? 1 : 0,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('노트북과 최근 문서를 빠르게 다시 엽니다.',
                              style: TextStyle(
                                  color: muted, fontSize: 13, height: 1.65)),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            _homeButton('새 노트북 만들기', onQuickMemo,
                                primary: true),
                            _homeButton('문서 둘러보기', onOpenDocuments),
                          ]),
                        ])),
              ]);
        }),
      );

  Widget _homeButton(String label, VoidCallback onTap,
          {bool primary = false}) =>
      Material(
        color: primary ? accent : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: primary ? BorderSide.none : const BorderSide(color: border),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    color: primary ? Colors.white : const Color(0xff27303d),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _section(
          String title, String action, VoidCallback onTap, Widget child) =>
      Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        height: 1.45)),
                const Spacer(),
                TextButton(
                    onPressed: onTap,
                    child: Text('$action ›',
                        style: const TextStyle(
                            color: muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600))),
              ])),
          const SizedBox(height: 4),
          child,
        ]),
      );

  Widget _notebooks(BuildContext context) => _section(
      '내 노트북',
      '모두 보기',
      onOpenDocuments,
      SizedBox(
          height: 224,
          child: LayoutBuilder(builder: (context, c) {
            final width = c.maxWidth >= 720
                ? (c.maxWidth - 56) / 3
                : (c.maxWidth * .42).clamp(140.0, 180.0);
            return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemCount: 3,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (_, i) => _notebookCard(width, i));
          })));

  Widget _notebookCard(double width, int i) {
    const titles = ['공부 기록', '프로젝트 노트', '주간 플래너'];
    const details = ['Cornell · 12페이지', '줄 노트 · 8페이지', 'Weekly · 5페이지'];
    const colors = [Color(0xffdceaf8), Color(0xffe3f0dc), Color(0xfff8e5df)];
    return SizedBox(
        width: width,
        child: Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: border)),
            clipBehavior: Clip.antiAlias,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: Container(
                      color: colors[i],
                      padding: const EdgeInsets.all(16),
                      child: Stack(children: [
                        const Align(
                            alignment: Alignment.topLeft,
                            child: Text('DOCNOTE',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1))),
                        Align(
                            alignment: Alignment.bottomLeft,
                            child: Text(titles[i],
                                style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    height: 1.4))),
                        Positioned(
                            top: 34,
                            right: 0,
                            child: SizedBox(
                                width: 48,
                                height: 72,
                                child: DecoratedBox(
                                    decoration: BoxDecoration(
                                        border: Border(
                                            top: BorderSide(
                                                color: Color(0x55607080))),
                                        gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [
                                              Colors.transparent,
                                              Color(0x22607080)
                                            ],
                                            stops: [
                                              0.1,
                                              0.11
                                            ])))))
                      ]))),
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(titles[i],
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(details[i],
                            style: const TextStyle(color: muted, fontSize: 12))
                      ])),
            ])));
  }

  Widget _templates(BuildContext context) => _section(
      '템플릿으로 시작',
      '모두 보기',
      onQuickMemo,
      SizedBox(
          height: 136,
          child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: 3,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                const labels = ['공부', '플래너', '회의'];
                const subs = ['Cornell', 'Weekly', 'Meeting note'];
                return SizedBox(
                    width: 124,
                    child: OutlinedButton(
                        onPressed: onQuickMemo,
                        style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.all(10),
                            alignment: Alignment.topLeft,
                            backgroundColor: Colors.white,
                            side: const BorderSide(color: border),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12))),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                  child: CustomPaint(
                                      painter: _PaperPainter(i),
                                      child: const SizedBox.expand())),
                              const SizedBox(height: 8),
                              Text(labels[i],
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700)),
                              Text(subs[i],
                                  style: const TextStyle(
                                      color: muted, fontSize: 11))
                            ])));
              })));

  Widget _recent(BuildContext context) => _section(
      '최근 문서',
      '문서 보기',
      onOpenDocuments,
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(children: [
            _recentTile(
                '2024_회의자료.pdf', 'PDF · 어제 오후 4:12', const Color(0xffffe9e5)),
            const SizedBox(height: 8),
            _recentTile(
                '서비스 기획안.hwpx', 'HWPX · 월요일 오전 9:40', const Color(0xffe3effb)),
          ])));

  Widget _recentTile(String title, String detail, Color color) => Container(
      height: 80,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Container(
            width: 48,
            height: 60,
            decoration: BoxDecoration(
                color: color,
                border: Border.all(color: border),
                borderRadius: BorderRadius.circular(8)),
            child: const CustomPaint(painter: _DocumentLinesPainter())),
        const SizedBox(width: 12),
        Expanded(
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              SizedBox(height: 4),
              Text(detail, style: TextStyle(color: muted, fontSize: 12))
            ])),
        Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
                color: Color(0xff3f9a70), shape: BoxShape.circle)),
        const SizedBox(width: 12),
        const Icon(Icons.more_horiz, size: 20),
      ]));
}

class _PaperPainter extends CustomPainter {
  _PaperPainter(this.kind);
  final int kind;
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..color = const Color(0xffd6dce3)
      ..strokeWidth = 1;
    for (var y = 12.0; y < s.height - 4; y += kind == 1 ? 22 : 12) {
      c.drawLine(Offset(10, y), Offset(s.width - 10, y), p);
    }
    if (kind == 0) {
      c.drawLine(const Offset(36, 12), Offset(36, s.height - 12), p);
    }
    if (kind == 2) {
      c.drawCircle(Offset(s.width - 18, s.height - 14), 3, p);
    }
  }

  @override
  bool shouldRepaint(covariant _PaperPainter old) => false;
}

class _DocumentLinesPainter extends CustomPainter {
  const _DocumentLinesPainter();
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..color = const Color(0x996d7480)
      ..strokeWidth = 2;
    for (var y = 14.0; y < s.height - 8; y += 9) {
      c.drawLine(Offset(8, y), Offset(s.width - 8, y), p);
    }
  }

  @override
  bool shouldRepaint(covariant _DocumentLinesPainter old) => false;
}

class _RefinedHomeView extends ConsumerStatefulWidget {
  const _RefinedHomeView({
    required this.onQuickMemo,
    required this.onSearch,
    required this.onOpenDocuments,
  });
  final VoidCallback onQuickMemo;
  final VoidCallback onSearch;
  final VoidCallback onOpenDocuments;

  @override
  ConsumerState<_RefinedHomeView> createState() => _RefinedHomeViewState();
}

class _RefinedHomeViewState extends ConsumerState<_RefinedHomeView> {
  @override
  Widget build(BuildContext context) {
    final documents = ref
        .watch(documentsProvider)
        .where((document) => !document.trashed)
        .toList()
      ..sort((left, right) => right.modified.compareTo(left.modified));
    final notebooks =
        documents.where((document) => document.isNotebook).toList();
    final recent = documents.take(4).toList();
    return Scaffold(
      backgroundColor: const Color(0xfff5f6f9),
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
                child: _RefinedHeader(onSearch: widget.onSearch)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _RefinedHomeHero(
                  onCreate: widget.onQuickMemo,
                  onOpenDocuments: widget.onOpenDocuments,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: _RefinedSection(
                title: '내 노트북',
                action: '모두 보기',
                onAction: widget.onOpenDocuments,
                child: SizedBox(
                  height: 224,
                  child: notebooks.isEmpty
                      ? _RefinedCreateNotebook(onTap: widget.onQuickMemo)
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final contentWidth = constraints.maxWidth - 32;
                            final cardWidth = constraints.maxWidth >= 720
                                ? (contentWidth - 24) / 3
                                : (contentWidth * .42).clamp(140.0, 180.0);
                            return ListView.separated(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              scrollDirection: Axis.horizontal,
                              itemCount: notebooks.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: 12),
                              itemBuilder: (_, index) => _RefinedNotebookCard(
                                document: notebooks[index],
                                index: index,
                                width: cardWidth,
                                compact: false,
                              ),
                            );
                          },
                        ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: _RefinedSection(
                title: '템플릿으로 시작',
                action: '모두 보기',
                onAction: widget.onQuickMemo,
                child: _RefinedTemplateRow(onTap: widget.onQuickMemo),
              ),
            ),
            SliverToBoxAdapter(
              child: _RefinedSection(
                title: '최근 문서',
                action: '문서 보기',
                onAction: widget.onOpenDocuments,
                child: recent.isEmpty
                    ? const EmptyState(
                        title: '최근 문서가 없습니다',
                        message: 'PDF 또는 HWP 문서를 가져오면 여기에 표시됩니다.',
                        icon: Icons.description_outlined,
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          children: [
                            for (final document in recent)
                              _RefinedHomeDocumentTile(document: document),
                          ],
                        ),
                      ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }
}

class _RefinedHeader extends StatelessWidget {
  const _RefinedHeader({required this.onSearch});
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 64,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'DocNote',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                      letterSpacing: 0,
                    ),
              ),
              Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(22),
                child: InkWell(
                  onTap: onSearch,
                  borderRadius: BorderRadius.circular(22),
                  child: const SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(Icons.search_outlined, size: 20),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class _RefinedHomeHero extends StatelessWidget {
  const _RefinedHomeHero(
      {required this.onCreate, required this.onOpenDocuments});
  final VoidCallback onCreate;
  final VoidCallback onOpenDocuments;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('오늘의 작업 공간',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.55,
                  fontWeight: FontWeight.w600,
                )),
            const SizedBox(height: 0),
            const Text(
              '최근 작업을 이어가세요',
              style: TextStyle(
                  fontSize: 24, height: 1.4, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text('노트북과 최근 문서를 빠르게 다시 엽니다.',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.65,
            )),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _HomeActionButton(
                label: '새 노트북 만들기', primary: true, onTap: onCreate),
            _HomeActionButton(label: '문서 둘러보기', onTap: onOpenDocuments),
          ],
        ),
      ],
    );
  }
}

class _HomeActionButton extends StatelessWidget {
  const _HomeActionButton(
      {required this.label, required this.onTap, this.primary = false});
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: primary ? scheme.primary : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: primary
            ? BorderSide.none
            : BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: Text(label,
                  style: TextStyle(
                    color: primary ? Colors.white : scheme.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  )),
            ),
          ),
        ),
      ),
    );
  }
}

class _RefinedSection extends StatelessWidget {
  const _RefinedSection({
    required this.title,
    required this.action,
    required this.onAction,
    required this.child,
  });
  final String title;
  final String action;
  final VoidCallback onAction;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 17,
                          height: 1.45,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onAction,
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 44,
                        child: Center(
                            child: Text('$action ›',
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600))),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      );
}

class _RefinedHomeDocumentTile extends ConsumerWidget {
  const _RefinedHomeDocumentTile({required this.document});
  final DocumentItem document;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, label) = switch (document.type) {
      DocumentType.pdf => (Icons.picture_as_pdf, scheme.error, 'PDF'),
      DocumentType.hwp || DocumentType.hwpx => (
          Icons.description_outlined,
          scheme.primary,
          'HWPX'
        ),
      DocumentType.drawingNote => (
          Icons.draw_outlined,
          scheme.tertiary,
          '필기 노트'
        ),
      _ => (Icons.note_alt_outlined, scheme.secondary, '메모'),
    };
    final title = document.title.trim().isEmpty ? '새 메모' : document.title;
    final time =
        '${document.modified.hour.toString().padLeft(2, '0')}:${document.modified.minute.toString().padLeft(2, '0')}';
    final details = document.pageCount > 0
        ? '$label · ${document.pageCount}페이지 · $time'
        : '$label · $time';

    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .7)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Container(
        constraints: const BoxConstraints(minHeight: 80),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        child: InkWell(
          onTap: () => openDocument(context, document, ref),
          borderRadius: BorderRadius.circular(8),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                height: 60,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: DocumentThumbnail(
                    document: document,
                    icon: icon,
                    color: color,
                    label: label,
                    compact: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          height: 1.55,
                          color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    color: scheme.primary, shape: BoxShape.circle),
              ),
              PopupMenuButton<String>(
                tooltip: '문서 메뉴',
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.more_horiz, size: 20),
                onSelected: (value) {
                  if (value == 'rename') {
                    _rename(context, ref);
                  } else if (value == 'favorite') {
                    document.favorite = !document.favorite;
                    document.modified = DateTime.now();
                    ref.read(documentsProvider.notifier).update(document);
                  } else if (value == 'trash') {
                    ref.read(documentsProvider.notifier).remove(document.id);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'favorite', child: Text('즐겨찾기')),
                  PopupMenuItem(value: 'rename', child: Text('이름 변경')),
                  PopupMenuItem(value: 'trash', child: Text('휴지통으로 이동')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: document.title);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('문서 이름 변경'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '문서 이름'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('저장')),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;
    document.title = trimmed;
    document.modified = DateTime.now();
    await ref.read(documentsProvider.notifier).update(document);
  }
}

class _RefinedNotebookCard extends ConsumerWidget {
  // ignore: unused_element_parameter
  const _RefinedNotebookCard(
      {required this.document,
      required this.index,
      this.width = 150,
      this.compact = false});
  final DocumentItem document;
  final int index;
  final double width;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
        width: width,
        height: compact ? 140 : 224,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
            side:
                BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => openDocument(context, document, ref),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _RefinedNotebookCover(
                      document: document, index: index, compact: compact),
                ),
                SizedBox(
                  height: compact ? 52 : 68,
                  child: Padding(
                    padding: EdgeInsets.all(compact ? 8 : 12),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.topLeft,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              document.title.trim().isEmpty
                                  ? '새 노트'
                                  : document.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: compact ? 12 : 14,
                                height: 1.5,
                                fontWeight: FontWeight.w600,
                              )),
                          SizedBox(height: compact ? 1 : 3),
                          Text(
                              '${_templateLabel(document.pageStyle)} · ${document.pageCount}페이지',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: compact ? 10 : 12,
                                height: 1.55,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              )),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _RefinedCreateNotebook extends StatelessWidget {
  const _RefinedCreateNotebook({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.add),
          label: const Text('첫 노트북 만들기'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(184, 156),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
            ),
          ),
        ),
      );
}

class _RefinedNotebookCover extends StatelessWidget {
  const _RefinedNotebookCover(
      {required this.document, required this.index, this.compact = false});
  final DocumentItem document;
  final int index;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = switch (document.coverId == 'simple' ? index : -1) {
      1 => (const Color(0xffd9ebc5), const Color(0xff44642f)),
      2 => (const Color(0xffffd8d5), const Color(0xff914c49)),
      _ => switch (document.coverId) {
          'work' => (const Color(0xffd9ebc5), const Color(0xff44642f)),
          'planner' => (const Color(0xffffd8d5), const Color(0xff914c49)),
          'study' => (const Color(0xffcfe5f8), const Color(0xff28618a)),
          'dark' => (const Color(0xff35475a), Colors.white),
          _ => (const Color(0xffcfe5f8), const Color(0xff28618a)),
        },
    };
    final title = document.title.trim().isEmpty ? '새 노트' : document.title;
    return Container(
      color: palette.$1,
      child: Stack(
        children: [
          Positioned(
            left: compact ? 9 : 16,
            top: compact ? 9 : 16,
            child: Text('DOCNOTE',
                style: TextStyle(
                  color: palette.$2,
                  fontSize: compact ? 6 : 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .08 * (compact ? 8 : 1),
                )),
          ),
          Positioned(
            top: compact ? 28 : 50,
            right: compact ? 9 : 16,
            child: SizedBox(
              width: compact ? 30 : 48,
              height: compact ? 36 : 72,
              child: Column(
                children: List.generate(
                    5,
                    (index) => Expanded(
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: Container(
                                height: 1,
                                color: palette.$2.withValues(alpha: .32)),
                          ),
                        )),
              ),
            ),
          ),
          Positioned(
            left: compact ? 9 : 16,
            right: compact ? 9 : 16,
            bottom: compact ? 9 : 16,
            child: Text(title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: palette.$2,
                    fontSize: compact ? 11 : 18,
                    height: 1.4,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _RefinedTemplateRow extends StatelessWidget {
  const _RefinedTemplateRow({required this.onTap});
  final VoidCallback onTap;
  static const templates = <(String, String, IconData)>[
    ('공부', 'Cornell', Icons.school_outlined),
    ('플래너', 'Weekly', Icons.calendar_today_outlined),
    ('회의', 'Meeting note', Icons.groups_outlined),
  ];

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 136,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          scrollDirection: Axis.horizontal,
          itemCount: templates.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, index) {
            final template = templates[index];
            return SizedBox(
              width: 124,
              child: OutlinedButton(
                onPressed: onTap,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.all(10),
                  alignment: Alignment.topLeft,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _TemplatePaper(
                        templateId: switch (template.$2) {
                          'Cornell' => 'cornell',
                          'Weekly' => 'weekly',
                          _ => 'meeting',
                        },
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(template.$1,
                        style: Theme.of(context).textTheme.labelLarge),
                    Text(template.$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            )),
                  ],
                ),
              ),
            );
          },
        ),
      );
}

class HeroFeatureSection extends StatelessWidget {
  const HeroFeatureSection({required this.onCreateNotebook, super.key});
  final VoidCallback onCreateNotebook;

  static const features = <({
    String title,
    String subtitle,
    IconData icon,
    Color color,
    Color ink,
  })>[
    (
      title: '나만의 무한 캔버스',
      subtitle: '생각을 자유롭게 펼쳐 보세요',
      icon: Icons.draw_outlined,
      color: Color(0xffdcecf8),
      ink: Color(0xff245b86),
    ),
    (
      title: '표지와 속지 선택',
      subtitle: '내 방식에 맞는 노트북 만들기',
      icon: Icons.auto_stories_outlined,
      color: Color(0xfff5e8c7),
      ink: Color(0xff775b32),
    ),
    (
      title: '필기와 문서 작업',
      subtitle: 'PDF와 메모를 한 곳에서',
      icon: Icons.layers_outlined,
      color: Color(0xffe9e4f4),
      ink: Color(0xff5c4d7d),
    ),
  ];

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: SizedBox(
          height: 126,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: features.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, index) {
              final feature = features[index];
              return _HeroFeatureCard(
                title: feature.title,
                subtitle: feature.subtitle,
                icon: feature.icon,
                color: feature.color,
                ink: feature.ink,
                onTap: index == 1 ? onCreateNotebook : null,
              );
            },
          ),
        ),
      );
}

class _HeroFeatureCard extends StatelessWidget {
  const _HeroFeatureCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.ink,
    this.onTap,
  });
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Color ink;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: color,
        borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
          child: SizedBox(
            width: 226,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Stack(
                children: [
                  Align(
                    alignment: Alignment.topRight,
                    child:
                        Icon(icon, size: 42, color: ink.withValues(alpha: .72)),
                  ),
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: ink,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            )),
                        const SizedBox(height: 5),
                        Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: ink.withValues(alpha: .72),
                              fontSize: 12,
                            )),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

class TemplateShortcutSection extends StatelessWidget {
  const TemplateShortcutSection({required this.onCreateNotebook, super.key});
  final VoidCallback onCreateNotebook;

  static const shortcuts = <({String label, String template, IconData icon})>[
    (label: '공부', template: 'Cornell', icon: Icons.school_outlined),
    (label: '플래너', template: 'Daily planner', icon: Icons.today_outlined),
    (label: '회의', template: 'Meeting notes', icon: Icons.groups_outlined),
    (label: '모눈', template: 'Grid', icon: Icons.grid_4x4_outlined),
  ];

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('템플릿으로 시작',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton(
                    onPressed: onCreateNotebook, child: const Text('모두 보기')),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 78,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: shortcuts.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, index) {
                  final shortcut = shortcuts[index];
                  return _TemplateShortcut(
                    label: shortcut.label,
                    template: shortcut.template,
                    icon: shortcut.icon,
                    onTap: onCreateNotebook,
                  );
                },
              ),
            ),
          ],
        ),
      );
}

class _TemplateShortcut extends StatelessWidget {
  const _TemplateShortcut({
    required this.label,
    required this.template,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final String template;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(DocNoteTheme.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DocNoteTheme.radiusSm),
        child: Container(
          width: 118,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(DocNoteTheme.radiusSm),
            border:
                Border.all(color: scheme.outlineVariant.withValues(alpha: .45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: scheme.primary),
              const Spacer(),
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              Text(template,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      )),
            ],
          ),
        ),
      ),
    );
  }
}

class HomeNotebookSection extends ConsumerWidget {
  const HomeNotebookSection({
    required this.notebooks,
    required this.onCreate,
    super.key,
  });
  final List<DocumentItem> notebooks;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('내 노트북', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                TextButton.icon(
                  onPressed: onCreate,
                  icon: const Icon(Icons.add, size: 17),
                  label: const Text('새 노트'),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              notebooks.isEmpty
                  ? '표지와 속지를 골라 첫 노트북을 만들어 보세요.'
                  : '나만의 표지와 속지로 정리한 노트입니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 13),
            SizedBox(
              height: 236,
              child: notebooks.isEmpty
                  ? _CreateNotebookCard(onTap: onCreate)
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: notebooks.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 14),
                      itemBuilder: (_, index) => SizedBox(
                        width: 154,
                        child: NotebookCard(document: notebooks[index]),
                      ),
                    ),
            ),
          ],
        ),
      );
}

class _CreateNotebookCard extends StatelessWidget {
  const _CreateNotebookCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
        child: Container(
          width: 154,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
            border: Border.all(color: scheme.primary.withValues(alpha: .20)),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: .10),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.add, color: scheme.primary),
            ),
            const SizedBox(height: 12),
            Text('새 노트북', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text('표지 · 속지 선택',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    )),
          ]),
        ),
      ),
    );
  }
}

class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: primary ? scheme.primary : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
        child: Container(
          height: 68,
          decoration: BoxDecoration(
            color: primary ? scheme.primary : scheme.surface,
            borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.045),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: primary
                      ? scheme.onPrimary.withValues(alpha: .16)
                      : scheme.primary.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Icon(icon,
                      color: primary ? scheme.onPrimary : scheme.primary,
                      size: 19),
                ),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: primary ? scheme.onPrimary : scheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DocumentsPage extends ConsumerStatefulWidget {
  const DocumentsPage({super.key});

  @override
  ConsumerState<DocumentsPage> createState() => _DocumentsPageState();
}

class _DocumentsPageState extends ConsumerState<DocumentsPage> {
  HomeDocumentCategory category = HomeDocumentCategory.all;
  bool grid = true;

  @override
  Widget build(BuildContext context) {
    final useRefinedDesign =
        Theme.of(context).platform != TargetPlatform.fuchsia;
    if (useRefinedDesign) return _RefinedDocumentsView();

    // Legacy list/grid presentation retained below for a low-risk rollback.
    final docs = ref.watch(documentsProvider).where((d) {
      if (d.trashed) return false;
      return switch (category) {
        HomeDocumentCategory.all => true,
        HomeDocumentCategory.memo =>
          d.type == DocumentType.textNote || d.type == DocumentType.drawingNote,
        HomeDocumentCategory.pdf => d.type == DocumentType.pdf,
        HomeDocumentCategory.hwp =>
          d.type == DocumentType.hwp || d.type == DocumentType.hwpx,
      };
    }).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('문서'), actions: [
        IconButton(
            onPressed: () => setState(() => grid = !grid),
            tooltip: grid ? '목록으로 보기' : '격자로 보기',
            icon: Icon(
                grid ? Icons.view_list_outlined : Icons.grid_view_outlined)),
        const SizedBox(width: 8),
      ]),
      body: Column(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(children: [
            _categoryChip('전체', HomeDocumentCategory.all),
            _categoryChip('메모', HomeDocumentCategory.memo),
            _categoryChip('PDF', HomeDocumentCategory.pdf),
            _categoryChip('HWP', HomeDocumentCategory.hwp),
          ]),
        ),
        Expanded(
          child: docs.isEmpty
              ? EmptyState.forCategory(category)
              : grid
                  ? LayoutBuilder(
                      builder: (context, constraints) {
                        final columns = constraints.maxWidth >= 620
                            ? 3
                            : docs.length == 1
                                ? 1
                                : 2;
                        return GridView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 16,
                            childAspectRatio: columns == 1 ? 1.18 : 0.78,
                          ),
                          itemCount: docs.length,
                          itemBuilder: (_, i) => docs[i].isNotebook
                              ? NotebookCard(document: docs[i])
                              : DocumentGridTile(document: docs[i]),
                        );
                      },
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      itemCount: docs.length,
                      itemBuilder: (_, i) => DocumentTile(document: docs[i]),
                    ),
        ),
      ]),
    );
  }

  Widget _categoryChip(String label, HomeDocumentCategory value) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
          selectedColor: Theme.of(context).colorScheme.primary,
          labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: category == value
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
          side: BorderSide.none,
          shape: const StadiumBorder(),
          label: Text(label),
          selected: category == value,
          onSelected: (_) => setState(() => category = value),
          showCheckmark: false,
        ),
      );
}

class _RefinedDocumentsView extends ConsumerStatefulWidget {
  const _RefinedDocumentsView();

  @override
  ConsumerState<_RefinedDocumentsView> createState() =>
      _RefinedDocumentsViewState();
}

class _RefinedDocumentsViewState extends ConsumerState<_RefinedDocumentsView> {
  HomeDocumentCategory category = HomeDocumentCategory.all;
  bool grid = false;

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(documentsProvider).where((document) {
      if (document.trashed) return false;
      return switch (category) {
        HomeDocumentCategory.all => true,
        HomeDocumentCategory.memo => document.type == DocumentType.textNote ||
            document.type == DocumentType.drawingNote,
        HomeDocumentCategory.pdf => document.type == DocumentType.pdf,
        HomeDocumentCategory.hwp => document.type == DocumentType.hwp ||
            document.type == DocumentType.hwpx,
      };
    }).toList();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('문서'),
        actions: [
          IconButton(
            onPressed: () => setState(() => grid = !grid),
            tooltip: grid ? '목록으로 보기' : '격자로 보기',
            icon: Icon(
                grid ? Icons.view_list_outlined : Icons.grid_view_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('문서 보관함 · ${docs.length}개',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    )),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
            child: Row(children: [
              _refinedChip('전체', HomeDocumentCategory.all),
              _refinedChip('메모', HomeDocumentCategory.memo),
              _refinedChip('PDF', HomeDocumentCategory.pdf),
              _refinedChip('HWP', HomeDocumentCategory.hwp),
            ]),
          ),
          Expanded(
            child: docs.isEmpty
                ? EmptyState.forCategory(category)
                : grid
                    ? GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 360,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                          childAspectRatio: .9,
                        ),
                        itemCount: docs.length,
                        itemBuilder: (_, index) =>
                            DocumentGridTile(document: docs[index]),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                        itemCount: docs.length,
                        itemBuilder: (_, index) =>
                            _RefinedDocumentListCard(document: docs[index]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _refinedChip(String label, HomeDocumentCategory value) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: category == value,
          onSelected: (_) => setState(() => category = value),
          showCheckmark: false,
          side: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          backgroundColor: Colors.transparent,
          selectedColor: Theme.of(context).colorScheme.onSurface,
          labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: category == value
                    ? Theme.of(context).colorScheme.surface
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
}

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({required this.onClose, super.key});
  final VoidCallback onClose;
  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  String query = '';
  DocumentType? typeFilter;
  bool favoritesOnly = false;
  @override
  Widget build(BuildContext context) {
    final useRefinedDesign =
        Theme.of(context).platform != TargetPlatform.fuchsia;
    if (useRefinedDesign) return _RefinedSearchView(onClose: widget.onClose);

    // Legacy search presentation retained below for a low-risk rollback.
    final docs = ref
        .watch(documentsProvider)
        .where((d) => !d.trashed)
        .where((d) => d.title.contains(query) || d.body.contains(query))
        .where((d) => typeFilter == null || d.type == typeFilter)
        .where((d) => !favoritesOnly || d.favorite)
        .toList();
    return Scaffold(
        appBar: AppBar(title: const Text('검색')),
        body: Column(children: [
          Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                  onChanged: (value) => setState(() => query = value),
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '문서 검색',
                      border: OutlineInputBorder()))),
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                ChoiceChip(
                    label: const Text('전체'),
                    selected: typeFilter == null && !favoritesOnly,
                    onSelected: (_) => setState(() {
                          typeFilter = null;
                          favoritesOnly = false;
                        })),
                const SizedBox(width: 8),
                ChoiceChip(
                    label: const Text('즐겨찾기'),
                    selected: favoritesOnly,
                    onSelected: (value) => setState(() {
                          favoritesOnly = value;
                          if (value) typeFilter = null;
                        })),
                const SizedBox(width: 8),
                ChoiceChip(
                    label: const Text('메모'),
                    selected: typeFilter == DocumentType.textNote,
                    onSelected: (value) => setState(() {
                          typeFilter = value ? DocumentType.textNote : null;
                          favoritesOnly = false;
                        })),
                const SizedBox(width: 8),
                ChoiceChip(
                    label: const Text('PDF'),
                    selected: typeFilter == DocumentType.pdf,
                    onSelected: (value) => setState(() {
                          typeFilter = value ? DocumentType.pdf : null;
                          favoritesOnly = false;
                        })),
                const SizedBox(width: 8),
                ChoiceChip(
                    label: const Text('필기'),
                    selected: typeFilter == DocumentType.drawingNote,
                    onSelected: (value) => setState(() {
                          typeFilter = value ? DocumentType.drawingNote : null;
                          favoritesOnly = false;
                        })),
              ])),
          Expanded(
            child: docs.isEmpty
                ? const EmptyState(
                    title: '검색 결과가 없습니다',
                    message: '다른 제목이나 메모 내용으로 검색해 보세요.',
                    icon: Icons.search_off_outlined,
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: docs.length,
                    itemBuilder: (_, index) =>
                        DocumentTile(document: docs[index]),
                  ),
          )
        ]));
  }
}

class _RefinedSearchView extends ConsumerStatefulWidget {
  const _RefinedSearchView({required this.onClose});
  final VoidCallback onClose;

  @override
  ConsumerState<_RefinedSearchView> createState() => _RefinedSearchViewState();
}

class _RefinedSearchViewState extends ConsumerState<_RefinedSearchView> {
  String query = '';
  DocumentType? typeFilter;
  bool favoritesOnly = false;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref
        .watch(documentsProvider)
        .where((document) => !document.trashed)
        .where((document) =>
            document.title.contains(query) || document.body.contains(query))
        .where((document) => typeFilter == null || document.type == typeFilter)
        .where((document) => !favoritesOnly || document.favorite)
        .toList();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('검색'),
        actions: [
          IconButton(
            onPressed: widget.onClose,
            tooltip: '검색 닫기',
            icon: const Icon(Icons.close_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '노트북, 문서, 메모 검색',
                prefixIcon: const Icon(Icons.search_outlined),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '검색어 지우기',
                        onPressed: () {
                          _searchController.clear();
                          setState(() => query = '');
                        },
                        icon: const Icon(Icons.close, size: 18),
                      ),
                filled: true,
                fillColor: scheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
                  borderSide: BorderSide(color: scheme.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
                  borderSide: BorderSide(color: scheme.outlineVariant),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
                  borderSide: BorderSide(color: scheme.primary, width: 1.4),
                ),
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(children: [
              _searchChip('전체', null, false),
              _searchChip('즐겨찾기', null, true),
              _searchChip('메모', DocumentType.textNote, false),
              _searchChip('PDF', DocumentType.pdf, false),
              _searchChip('필기', DocumentType.drawingNote, false),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Row(
              children: [
                Text('최근 검색 결과',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text('${docs.length}개',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        )),
              ],
            ),
          ),
          Expanded(
            child: docs.isEmpty
                ? const EmptyState(
                    title: '검색 결과가 없습니다',
                    message: '다른 키워드로 다시 검색해 보세요.',
                    icon: Icons.search_off_outlined,
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: docs.length,
                    itemBuilder: (_, index) =>
                        _RefinedDocumentListCard(document: docs[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _searchChip(String label, DocumentType? type, bool favorite) =>
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: typeFilter == type && favoritesOnly == favorite,
          onSelected: (_) => setState(() {
            typeFilter = type;
            favoritesOnly = favorite;
          }),
          showCheckmark: false,
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          backgroundColor: Colors.transparent,
          selectedColor: Theme.of(context).colorScheme.onSurface,
          labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: typeFilter == type && favoritesOnly == favorite
                    ? Theme.of(context).colorScheme.surface
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
}

class SettingsPage extends ConsumerWidget {
  const SettingsPage({required this.onClose, super.key});
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useRefinedDesign =
        Theme.of(context).platform != TargetPlatform.fuchsia;
    if (useRefinedDesign) return _RefinedSettingsView(onClose: onClose);

    // Legacy settings list retained below for a low-risk rollback.
    final settings = ref.watch(appSettingsProvider);
    final controller = ref.read(appSettingsProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(children: [
        ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('테마 설정'),
            subtitle: Text(_themeLabel(settings.theme)),
            onTap: () => _selectTheme(context, settings.theme, controller)),
        SwitchListTile(
            secondary: const Icon(Icons.save_outlined),
            title: const Text('자동 저장'),
            subtitle: Text(
                settings.autoSave ? '변경 사항을 자동으로 저장합니다.' : '자동 저장이 꺼져 있습니다.'),
            value: settings.autoSave,
            onChanged: controller.setAutoSave),
        ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('휴지통'),
            subtitle: Text(
                '${ref.watch(documentsProvider).where((d) => d.trashed).length}개 문서'),
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const TrashPage()))),
        const StorageInfoTile(),
        const AboutListTile(
            applicationName: 'DocNote',
            applicationVersion: '0.1.0',
            icon: Icon(Icons.info_outline),
            aboutBoxChildren: [Text('문서와 필기를 한 곳에서 관리하는 노트 앱입니다.')]),
      ]),
    );
  }

  String _themeLabel(AppThemeChoice choice) => switch (choice) {
        AppThemeChoice.system => '시스템 설정 따름',
        AppThemeChoice.light => '라이트 모드',
        AppThemeChoice.dark => '다크 모드',
      };

  Future<void> _selectTheme(BuildContext context, AppThemeChoice current,
      AppSettingsController controller) async {
    final selected = await showDialog<AppThemeChoice>(
        context: context,
        builder: (_) => SimpleDialog(
              title: const Text('테마 설정'),
              children: [
                for (final choice in AppThemeChoice.values)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, choice),
                    child: Row(children: [
                      Icon(choice == current
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked),
                      const SizedBox(width: 12),
                      Text(_themeLabel(choice)),
                    ]),
                  ),
              ],
            ));
    if (selected != null) await controller.setTheme(selected);
  }
}

class _RefinedSettingsView extends ConsumerWidget {
  const _RefinedSettingsView({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final controller = ref.read(appSettingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: DocNoteTheme.page,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    height: 64,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('설정',
                            style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                height: 1.35)),
                        Tooltip(
                          message: '설정 닫기',
                          child: InkWell(
                            onTap: onClose,
                            borderRadius: BorderRadius.circular(22),
                            child: const SizedBox(
                              width: 44,
                              height: 44,
                              child: Center(
                                  child: Text('×',
                                      style: TextStyle(fontSize: 22))),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                  child: Text('DocNote를 사용하는 방식과 저장 환경을 관리합니다.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontSize: 14,
                            height: 1.7,
                          )),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _RefinedSettingsGroup(
                    title: '사용 환경',
                    children: [
                      _RefinedSettingsRow(
                        icon: '◐',
                        title: '화면 테마',
                        subtitle: '기기 설정에 맞춤',
                        trailing: Text(_refinedThemeLabel(settings.theme),
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                )),
                        onTap: () => _selectRefinedTheme(
                            context, settings.theme, controller),
                      ),
                      _RefinedSettingsRow(
                        icon: '✓',
                        title: '자동 저장',
                        subtitle: '변경 사항을 자동으로 저장합니다',
                        trailing: _DesignSwitch(
                          value: settings.autoSave,
                          onChanged: controller.setAutoSave,
                        ),
                        onTap: () => controller.setAutoSave(!settings.autoSave),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _RefinedSettingsGroup(
                    title: '문서 관리',
                    children: [
                      _RefinedSettingsRow(
                        icon: '⌫',
                        title: '휴지통',
                        subtitle: '삭제한 문서를 확인합니다',
                        trailing: const _SettingsChevron(),
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const TrashPage())),
                      ),
                      _RefinedStorageRow(),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _RefinedSettingsGroup(
                    title: 'DocNote 정보',
                    children: [
                      _RefinedSettingsRow(
                        icon: 'i',
                        title: '앱 정보',
                        subtitle: 'DocNote 버전과 도움말',
                        trailing: const _SettingsChevron(),
                        onTap: () => showAboutDialog(
                          context: context,
                          applicationName: 'DocNote',
                          applicationVersion: '0.1.0',
                          children: const [Text('문서와 필기를 한 곳에서 관리하는 노트 앱입니다.')],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _refinedThemeLabel(AppThemeChoice choice) => switch (choice) {
        AppThemeChoice.system => '시스템',
        AppThemeChoice.light => '라이트',
        AppThemeChoice.dark => '다크',
      };

  Future<void> _selectRefinedTheme(BuildContext context, AppThemeChoice current,
      AppSettingsController controller) async {
    final selected = await showDialog<AppThemeChoice>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('화면 테마'),
        children: [
          for (final choice in AppThemeChoice.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, choice),
              child: Row(children: [
                Icon(choice == current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                const SizedBox(width: 12),
                Text(_refinedThemeLabel(choice)),
              ]),
            ),
        ],
      ),
    );
    if (selected != null) await controller.setTheme(selected);
  }
}

class _RefinedSettingsGroup extends StatelessWidget {
  const _RefinedSettingsGroup({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontSize: 17,
                      height: 1.45,
                    )),
            const SizedBox(height: 12),
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Column(
                children: [
                  for (var index = 0; index < children.length; index++) ...[
                    children[index],
                    if (index < children.length - 1)
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
}

class _RefinedSettingsRow extends StatelessWidget {
  const _RefinedSettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.onTap,
  });
  final String icon;
  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 68),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xfff1f2f4),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(icon,
                      style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: icon == 'i' ? 16 : 15,
                          fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 14,
                              height: 1.5,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                              height: 1.5)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RefinedStorageRow extends StatelessWidget {
  const _RefinedStorageRow();

  @override
  Widget build(BuildContext context) => _RefinedSettingsRow(
        icon: '▤',
        title: '저장 공간',
        subtitle: '현재 기기에 저장된 문서',
        trailing: const _SettingsChevron(),
      );
}

class _SettingsChevron extends StatelessWidget {
  const _SettingsChevron();

  @override
  Widget build(BuildContext context) => Text('›',
      style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 18,
          fontWeight: FontWeight.w600));
}

class _DesignSwitch extends StatelessWidget {
  const _DesignSwitch({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
        toggled: value,
        label: '자동 저장',
        child: GestureDetector(
          onTap: () => onChanged(!value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 44,
            height: 26,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: value ? DocNoteTheme.accent : const Color(0xffe2e5e9),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Align(
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: const SizedBox(
                width: 20,
                height: 20,
                child: DecoratedBox(
                    decoration: BoxDecoration(
                        color: Colors.white, shape: BoxShape.circle)),
              ),
            ),
          ),
        ),
      );
}

class StorageInfoTile extends StatelessWidget {
  const StorageInfoTile({super.key});
  @override
  Widget build(BuildContext context) => FutureBuilder<int>(
        future: _storageBytes(),
        builder: (context, snapshot) => ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: const Text('저장 공간'),
          subtitle:
              Text(snapshot.hasData ? _formatBytes(snapshot.data!) : '계산 중...'),
        ),
      );
}

Future<int> _storageBytes() async {
  final root = await getApplicationDocumentsDirectory();
  var total = 0;
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File) total += await entity.length();
  }
  return total;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B 사용 중';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB 사용 중';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB 사용 중';
}

class TrashPage extends ConsumerWidget {
  const TrashPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final documents =
        ref.watch(documentsProvider).where((d) => d.trashed).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('휴지통')),
      body: documents.isEmpty
          ? const Center(child: Text('휴지통이 비어 있습니다.'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: documents.length,
              itemBuilder: (_, index) {
                final document = documents[index];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title:
                        Text(document.title.isEmpty ? '새 메모' : document.title),
                    subtitle: const Text('휴지통에 보관됨'),
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) async {
                        final controller = ref.read(documentsProvider.notifier);
                        if (value == 'restore') {
                          await controller.restoreFromTrash(document.id);
                        } else if (value == 'delete') {
                          await controller.permanentlyRemove(document.id);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'restore', child: Text('복원')),
                        PopupMenuItem(value: 'delete', child: Text('영구 삭제')),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class DocumentTile extends ConsumerWidget {
  const DocumentTile({required this.document, super.key});
  final DocumentItem document;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, typeLabel) = switch (document.type) {
      DocumentType.pdf => (Icons.picture_as_pdf, scheme.error, 'PDF'),
      DocumentType.hwp || DocumentType.hwpx => (
          Icons.description,
          scheme.primary,
          'HWP'
        ),
      DocumentType.drawingNote => (Icons.draw, scheme.tertiary, '필기 노트'),
      _ => (Icons.note_alt_outlined, scheme.secondary, '메모'),
    };
    final preview = document.body.trim().isEmpty
        ? (document.title.trim().isEmpty ? '새 메모' : document.title)
        : document.body.trim().split('\n').first;
    final time =
        '${document.modified.hour.toString().padLeft(2, '0')}:${document.modified.minute.toString().padLeft(2, '0')}';
    final details = document.type == DocumentType.pdf && document.pageCount > 0
        ? '$typeLabel · ${document.pageCount}페이지 · $time'
        : '$typeLabel · $time';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .72)),
      ),
      child: ListTile(
        minVerticalPadding: 10,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 48,
            height: 60,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(DocNoteTheme.radiusSm),
              child: DocumentThumbnail(
                document: document,
                icon: icon,
                color: color,
                label: typeLabel,
                compact: true,
              ),
            ),
          ),
        ),
        title: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(details),
        onTap: () => openDocument(context, document, ref),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: .72),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              tooltip: '문서 메뉴',
              onSelected: (value) {
                if (value == 'rename') _rename(context, ref);
                if (value == 'favorite') {
                  document.favorite = !document.favorite;
                  document.modified = DateTime.now();
                  ref.read(documentsProvider.notifier).update(document);
                }
                if (value == 'trash') {
                  ref.read(documentsProvider.notifier).remove(document.id);
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('문서를 휴지통으로 이동했습니다.')));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'favorite', child: Text('즐겨찾기')),
                PopupMenuItem(value: 'rename', child: Text('이름 변경')),
                PopupMenuItem(value: 'trash', child: Text('휴지통으로 이동')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: document.title);
    final name = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('문서 이름 변경'),
              content: TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '문서 이름')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('취소')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, controller.text),
                    child: const Text('저장')),
              ],
            ));
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;
    document.title = trimmed;
    document.modified = DateTime.now();
    await ref.read(documentsProvider.notifier).update(document);
  }
}

class NotebookCard extends ConsumerWidget {
  const NotebookCard({required this.document, super.key});
  final DocumentItem document;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final title = document.title.trim().isEmpty ? '새 노트' : document.title;
    return Material(
      color: scheme.surface,
      elevation: 1,
      shadowColor: Colors.black.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openDocument(context, document, ref),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(14)),
                child: _NotebookCover(document: document),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 8, 8, 9),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      '${_templateLabel(document.pageStyle)} · ${document.pageCount}p',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '노트북 메뉴',
                icon: const Icon(Icons.more_horiz, size: 19),
                onSelected: (value) {
                  if (value == 'trash') {
                    ref.read(documentsProvider.notifier).remove(document.id);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'trash', child: Text('휴지통으로 이동')),
                ],
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _RefinedDocumentListCard extends ConsumerWidget {
  const _RefinedDocumentListCard({required this.document});
  final DocumentItem document;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, label) = switch (document.type) {
      DocumentType.pdf => (Icons.picture_as_pdf_outlined, scheme.error, 'PDF'),
      DocumentType.hwp || DocumentType.hwpx => (
          Icons.description_outlined,
          scheme.primary,
          document.type == DocumentType.hwpx ? 'HWPX' : 'HWP'
        ),
      DocumentType.drawingNote => (
          Icons.draw_outlined,
          scheme.tertiary,
          '필기 노트'
        ),
      _ => (Icons.note_alt_outlined, scheme.secondary, '메모'),
    };
    final title = document.title.trim().isEmpty ? '새 메모' : document.title;
    final time =
        '${document.modified.hour.toString().padLeft(2, '0')}:${document.modified.minute.toString().padLeft(2, '0')}';
    final meta = document.pageCount > 0
        ? '$label · ${document.pageCount}페이지 · $time'
        : '$label · $time';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surface.withValues(alpha: .88),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .72)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openDocument(context, document, ref),
          child: SizedBox(
            height: 88,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  SizedBox(
                    width: 52,
                    height: 64,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(7),
                      child: DocumentThumbnail(
                        document: document,
                        icon: icon,
                        color: color,
                        label: label,
                        compact: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14,
                                height: 1.45,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                        color: scheme.tertiary, shape: BoxShape.circle),
                  ),
                  PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.more_horiz, size: 20),
                    tooltip: '문서 메뉴',
                    onSelected: (value) {
                      if (value == 'trash') {
                        ref
                            .read(documentsProvider.notifier)
                            .remove(document.id);
                      } else if (value == 'favorite') {
                        document.favorite = !document.favorite;
                        document.modified = DateTime.now();
                        ref.read(documentsProvider.notifier).update(document);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'favorite', child: Text('즐겨찾기')),
                      PopupMenuItem(value: 'trash', child: Text('휴지통으로 이동')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DocumentGridTile extends ConsumerWidget {
  const DocumentGridTile({required this.document, super.key});
  final DocumentItem document;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, label) = switch (document.type) {
      DocumentType.pdf => (Icons.picture_as_pdf_outlined, scheme.error, 'PDF'),
      DocumentType.hwp || DocumentType.hwpx => (
          Icons.description_outlined,
          scheme.primary,
          'HWP'
        ),
      DocumentType.drawingNote => (Icons.draw_outlined, scheme.primary, '필기'),
      _ => (Icons.note_alt_outlined, scheme.primary, '메모'),
    };
    final title = document.title.trim().isEmpty ? '새 메모' : document.title;
    final time =
        '${document.modified.hour.toString().padLeft(2, '0')}:${document.modified.minute.toString().padLeft(2, '0')}';
    return Material(
      color: scheme.surface,
      elevation: 1,
      shadowColor: Colors.black.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openDocument(context, document, ref),
        child: Container(
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  color: const Color(0xfff4f5f7),
                  padding: const EdgeInsets.all(10),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .07),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: DocumentThumbnail(
                        document: document,
                        icon: icon,
                        color: color,
                        label: label,
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                height: 60,
                padding: const EdgeInsets.fromLTRB(13, 8, 6, 7),
                color: scheme.surface,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 3),
                          Text('$label · $time',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  )),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: '문서 메뉴',
                      icon: const Icon(Icons.more_horiz, size: 20),
                      onSelected: (value) {
                        if (value == 'trash') {
                          ref
                              .read(documentsProvider.notifier)
                              .remove(document.id);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('문서를 휴지통으로 이동했습니다.'),
                            ),
                          );
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'trash', child: Text('휴지통으로 이동')),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DocumentThumbnail extends ConsumerStatefulWidget {
  const DocumentThumbnail({
    required this.document,
    required this.icon,
    required this.color,
    required this.label,
    this.compact = false,
    super.key,
  });

  final DocumentItem document;
  final IconData icon;
  final Color color;
  final String label;
  final bool compact;

  @override
  ConsumerState<DocumentThumbnail> createState() => _DocumentThumbnailState();
}

class _DocumentThumbnailState extends ConsumerState<DocumentThumbnail> {
  var _isLoading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_ensureThumbnail());
  }

  @override
  void didUpdateWidget(covariant DocumentThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document.id != widget.document.id) {
      unawaited(_ensureThumbnail());
    }
  }

  Future<void> _ensureThumbnail() async {
    if (defaultTargetPlatform != TargetPlatform.fuchsia) {
      _finishLoading();
      return;
    }
    if (widget.document.thumbnailPath != null &&
        widget.document.thumbnailVersion >=
            DocumentThumbnailService.currentVersion) {
      _finishLoading();
      return;
    }
    try {
      final path =
          await const DocumentThumbnailService().ensure(widget.document);
      if (!mounted) return;
      if (path != null) {
        widget.document.thumbnailPath = path;
        widget.document.thumbnailVersion =
            DocumentThumbnailService.currentVersion;
        await ref.read(documentsProvider.notifier).update(widget.document);
      }
    } catch (error, stack) {
      developer.log(
        'thumbnail generation failed id=${widget.document.id}: $error',
        name: 'docnote.thumbnail',
        error: error,
        stackTrace: stack,
      );
    } finally {
      _finishLoading();
    }
  }

  void _finishLoading() {
    if (mounted && _isLoading) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.fuchsia) {
      return _FixedDocumentTypeCard(
        type: widget.document.type,
        compact: widget.compact,
      );
    }
    final path = widget.document.thumbnailPath;
    if (path != null && File(path).existsSync()) {
      if (path.toLowerCase().endsWith('.svg')) {
        return SizedBox.expand(
          child: ColoredBox(
            color: Colors.white,
            child: SvgPicture.file(
              File(path),
              fit: BoxFit.contain,
              alignment: Alignment.center,
              errorBuilder: (_, __, ___) => _ThumbnailError(
                icon: widget.icon,
                color: widget.color,
              ),
            ),
          ),
        );
      }
      return SizedBox.expand(
        child: ColoredBox(
          color: Colors.white,
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            alignment: Alignment.center,
            errorBuilder: (_, __, ___) => _ThumbnailError(
              icon: widget.icon,
              color: widget.color,
            ),
          ),
        ),
      );
    }
    if ((widget.document.type == DocumentType.textNote ||
            widget.document.type == DocumentType.drawingNote) &&
        widget.document.coverId != null) {
      return widget.compact
          ? _NotebookCoverArt(
              coverId: widget.document.coverId ?? 'simple',
              title: widget.document.title.trim().isEmpty
                  ? '새 노트'
                  : widget.document.title,
              template: widget.document.pageStyle,
              compact: true,
            )
          : _NotebookCover(document: widget.document);
    }
    if (widget.document.type == DocumentType.textNote) {
      return widget.compact
          ? _CompactMemoThumbnail(document: widget.document)
          : _MemoThumbnail(document: widget.document);
    }
    if (widget.document.type == DocumentType.drawingNote) {
      return _DrawingNoteThumbnail(document: widget.document);
    }
    return _DocumentPreview(
      icon: widget.icon,
      color: widget.color,
      label: widget.label,
      loading: _isLoading,
      compact: widget.compact,
    );
  }
}

class _FixedDocumentTypeCard extends StatelessWidget {
  const _FixedDocumentTypeCard({required this.type, required this.compact});
  final DocumentType type;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final style = switch (type) {
      DocumentType.pdf => (
          const Color(0xfffff1ed),
          const Color(0xffc95745),
          'PDF',
          Icons.picture_as_pdf_outlined,
        ),
      DocumentType.hwp || DocumentType.hwpx => (
          const Color(0xffeef7ef),
          const Color(0xff44835a),
          type == DocumentType.hwpx ? 'HWPX' : 'HWP',
          Icons.description_outlined,
        ),
      DocumentType.drawingNote => (
          const Color(0xffe9f2fb),
          const Color(0xff2f6eaa),
          '노트',
          Icons.draw_outlined,
        ),
      DocumentType.textNote => (
          const Color(0xfffff7df),
          const Color(0xff946f26),
          '메모',
          Icons.notes_outlined,
        ),
    };
    final labelSize = compact ? 6.5 : 9.0;
    return ColoredBox(
      color: style.$1,
      child: Padding(
        padding: EdgeInsets.all(compact ? 7 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: compact ? 4 : 6, vertical: compact ? 2 : 3),
              decoration: BoxDecoration(
                color: style.$2,
                borderRadius: BorderRadius.circular(compact ? 3 : 5),
              ),
              child: Text(style.$3,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: labelSize,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .15)),
            ),
            const Spacer(),
            Align(
              alignment: Alignment.bottomRight,
              child: Icon(style.$4,
                  size: compact ? 22 : 40,
                  color: style.$2.withValues(alpha: .32)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThumbnailError extends StatelessWidget {
  const _ThumbnailError({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Center(
        child: Icon(icon, size: 20, color: color.withValues(alpha: .65)),
      );
}

class _MemoThumbnail extends StatelessWidget {
  const _MemoThumbnail({required this.document});
  final DocumentItem document;

  @override
  Widget build(BuildContext context) {
    final text =
        document.body.trim().isEmpty ? '새 메모를 작성해 보세요.' : document.body.trim();
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            document.title.trim().isEmpty ? '메모' : document.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Text(
              text,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.55,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactMemoThumbnail extends StatelessWidget {
  const _CompactMemoThumbnail({required this.document});
  final DocumentItem document;

  @override
  Widget build(BuildContext context) {
    final hasContent =
        document.title.trim().isNotEmpty || document.body.trim().isNotEmpty;
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: Icon(
          hasContent ? Icons.notes_outlined : Icons.note_add_outlined,
          size: 20,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: .68),
        ),
      ),
    );
  }
}

class _NotebookCover extends StatelessWidget {
  const _NotebookCover({required this.document});
  final DocumentItem document;

  @override
  Widget build(BuildContext context) => _NotebookCoverArt(
        coverId: document.coverId ?? 'simple',
        title: document.title.trim().isEmpty ? '새 노트' : document.title,
        template: document.pageStyle,
      );
}

class _NotebookCoverArt extends StatelessWidget {
  const _NotebookCoverArt({
    required this.coverId,
    required this.title,
    this.template = 'blank',
    this.compact = false,
  });
  final String coverId;
  final String title;
  final String template;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = switch (coverId) {
      'work' => (
          const Color(0xffdce8f5),
          const Color(0xff27577f),
          const Color(0xffa9c6e4)
        ),
      'study' => (
          const Color(0xffe9efd9),
          const Color(0xff4d6b42),
          const Color(0xffcbd9af)
        ),
      'planner' => (
          const Color(0xffffe8dc),
          const Color(0xff9a5540),
          const Color(0xfff4c9b4)
        ),
      'minimal' => (
          const Color(0xffeeeeef),
          const Color(0xff4c4f58),
          const Color(0xffd5d6da)
        ),
      'dark' => (
          const Color(0xff263243),
          Colors.white,
          const Color(0xff49617e)
        ),
      'mood' => (
          const Color(0xfff3e5ec),
          const Color(0xff895b70),
          const Color(0xffe5bfd0)
        ),
      'ocean' => (
          const Color(0xffd9ebf8),
          const Color(0xff27658d),
          const Color(0xffaacfea)
        ),
      'rose' => (
          const Color(0xfff5e1e9),
          const Color(0xff94516c),
          const Color(0xffe6bfd0)
        ),
      'forest' => (
          const Color(0xffdcebdd),
          const Color(0xff456b47),
          const Color(0xffb9d7b9)
        ),
      'sand' => (
          const Color(0xfff4ebd4),
          const Color(0xff886b37),
          const Color(0xffe2cf9f)
        ),
      'violet' => (
          const Color(0xffe8e1f4),
          const Color(0xff6c528b),
          const Color(0xffcbbbe1)
        ),
      _ => (
          const Color(0xffe6eff9),
          const Color(0xff245b90),
          const Color(0xffb9d2ea)
        ),
    };
    final titleSize = compact ? 13.0 : 20.0;
    if (compact) {
      return ColoredBox(
        color: palette.$1,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              left: 7,
              top: 7,
              child: Text('DOCNOTE',
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                      color: palette.$2,
                      fontSize: 5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .35)),
            ),
            Positioned(
              top: 22,
              right: 7,
              child: SizedBox(
                width: 24,
                height: 28,
                child: Column(
                  children: List.generate(
                      4,
                      (_) => Expanded(
                            child: Align(
                                alignment: Alignment.topCenter,
                                child: Container(
                                    height: 1,
                                    color: palette.$2.withValues(alpha: .32))),
                          )),
                ),
              ),
            ),
            Positioned(
              left: 7,
              right: 5,
              bottom: 6,
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: palette.$2,
                      fontSize: 8,
                      height: 1.1,
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );
    }
    return Container(
      color: palette.$1,
      child: Stack(children: [
        Positioned(
          right: -18,
          bottom: -28,
          child: Container(
            width: compact ? 76 : 130,
            height: compact ? 76 : 130,
            decoration: BoxDecoration(
                color: palette.$3.withValues(alpha: .55),
                shape: BoxShape.circle),
          ),
        ),
        if (coverId == 'study' || coverId == 'planner')
          Positioned(
            top: compact ? 12 : 18,
            right: compact ? 10 : 16,
            child: Icon(
              coverId == 'study'
                  ? Icons.auto_stories_outlined
                  : Icons.calendar_month_outlined,
              color: palette.$2.withValues(alpha: .48),
              size: compact ? 22 : 34,
            ),
          ),
        Padding(
          padding: EdgeInsets.all(compact ? 10 : 16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                  width: compact ? 3 : 4,
                  height: compact ? 13 : 17,
                  color: palette.$2),
              const SizedBox(width: 5),
              Text('DocNote',
                  style: TextStyle(
                      color: palette.$2,
                      fontSize: compact ? 7 : 10,
                      fontWeight: FontWeight.w700)),
            ]),
            const Spacer(),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.bottomLeft,
                child: Text(
                  title,
                  maxLines: compact ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: palette.$2,
                      fontSize: titleSize,
                      height: 1.08,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ),
            SizedBox(height: compact ? 6 : 10),
            Text(
              _templateLabel(template).toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.$2.withValues(alpha: .72),
                fontSize: compact ? 6 : 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

String _templateLabel(String template) => switch (template) {
      'ruled' => 'Ruled',
      'ruledWide' => 'Wide ruled',
      'grid' => 'Grid',
      'graph5' => '5mm graph',
      'dotted' => 'Dotted',
      'cornell' => 'Cornell',
      'checklist' => 'Checklist',
      'meeting' => 'Meeting notes',
      'kanban' => 'Kanban board',
      'timetable' => 'Study timetable',
      'daily' => 'Daily planner',
      'weekly' => 'Weekly planner',
      'monthly' => 'Monthly planner',
      'calendar' => 'Calendar',
      'habit' => 'Habit tracker',
      _ => 'Blank',
    };

class _PaperPreviewPainter extends CustomPainter {
  const _PaperPreviewPainter(this.templateId);
  final String templateId;

  @override
  void paint(Canvas canvas, Size size) {
    final paper = Paint()..color = const Color(0xfffbfbfc);
    final rule = Paint()
      ..color = const Color(0xffcbd7e4)
      ..strokeWidth = .75;
    canvas.drawRect(Offset.zero & size, paper);
    if (templateId == 'blank') return;
    if (templateId == 'grid' ||
        templateId == 'graph5' ||
        templateId == 'dotted') {
      final gap = templateId == 'graph5' ? 7.0 : 9.0;
      for (double x = gap; x < size.width; x += gap) {
        for (double y = gap; y < size.height; y += gap) {
          if (templateId == 'dotted') {
            canvas.drawCircle(Offset(x, y), .65, rule);
          } else {
            canvas.drawLine(Offset(x, 0), Offset(x, size.height), rule);
            canvas.drawLine(Offset(0, y), Offset(size.width, y), rule);
          }
        }
      }
      return;
    }
    if (templateId == 'kanban') {
      for (var column = 1; column < 3; column++) {
        canvas.drawLine(Offset(size.width * column / 3, 0),
            Offset(size.width * column / 3, size.height), rule);
      }
      canvas.drawLine(Offset(0, 13), Offset(size.width, 13), rule);
      for (double y = 27; y < size.height; y += 20) {
        canvas.drawLine(Offset(4, y), Offset(size.width - 4, y), rule);
      }
      return;
    }
    if (templateId == 'timetable' || templateId == 'habit') {
      final columns = templateId == 'timetable' ? 5 : 7;
      final rows = templateId == 'timetable' ? 7 : 5;
      for (var column = 1; column < columns; column++) {
        canvas.drawLine(Offset(size.width * column / columns, 0),
            Offset(size.width * column / columns, size.height), rule);
      }
      for (var row = 1; row < rows; row++) {
        canvas.drawLine(Offset(0, size.height * row / rows),
            Offset(size.width, size.height * row / rows), rule);
      }
      return;
    }
    if (templateId == 'cornell') {
      canvas.drawLine(Offset(size.width * .3, 0),
          Offset(size.width * .3, size.height), rule);
      canvas.drawLine(Offset(0, size.height * .78),
          Offset(size.width, size.height * .78), rule);
    }
    if (templateId == 'daily' ||
        templateId == 'weekly' ||
        templateId == 'monthly' ||
        templateId == 'calendar') {
      final columns = templateId == 'daily'
          ? 1
          : templateId == 'weekly'
              ? 2
              : templateId == 'calendar'
                  ? 7
                  : 3;
      for (var x = 1; x < columns; x++) {
        canvas.drawLine(Offset(size.width * x / columns, 0),
            Offset(size.width * x / columns, size.height), rule);
      }
      canvas.drawLine(Offset(0, 12), Offset(size.width, 12), rule);
    }
    final start = templateId == 'meeting' ? 15.0 : 8.0;
    final gap = templateId == 'ruledWide' ? 14.0 : 9.0;
    for (double y = start; y < size.height; y += gap) {
      canvas.drawLine(Offset(4, y), Offset(size.width - 4, y), rule);
      if (templateId == 'checklist') {
        canvas.drawRect(
            Rect.fromLTWH(5, y - 5, 4, 4), rule..style = PaintingStyle.stroke);
      }
      rule.style = PaintingStyle.stroke;
    }
  }

  @override
  bool shouldRepaint(covariant _PaperPreviewPainter oldDelegate) =>
      oldDelegate.templateId != templateId;
}

class _DrawingNoteThumbnail extends StatelessWidget {
  const _DrawingNoteThumbnail({required this.document});
  final DocumentItem document;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Stroke>>(
        future: AnnotationStore().load(document.id, 'page_1'),
        builder: (context, snapshot) {
          final strokes = snapshot.data ?? const <Stroke>[];
          return Container(
            color: Colors.white,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return CustomPaint(
                  painter: StrokePainter(
                    strokes,
                    const [],
                    size,
                    StrokeTool.pen,
                    Colors.black,
                    3,
                  ),
                  child: const SizedBox.expand(),
                );
              },
            ),
          );
        },
      );
}

class _DocumentPreview extends StatelessWidget {
  const _DocumentPreview({
    required this.icon,
    required this.color,
    required this.label,
    required this.loading,
    this.compact = false,
  });

  final IconData icon;
  final Color color;
  final String label;
  final bool loading;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return ColoredBox(
        color: Colors.white,
        child: Center(
          child: loading
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: color.withValues(alpha: .7),
                  ),
                )
              : Icon(icon, size: 20, color: color.withValues(alpha: .65)),
        ),
      );
    }
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 10)),
            ),
          ]),
          const SizedBox(height: 16),
          Container(height: 2, width: 72, color: color.withValues(alpha: 0.45)),
          const SizedBox(height: 10),
          Container(
            height: 2,
            width: double.infinity,
            color: const Color(0xffe6e9ed),
          ),
          const SizedBox(height: 7),
          Container(height: 2, width: 112, color: const Color(0xffe6e9ed)),
          const Spacer(),
          Row(
            children: [
              if (loading) ...[
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: color.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text('미리보기 생성 중',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          )),
                ),
              ] else
                Flexible(
                  child: Text('미리보기 없음',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          )),
                ),
              const Spacer(),
              Icon(Icons.description_outlined,
                  size: 26, color: color.withValues(alpha: 0.20)),
            ],
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    this.title = '아직 문서가 없습니다',
    this.message = '빠른 메모나 PDF 가져오기로 기록을 시작해 보세요.',
    this.icon = Icons.note_alt_outlined,
    super.key,
  });
  const EmptyState.forCategory(HomeDocumentCategory category, {super.key})
      : title = category == HomeDocumentCategory.memo
            ? '아직 메모가 없습니다'
            : category == HomeDocumentCategory.pdf
                ? '아직 PDF 문서가 없습니다'
                : category == HomeDocumentCategory.hwp
                    ? '아직 HWP 문서가 없습니다'
                    : '아직 문서가 없습니다',
        message = category == HomeDocumentCategory.memo
            ? '새 메모를 작성하면 이곳에 표시됩니다.'
            : category == HomeDocumentCategory.pdf
                ? 'PDF를 가져오면 이곳에서 확인할 수 있습니다.'
                : category == HomeDocumentCategory.hwp
                    ? 'HWP 파일을 가져오면 이곳에 표시됩니다.\nHWP 열기 기능은 준비 중입니다.'
                    : '빠른 메모나 PDF 가져오기로 기록을 시작해 보세요.',
        icon = category == HomeDocumentCategory.pdf
            ? Icons.picture_as_pdf_outlined
            : category == HomeDocumentCategory.hwp
                ? Icons.description_outlined
                : category == HomeDocumentCategory.memo
                    ? Icons.edit_note_outlined
                    : Icons.note_alt_outlined;
  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 72, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(title,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}
