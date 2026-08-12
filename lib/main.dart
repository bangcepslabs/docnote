import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:file_picker/file_picker.dart';
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
          onSearch: () => setState(() => index = 3)),
      const DocumentsPage(),
      const SizedBox(),
      const SearchPage(),
      const SettingsPage()
    ];
    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) {
          if (value == 2) {
            _createSheet();
          } else {
            setState(() => index = value);
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '홈',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: '문서',
          ),
          NavigationDestination(
            icon: Icon(Icons.add),
            selectedIcon: Icon(Icons.add),
            label: '새로 만들기',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: '검색',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '설정',
          ),
        ],
      ),
    );
  }

  void _createSheet() => showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
          child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              child: Wrap(children: [
                const ListTile(
                    contentPadding: EdgeInsets.symmetric(horizontal: 4),
                    title: Text('새 문서',
                        style: TextStyle(fontWeight: FontWeight.w700))),
                ListTile(
                    leading: const Icon(Icons.note_add_outlined),
                    title: const Text('새 메모'),
                    onTap: () {
                      Navigator.pop(context);
                      _quickMemo();
                    }),
                ListTile(
                    leading: const Icon(Icons.draw_outlined),
                    title: const Text('필기 노트'),
                    onTap: () {
                      Navigator.pop(context);
                      _drawingNote();
                    }),
                ListTile(
                    leading: const Icon(Icons.picture_as_pdf_outlined),
                    title: const Text('PDF 가져오기'),
                    onTap: () {
                      Navigator.pop(context);
                      _pickPdf();
                    }),
                ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: const Text('HWP/HWPX 가져오기'),
                    onTap: () {
                      Navigator.pop(context);
                      _pickHwp();
                    }),
                ListTile(
                    leading: const Icon(Icons.image_outlined),
                    title: const Text('이미지 가져오기'),
                    subtitle: const Text('메모 첨부 기능 준비 중'),
                    onTap: () {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('이미지 첨부 기능은 준비 중입니다.')));
                    }),
                ListTile(
                    leading: const Icon(Icons.document_scanner_outlined),
                    title: const Text('문서 스캔'),
                    subtitle: const Text('카메라 스캔 기능 준비 중'),
                    onTap: () {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('문서 스캔 기능은 준비 중입니다.')));
                    })
              ]))));
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
      String? thumbnailPath;
      if (pages > 0) {
        final page = await pdf.getPage(1, autoCloseAndroid: false);
        final thumbnailDirectory =
            Directory('${root.path}/documents/$id/thumbnails');
        await thumbnailDirectory.create(recursive: true);
        final thumbnail = await page.render(
            width: 720,
            height: 720 * page.height / page.width,
            format: PdfPageImageFormat.png,
            backgroundColor: '#FFFFFF');
        final thumbnailBytes = thumbnail?.bytes;
        if (thumbnailBytes != null) {
          final file = File('${thumbnailDirectory.path}/page_1.png');
          await file.writeAsBytes(thumbnailBytes, flush: true);
          thumbnailPath = file.path;
        }
        await page.close();
      }
      developer.log('pdf opened pages=$pages path=${target.path}',
          name: 'docnote.pdf');
      await pdf.close();
      final d = DocumentItem(
          id: id,
          title: picked.name,
          type: DocumentType.pdf,
          sourcePath: target.path,
          thumbnailPath: thumbnailPath,
          thumbnailVersion: thumbnailPath == null
              ? 0
              : DocumentThumbnailService.currentVersion,
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
      String? thumbnailPath;
      try {
        thumbnailPath = await const DocumentThumbnailService().ensure(
          DocumentItem(
            id: id,
            title: picked.name,
            type: extension,
            sourcePath: target.path,
          ),
        );
      } catch (thumbnailError, stack) {
        developer.log(
          'HWP thumbnail generation failed id=$id: $thumbnailError',
          name: 'docnote.thumbnail',
          error: thumbnailError,
          stackTrace: stack,
        );
      }
      final document = DocumentItem(
          id: id,
          title: picked.name,
          type: extension,
          sourcePath: target.path,
          thumbnailPath: thumbnailPath,
          thumbnailVersion: thumbnailPath == null
              ? 0
              : DocumentThumbnailService.currentVersion);
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
  };
  static const templates = <String, String>{
    'blank': 'Blank',
    'ruled': 'Ruled',
    'grid': 'Grid',
    'dotted': 'Dotted',
    'cornell': 'Cornell',
    'checklist': 'Checklist',
    'meeting': 'Meeting Notes',
    'daily': 'Daily planner',
    'weekly': 'Weekly planner',
    'monthly': 'Monthly planner',
    'calendar': 'Calendar',
  };

  @override
  void dispose() {
    titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
            color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: .55),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Expanded(child: _TemplatePaper(templateId: id)),
            const SizedBox(height: 3),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
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
      super.key});
  final VoidCallback onQuickMemo;
  final VoidCallback onImportPdf;
  final VoidCallback onImportHwp;
  final VoidCallback onSearch;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  HomeDocumentCategory category = HomeDocumentCategory.all;
  bool grid = true;
  bool sortByLastOpened = false;

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(documentsProvider).where((d) => !d.trashed).toList()
      ..sort((left, right) {
        final leftDate = sortByLastOpened
            ? left.lastOpened ?? left.modified
            : left.modified;
        final rightDate = sortByLastOpened
            ? right.lastOpened ?? right.modified
            : right.modified;
        return rightDate.compareTo(leftDate);
      });
    final scheme = Theme.of(context).colorScheme;
    final notebooks = docs.where((document) => document.isNotebook).toList();
    final imported = docs.where((document) => document.isImportedDocument).toList();
    final recentDocs = imported.where((document) => switch (category) {
          HomeDocumentCategory.pdf => document.type == DocumentType.pdf,
          HomeDocumentCategory.hwp =>
            document.type == DocumentType.hwp || document.type == DocumentType.hwpx,
          _ => true,
        }).toList();
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
                  onSelected: (value) => setState(() => sortByLastOpened = value),
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
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
                    child: Icon(icon, size: 42, color: ink.withValues(alpha: .72)),
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
                Text('템플릿으로 시작', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton(onPressed: onCreateNotebook, child: const Text('모두 보기')),
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
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: .45)),
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
              notebooks.isEmpty ? '표지와 속지를 골라 첫 노트북을 만들어 보세요.' : '나만의 표지와 속지로 정리한 노트입니다.',
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

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});
  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  String query = '';
  DocumentType? typeFilter;
  bool favoritesOnly = false;
  @override
  Widget build(BuildContext context) {
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
                    itemBuilder: (_, index) => DocumentTile(document: docs[index]),
                  ),
          )
        ]));
  }
}

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          '문서'
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .7)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 44,
            height: 56,
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
            IconButton(
              tooltip: document.favorite ? '즐겨찾기 해제' : '즐겨찾기',
              icon: Icon(document.favorite ? Icons.star : Icons.star_border),
              color: document.favorite ? Colors.amber.shade700 : null,
              onPressed: () {
                document.favorite = !document.favorite;
                document.modified = DateTime.now();
                ref.read(documentsProvider.notifier).update(document);
              },
            ),
            PopupMenuButton<String>(
              tooltip: '문서 메뉴',
              onSelected: (value) {
                if (value == 'rename') _rename(context, ref);
                if (value == 'trash') {
                  ref.read(documentsProvider.notifier).remove(document.id);
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('문서를 휴지통으로 이동했습니다.')));
                }
              },
              itemBuilder: (_) => const [
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
                borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
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
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
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
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(DocNoteTheme.radiusMd)),
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
                              style: Theme.of(context).textTheme.labelMedium?.copyWith(
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
    if (widget.document.thumbnailPath != null &&
        widget.document.thumbnailVersion >= DocumentThumbnailService.currentVersion) {
      _finishLoading();
      return;
    }
    try {
      final path = await const DocumentThumbnailService().ensure(widget.document);
      if (!mounted) return;
      if (path != null) {
        widget.document.thumbnailPath = path;
        widget.document.thumbnailVersion = DocumentThumbnailService.currentVersion;
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
    final text = document.body.trim().isEmpty
        ? '새 메모를 작성해 보세요.'
        : document.body.trim();
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
    final hasContent = document.title.trim().isNotEmpty ||
        document.body.trim().isNotEmpty;
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
      'work' => (const Color(0xffdce8f5), const Color(0xff27577f), const Color(0xffa9c6e4)),
      'study' => (const Color(0xffe9efd9), const Color(0xff4d6b42), const Color(0xffcbd9af)),
      'planner' => (const Color(0xffffe8dc), const Color(0xff9a5540), const Color(0xfff4c9b4)),
      'minimal' => (const Color(0xffeeeeef), const Color(0xff4c4f58), const Color(0xffd5d6da)),
      'dark' => (const Color(0xff263243), Colors.white, const Color(0xff49617e)),
      'mood' => (const Color(0xfff3e5ec), const Color(0xff895b70), const Color(0xffe5bfd0)),
      _ => (const Color(0xffe6eff9), const Color(0xff245b90), const Color(0xffb9d2ea)),
    };
    final titleSize = compact ? 13.0 : 20.0;
    return Container(
      color: palette.$1,
      child: Stack(children: [
        Positioned(
          right: -18,
          bottom: -28,
          child: Container(
            width: compact ? 76 : 130,
            height: compact ? 76 : 130,
            decoration: BoxDecoration(color: palette.$3.withValues(alpha: .55), shape: BoxShape.circle),
          ),
        ),
        if (coverId == 'study' || coverId == 'planner')
          Positioned(
            top: compact ? 12 : 18,
            right: compact ? 10 : 16,
            child: Icon(
              coverId == 'study' ? Icons.auto_stories_outlined : Icons.calendar_month_outlined,
              color: palette.$2.withValues(alpha: .48),
              size: compact ? 22 : 34,
            ),
          ),
        Padding(
          padding: EdgeInsets.all(compact ? 10 : 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: compact ? 3 : 4, height: compact ? 13 : 17, color: palette.$2),
              const SizedBox(width: 5),
              Text('DocNote', style: TextStyle(color: palette.$2, fontSize: compact ? 7 : 10, fontWeight: FontWeight.w700)),
            ]),
            const Spacer(),
            Text(
              title,
              maxLines: compact ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.$2, fontSize: titleSize, height: 1.08, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: compact ? 6 : 10),
            Text(_templateLabel(template).toUpperCase(),
                style: TextStyle(color: palette.$2.withValues(alpha: .72), fontSize: compact ? 6 : 9, fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
    );
  }
}

String _templateLabel(String template) => switch (template) {
      'ruled' => 'Ruled',
      'grid' => 'Grid',
      'dotted' => 'Dotted',
      'cornell' => 'Cornell',
      'checklist' => 'Checklist',
      'meeting' => 'Meeting notes',
      'daily' => 'Daily planner',
      'weekly' => 'Weekly planner',
      'monthly' => 'Monthly planner',
      'calendar' => 'Calendar',
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
    if (templateId == 'grid' || templateId == 'dotted') {
      const gap = 9.0;
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
    if (templateId == 'cornell') {
      canvas.drawLine(Offset(size.width * .3, 0), Offset(size.width * .3, size.height), rule);
      canvas.drawLine(Offset(0, size.height * .78), Offset(size.width, size.height * .78), rule);
    }
    if (templateId == 'daily' || templateId == 'weekly' || templateId == 'monthly') {
      final columns = templateId == 'daily' ? 1 : templateId == 'weekly' ? 2 : 3;
      for (var x = 1; x < columns; x++) {
        canvas.drawLine(Offset(size.width * x / columns, 0), Offset(size.width * x / columns, size.height), rule);
      }
      canvas.drawLine(Offset(0, 12), Offset(size.width, 12), rule);
    }
    final start = templateId == 'meeting' ? 15.0 : 8.0;
    for (double y = start; y < size.height; y += 9) {
      canvas.drawLine(Offset(4, y), Offset(size.width - 4, y), rule);
      if (templateId == 'checklist') canvas.drawRect(Rect.fromLTWH(5, y - 5, 4, 4), rule..style = PaintingStyle.stroke);
      rule.style = PaintingStyle.stroke;
    }
  }

  @override
  bool shouldRepaint(covariant _PaperPreviewPainter oldDelegate) => oldDelegate.templateId != templateId;
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
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          )),
                ),
              ] else
                Flexible(
                  child: Text('미리보기 없음',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
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
