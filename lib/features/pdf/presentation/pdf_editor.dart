import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/storage/annotation_store.dart';
import '../data/pdf_export_service.dart';
import '../data/pdf_file_validator.dart';
import '../../drawing/domain/stroke.dart';
import '../../drawing/presentation/drawing_editor.dart';
import '../../../core/theme/docnote_theme.dart';

enum PdfInteractionMode { view, draw }

enum DrawingTool { pen, highlighter, eraser, lasso, shape }

enum ShapeKind { line, rectangle, ellipse, arrow }

enum EditorTool { hand, pen, highlighter, eraser, lasso, shape }

class PenPreset {
  const PenPreset(
      {required this.type,
      required this.color,
      required this.width,
      required this.opacity});
  final PenType type;
  final Color color;
  final double width;
  final double opacity;
}

class PdfEditingState {
  PdfInteractionMode mode = PdfInteractionMode.view;
  EditorTool activeTool = EditorTool.hand;
  DrawingTool selectedTool = DrawingTool.pen;
  ShapeKind shapeKind = ShapeKind.line;
  PenType selectedPenType = PenType.ballpoint;
  Color selectedColor = Colors.black;
  double strokeWidth = 3;
  double opacity = 1;
  final toolWidths = <DrawingTool, double>{
    DrawingTool.pen: 3,
    DrawingTool.highlighter: 14,
    DrawingTool.eraser: 18,
  };
  final toolOpacities = <DrawingTool, double>{
    DrawingTool.pen: 1,
    DrawingTool.highlighter: .35,
    DrawingTool.eraser: 1,
  };
  int selectedPageIndex = 0;
  bool canUndo = false;
  bool canRedo = false;
  final presets = <PenPreset>[
    PenPreset(
        type: PenType.ballpoint, color: Colors.black, width: 3, opacity: 1),
    PenPreset(type: PenType.ballpoint, color: Colors.red, width: 3, opacity: 1),
    PenPreset(type: PenType.marker, color: Colors.blue, width: 6, opacity: .9),
  ];

  void selectTool(DrawingTool tool) {
    selectedTool = tool;
    activeTool = switch (tool) {
      DrawingTool.pen => EditorTool.pen,
      DrawingTool.highlighter => EditorTool.highlighter,
      DrawingTool.eraser => EditorTool.eraser,
      DrawingTool.lasso => EditorTool.lasso,
      DrawingTool.shape => EditorTool.shape,
    };
    strokeWidth = toolWidths[tool] ?? strokeWidth;
    opacity = toolOpacities[tool] ?? opacity;
  }

  void selectPenType(PenType type) {
    selectedPenType = type;
    selectedTool = DrawingTool.pen;
    activeTool = EditorTool.pen;
    final preset = switch (type) {
      PenType.ballpoint => (3.0, 1.0),
      PenType.fountain => (3.5, .92),
      PenType.pencil => (2.5, .72),
      PenType.marker => (6.0, .9),
    };
    strokeWidth = preset.$1;
    opacity = preset.$2;
    toolWidths[DrawingTool.pen] = strokeWidth;
    toolOpacities[DrawingTool.pen] = opacity;
  }

  void setWidth(double value) {
    strokeWidth = value;
    toolWidths[selectedTool] = value;
  }

  void setOpacity(double value) {
    opacity = value;
    toolOpacities[selectedTool] = value;
  }

  void selectHand() {
    activeTool = EditorTool.hand;
    mode = PdfInteractionMode.view;
  }

  void applyPreset(PenPreset preset) {
    selectedPenType = preset.type;
    selectedColor = preset.color;
    selectedTool = DrawingTool.pen;
    activeTool = EditorTool.pen;
    strokeWidth = preset.width;
    opacity = preset.opacity;
    toolWidths[DrawingTool.pen] = strokeWidth;
    toolOpacities[DrawingTool.pen] = opacity;
    mode = PdfInteractionMode.draw;
  }
}

class PdfEditorPage extends StatefulWidget {
  const PdfEditorPage(
      {required this.documentId,
      required this.title,
      required this.path,
      super.key});
  final String documentId;
  final String title;
  final String path;
  @override
  State<PdfEditorPage> createState() => _PdfEditorPageState();
}

class _PdfEditorPageState extends State<PdfEditorPage> {
  PdfDocument? document;
  Object? error;
  final editing = PdfEditingState();
  final pageKeys = <int, GlobalKey<_PdfPageWithInkState>>{};
  bool exporting = false;
  bool toolbarVisible = true;
  PdfExportProgress? progress;
  final bookmarkedPages = <int>{};

  String get _bookmarkKey => 'docnote.pdf.bookmarks.${widget.documentId}';

  @override
  void initState() {
    super.initState();
    _open();
    _loadBookmarks();
  }

  Future<void> _loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final values = prefs.getStringList(_bookmarkKey) ?? const [];
    if (!mounted) return;
    setState(() => bookmarkedPages
      ..clear()
      ..addAll(values.map(int.tryParse).whereType<int>()));
  }

  Future<void> _toggleBookmark() async {
    final page = editing.selectedPageIndex + 1;
    setState(() {
      if (!bookmarkedPages.add(page)) bookmarkedPages.remove(page);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _bookmarkKey, bookmarkedPages.map((value) => '$value').toList());
  }

  Future<void> _showBookmarks() async {
    if (bookmarkedPages.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('저장된 북마크가 없습니다.')));
      return;
    }
    final page = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: (bookmarkedPages.toList()..sort())
              .map((value) => ListTile(
                    leading: const Icon(Icons.bookmark_outline),
                    title: Text('$value페이지'),
                    onTap: () => Navigator.pop(context, value),
                  ))
              .toList(),
        ),
      ),
    );
    if (!mounted || page == null || document == null) return;
    final index = page.clamp(1, document!.pagesCount) - 1;
    _activatePage(index);
    final targetContext = _keyFor(index).currentContext;
    if (targetContext != null) {
      await Scrollable.ensureVisible(targetContext,
          duration: const Duration(milliseconds: 260), alignment: .12);
    }
  }

  Future<void> _open() async {
    try {
      final file = File(widget.path);
      await PdfFileValidator.validate(file, documentId: widget.documentId);
      final value = await PdfDocument.openFile(file.path);
      if (mounted) {
        setState(() => document = value);
      } else {
        await value.close();
      }
    } catch (e, stack) {
      developer.log(
          'document open failed path=${widget.path} id=${widget.documentId}: $e',
          name: 'docnote.pdf',
          error: e,
          stackTrace: stack);
      if (mounted) {
        setState(() => error = e);
      }
    }
  }

  @override
  void dispose() {
    final value = document;
    document = null;
    value?.close();
    super.dispose();
  }

  GlobalKey<_PdfPageWithInkState> _keyFor(int index) =>
      pageKeys.putIfAbsent(index, () => GlobalKey<_PdfPageWithInkState>());
  void _activatePage(int index) {
    if (!mounted) return;
    setState(() {
      editing.selectedPageIndex = index;
      _refreshUndoState();
    });
  }

  Future<void> _showPageJumpDialog() async {
    final pdf = document;
    if (pdf == null) return;
    final controller = TextEditingController(
        text: '${editing.selectedPageIndex + 1}');
    final target = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('페이지 이동'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: '페이지 (1–${pdf.pagesCount})',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => Navigator.of(dialogContext)
              .pop(int.tryParse(controller.text)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext)
                  .pop(int.tryParse(controller.text)),
              child: const Text('이동')),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || target == null) return;
    final page = target.clamp(1, pdf.pagesCount) - 1;
    final key = _keyFor(page);
    _activatePage(page);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetContext = key.currentContext;
      if (targetContext != null) {
        Scrollable.ensureVisible(targetContext,
            duration: const Duration(milliseconds: 260),
            alignment: .12,
            curve: Curves.easeOut);
      }
    });
  }

  void _refreshUndoState() {
    final state = pageKeys[editing.selectedPageIndex]?.currentState;
    editing.canUndo = state?.canUndo ?? false;
    editing.canRedo = state?.canRedo ?? false;
  }

  void _pageStateChanged(int index) {
    if (index == editing.selectedPageIndex && mounted) {
      setState(_refreshUndoState);
    }
  }

  void _setMode(PdfInteractionMode mode) {
    setState(() {
      if (mode == PdfInteractionMode.view) {
        editing.selectHand();
      } else {
        editing.mode = mode;
        editing.selectTool(editing.selectedTool);
      }
      pageKeys[editing.selectedPageIndex]?.currentState?.cancelActiveStroke();
    });
  }

  void _undo() {
    pageKeys[editing.selectedPageIndex]?.currentState?.undo();
  }

  void _redo() {
    pageKeys[editing.selectedPageIndex]?.currentState?.redo();
  }

  void _clearCurrent() {
    pageKeys[editing.selectedPageIndex]?.currentState?.clearStrokes();
  }

  Future<void> _export() async {
    final pdf = document;
    if (pdf == null || exporting) return;
    setState(() {
      exporting = true;
      progress = null;
    });
    try {
      for (final key in pageKeys.values) {
        await key.currentState?.saveNow();
      }
      final file = await PdfExportService(AnnotationStore()).export(
          sourcePath: widget.path,
          documentId: widget.documentId,
          title: widget.title,
          onProgress: (value) {
            if (mounted) setState(() => progress = value);
          });
      if (!mounted) return;
      setState(() => exporting = false);
      await showModalBottomSheet<void>(
          context: context,
          builder: (_) => SafeArea(
                  child: Wrap(children: [
                const ListTile(
                    leading: Icon(Icons.check_circle, color: Colors.green),
                    title: Text('PDF 저장 완료')),
                ListTile(
                    leading: const Icon(Icons.share),
                    title: const Text('공유'),
                    onTap: () {
                      Navigator.pop(context);
                      SharePlus.instance.share(ShareParams(
                          files: [XFile(file.path)], text: widget.title));
                    }),
                ListTile(
                    leading: const Icon(Icons.close),
                    title: const Text('닫기'),
                    onTap: () => Navigator.pop(context))
              ])));
    } catch (error, stack) {
      developer.log('PDF export failed id=${widget.documentId}: $error',
          name: 'docnote.pdf', error: error, stackTrace: stack);
      if (mounted) {
        setState(() => exporting = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('PDF 내보내기에 실패했습니다.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pdf = document;
    if (error != null) {
      return Scaffold(
          appBar: AppBar(title: Text(widget.title)),
          body: const Center(child: Text('PDF를 열 수 없습니다. 파일을 확인해 주세요.')));
    }
    if (pdf == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.2,
                ),
          ),
          actions: [
            IconButton(
                onPressed: _toggleBookmark,
                tooltip: bookmarkedPages.contains(editing.selectedPageIndex + 1)
                    ? '현재 페이지 북마크 제거'
                    : '현재 페이지 북마크',
                icon: Icon(bookmarkedPages.contains(editing.selectedPageIndex + 1)
                    ? Icons.bookmark
                    : Icons.bookmark_border)),
            IconButton(
                onPressed: _showBookmarks,
                tooltip: '북마크 목록',
                icon: const Icon(Icons.bookmarks_outlined)),
            IconButton(
                onPressed: _showPageJumpDialog,
                tooltip: '페이지 이동',
                icon: const Icon(Icons.find_in_page_outlined)),
            IconButton(
                onPressed: () =>
                    setState(() => toolbarVisible = !toolbarVisible),
                tooltip: toolbarVisible ? '편집 도구 숨기기' : '편집 도구 열기',
                icon: Icon(
                    toolbarVisible ? Icons.keyboard_arrow_up : Icons.edit)),
            if (exporting)
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              value: progress == null
                                  ? null
                                  : progress!.current / progress!.total)))),
            IconButton(
                onPressed: exporting ? null : _export,
                tooltip: 'PDF 내보내기',
                icon: const Icon(Icons.picture_as_pdf)),
            IconButton(
                onPressed: () => SharePlus.instance.share(ShareParams(
                    files: [XFile(widget.path)], text: widget.title)),
                icon: const Icon(Icons.share)),
            PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'clear') _confirmClearAll();
                },
                itemBuilder: (_) => [
                      const PopupMenuItem(
                          value: 'clear', child: Text('전체 문서 필기 모두 지우기'))
                    ])
          ],
        ),
        body: Column(children: [
          if (toolbarVisible)
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  bottom: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: PdfDrawingToolbar(
                    state: editing,
                    onView: () => _setMode(PdfInteractionMode.view),
                    onPenTypeChanged: (type) => setState(() {
                          editing.selectPenType(type);
                          editing.mode = PdfInteractionMode.draw;
                        }),
                    onPenWidthChanged: (width) =>
                        setState(() => editing.setWidth(width)),
                    onPresetChanged: (preset) =>
                        setState(() => editing.applyPreset(preset)),
                    onShapeChanged: (shape) =>
                        setState(() => editing.shapeKind = shape),
                    onToolChanged: (tool) => setState(() {
                          editing.selectTool(tool);
                          editing.mode = PdfInteractionMode.draw;
                        }),
                    onColorChanged: (color) =>
                        setState(() => editing.selectedColor = color),
                    onWidthChanged: (width) =>
                        setState(() => editing.setWidth(width)),
                    onOpacityChanged: (opacity) =>
                        setState(() => editing.setOpacity(opacity)),
                    onUndo: _undo,
                    onRedo: _redo,
                    onClear: () => _confirmClearCurrent()),
              ),
            ),
          Expanded(
            child: Stack(children: [
              ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
                  physics: editing.mode == PdfInteractionMode.draw
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  itemCount: pdf.pagesCount,
                  itemBuilder: (_, index) {
                    final key = _keyFor(index);
                    return PdfPageWithInk(
                        key: key,
                        document: pdf,
                        pageNumber: index + 1,
                        documentId: widget.documentId,
                        editMode: editing.mode == PdfInteractionMode.draw,
                        tool: editing.selectedTool,
                        penType: editing.selectedPenType,
                        color: editing.selectedColor,
                        width: editing.strokeWidth,
                        opacity: editing.opacity,
                        shapeKind: editing.shapeKind,
                        onPageActivated: () => _activatePage(index),
                        onStateChanged: () => _pageStateChanged(index));
                  }),
              Positioned(
                right: 16,
                bottom: 16,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surface
                          .withValues(alpha: .96),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .08),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 5),
                      child: Text(
                        '${editing.selectedPageIndex + 1} / ${pdf.pagesCount}',
                        style:
                            Theme.of(context).textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ]));
  }

  Future<void> _confirmClearCurrent() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
                title: const Text('현재 페이지 필기 지우기'),
                content: const Text('현재 페이지의 필기를 모두 삭제할까요?'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('취소')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('삭제'))
                ]));
    if (ok == true) _clearCurrent();
  }

  Future<void> _confirmClearAll() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
                title: const Text('전체 문서 필기 지우기'),
                content: const Text('모든 페이지의 필기를 삭제할까요?'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('취소')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('삭제'))
                ]));
    if (ok != true || document == null) return;
    for (final key in pageKeys.values) {
      key.currentState?.clearStrokes();
    }
  }
}

class PdfDrawingToolbar extends StatelessWidget {
  const PdfDrawingToolbar(
      {required this.state,
      required this.onView,
      required this.onPenTypeChanged,
      required this.onPenWidthChanged,
      required this.onPresetChanged,
      required this.onShapeChanged,
      required this.onToolChanged,
      required this.onColorChanged,
      required this.onWidthChanged,
      required this.onOpacityChanged,
      required this.onUndo,
      required this.onRedo,
      required this.onClear,
      super.key});
  final PdfEditingState state;
  final VoidCallback onView;
  final ValueChanged<PenType> onPenTypeChanged;
  final ValueChanged<double> onPenWidthChanged;
  final ValueChanged<PenPreset> onPresetChanged;
  final ValueChanged<ShapeKind> onShapeChanged;
  final ValueChanged<DrawingTool> onToolChanged;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onWidthChanged;
  final ValueChanged<double> onOpacityChanged;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onClear;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[
      _section(context, [
        _viewButton(context),
        _button(context, DrawingTool.pen, _penIcon(state.selectedPenType), '펜'),
        _button(context, DrawingTool.highlighter, Icons.highlight, '형광펜'),
        _button(context, DrawingTool.eraser, Icons.auto_fix_normal, '지우개'),
        _button(context, DrawingTool.lasso, Icons.gesture, '올가미'),
        _button(context, DrawingTool.shape, Icons.shape_line_outlined, '도형'),
      ]),
      _divider(context),
      _presets(context),
      _divider(context),
      _section(context, [
        IconButton(
          onPressed: state.canUndo ? onUndo : null,
          tooltip: '실행 취소',
          style: IconButton.styleFrom(
              fixedSize: const Size.square(32),
              minimumSize: const Size(30, 30),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          icon: const Icon(Icons.undo, size: 18),
        ),
        IconButton(
          onPressed: state.canRedo ? onRedo : null,
          tooltip: '다시 실행',
          style: IconButton.styleFrom(
              fixedSize: const Size.square(32),
              minimumSize: const Size(30, 30),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          icon: const Icon(Icons.redo, size: 18),
        ),
      ]),
      _divider(context),
      IconButton(
        onPressed: onClear,
        tooltip: '현재 페이지 필기 지우기',
        style: IconButton.styleFrom(
            fixedSize: const Size.square(32),
            minimumSize: const Size(30, 30),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: scheme.error,
            backgroundColor: scheme.errorContainer.withValues(alpha: .55)),
        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
      ),
      PopupMenuButton<String>(
        tooltip: '더보기',
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'text', child: Text('텍스트 도구')),
          PopupMenuItem(value: 'image', child: Text('이미지')),
          PopupMenuItem(value: 'sticker', child: Text('스티커')),
        ],
        onSelected: (_) {},
        padding: EdgeInsets.zero,
        child: const SizedBox.square(
            dimension: 32,
            child: Center(child: Icon(Icons.more_horiz, size: 20))),
      ),
    ];
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          bottom: false,
          child: SizedBox(
            height: 60,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: children),
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, List<Widget> children) =>
      Row(children: children);

  Widget _divider(BuildContext context) => Container(
      width: 1,
      height: 28,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: Theme.of(context).colorScheme.outlineVariant);

  Widget _viewButton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = state.mode == PdfInteractionMode.view;
    return IconButton(
      onPressed: onView,
      tooltip: '보기 모드 · 페이지 이동/확대',
      style: IconButton.styleFrom(
          fixedSize: const Size.square(32),
          minimumSize: const Size(30, 30),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          backgroundColor: selected ? scheme.primaryContainer : null,
          foregroundColor: selected ? scheme.primary : null),
      icon: const Icon(Icons.pan_tool_outlined, size: 18),
    );
  }

  Widget _button(
    BuildContext context,
    DrawingTool tool,
    IconData icon,
    String label,
  ) {
    final selected =
        state.mode == PdfInteractionMode.draw && state.selectedTool == tool;
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '$label · 다시 누르면 설정',
      child: AnimatedContainer(
        width: 32,
        height: 32,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: IconButton(
          onPressed: () {
            if (state.mode == PdfInteractionMode.draw &&
                state.selectedTool == tool) {
              _showSettings(context, tool);
            } else {
              onToolChanged(tool);
            }
          },
          onLongPress: () => _showSettings(context, tool),
          style: IconButton.styleFrom(
            fixedSize: const Size.square(32),
            minimumSize: const Size(30, 30),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            side: BorderSide(color: Colors.transparent),
            backgroundColor: Colors.transparent,
            foregroundColor: selected ? scheme.primary : null,
          ),
          icon: Icon(icon, size: 18),
        ),
      ),
    );
  }

  Widget _presets(BuildContext context) => Row(
        children: [
          for (final preset in state.presets)
            Tooltip(
              message: '펜 프리셋 · ${_presetName(preset)}',
              child: IconButton(
                onPressed: () => onPresetChanged(preset),
                style: IconButton.styleFrom(
                    fixedSize: const Size.square(32),
                    minimumSize: const Size(30, 30),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                color: preset.color,
                icon: Icon(_presetIcon(preset), size: 19),
              ),
            ),
        ],
      );

  IconData _presetIcon(PenPreset preset) => switch (preset.type) {
        PenType.ballpoint => Icons.edit_outlined,
        PenType.fountain => Icons.draw_outlined,
        PenType.pencil => Icons.create_outlined,
        PenType.marker => Icons.border_color_outlined,
      };

  String _presetName(PenPreset preset) => switch (preset.type) {
        PenType.ballpoint => '볼펜',
        PenType.fountain => '만년필',
        PenType.pencil => '연필',
        PenType.marker => '마커',
      };

  Future<void> _showSettings(BuildContext context, DrawingTool tool) async {
    final panel = _settingsPanel(context, tool);
    if (MediaQuery.sizeOf(context).width >= 600) {
      await showDialog<void>(
          context: context, builder: (_) => AlertDialog(content: panel));
    } else {
      await showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (_) => SafeArea(child: panel));
    }
  }

  Widget _settingsPanel(BuildContext context, DrawingTool tool) {
    final isPen = tool == DrawingTool.pen;
    final isHighlighter = tool == DrawingTool.highlighter;
    final isShape = tool == DrawingTool.shape;
    final isEraser = tool == DrawingTool.eraser;
    final title = isPen
        ? '펜 설정'
        : isHighlighter
            ? '형광펜 설정'
            : isShape
                ? '도형 설정'
                : tool == DrawingTool.lasso
                    ? '올가미 설정'
                    : '지우개 설정';
    return StatefulBuilder(builder: (context, setPanelState) {
      final types = [
        (PenType.ballpoint, Icons.edit_outlined),
        (PenType.fountain, Icons.draw_outlined),
        (PenType.pencil, Icons.create_outlined),
        (PenType.marker, Icons.border_color_outlined),
      ];
      return SizedBox(
          width: 360,
          child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                if (isPen)
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        for (final item in types)
                          IconButton(
                              tooltip: '펜 종류',
                              onPressed: () {
                                onPenTypeChanged(item.$1);
                                setPanelState(() {});
                              },
                              color: state.selectedPenType == item.$1
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                              icon: Icon(item.$2)),
                      ]),
                if (isPen || isHighlighter || isShape)
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        for (final color in [
                          Colors.black,
                          Colors.red,
                          Colors.blue,
                          Colors.green,
                          Colors.yellow
                        ])
                          IconButton(
                              tooltip: '색상',
                              onPressed: () {
                                onColorChanged(color);
                                setPanelState(() {});
                              },
                              color: color,
                              icon: Icon(
                                  state.selectedColor == color
                                      ? Icons.radio_button_checked
                                      : Icons.circle,
                                  size: 22)),
                      ]),
                if (isShape)
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        for (final item in [
                          (ShapeKind.line, Icons.remove),
                          (ShapeKind.rectangle, Icons.crop_square),
                          (ShapeKind.ellipse, Icons.circle_outlined),
                          (ShapeKind.arrow, Icons.arrow_forward)
                        ])
                          IconButton(
                              tooltip: '도형 종류',
                              onPressed: () {
                                onShapeChanged(item.$1);
                                setPanelState(() {});
                              },
                              color: state.shapeKind == item.$1
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                              icon: Icon(item.$2)),
                      ]),
                if (isEraser)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('정밀 지우개 크기',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                Row(children: [
                  Icon(
                      isEraser
                          ? Icons.cleaning_services_outlined
                          : Icons.line_weight,
                      size: 18),
                  Expanded(
                      child: Slider(
                          min: isEraser
                              ? 1
                              : isHighlighter
                                  ? 4
                                  : isPen
                                      ? 1
                                      : 4,
                          max: isHighlighter
                              ? 30
                              : isPen
                                  ? 12
                                  : isEraser
                                      ? 50
                                      : 40,
                          value: state.strokeWidth.clamp(
                              isEraser
                                  ? 1
                                  : isHighlighter
                                      ? 4
                                      : isPen
                                          ? 1
                                          : 4,
                              isHighlighter
                                  ? 30
                                  : isPen
                                      ? 12
                                      : isEraser
                                          ? 50
                                          : 40),
                          onChanged: (value) {
                            if (isPen) {
                              onPenWidthChanged(value);
                            } else {
                              onWidthChanged(value);
                            }
                            setPanelState(() {});
                          })),
                  SizedBox(
                      width: 42,
                      child: Text('${state.strokeWidth.round()}px',
                          textAlign: TextAlign.end,
                          style: Theme.of(context).textTheme.labelSmall)),
                ]),
                if (isPen || isHighlighter || isShape)
                  Row(children: [
                    const Icon(Icons.opacity, size: 18),
                    Expanded(
                        child: Slider(
                            min: .1,
                            max: 1,
                            value: state.opacity.clamp(.1, 1),
                            onChanged: (value) {
                              onOpacityChanged(value);
                              setPanelState(() {});
                            }))
                  ]),
                if (isEraser)
                  TextButton.icon(
                      onPressed: onClear,
                      icon: const Icon(Icons.delete_sweep_outlined),
                      label: const Text('현재 페이지 모두 지우기')),
              ])));
    });
  }

  IconData _penIcon(PenType type) => switch (type) {
        PenType.ballpoint => Icons.edit_outlined,
        PenType.fountain => Icons.draw_outlined,
        PenType.pencil => Icons.create_outlined,
        PenType.marker => Icons.border_color_outlined,
      };
}

class PdfPageWithInk extends StatefulWidget {
  const PdfPageWithInk(
      {required this.document,
      required this.pageNumber,
      required this.documentId,
      required this.editMode,
      required this.tool,
      required this.penType,
      required this.color,
      required this.width,
      required this.opacity,
      required this.shapeKind,
      required this.onPageActivated,
      required this.onStateChanged,
      super.key});
  final PdfDocument document;
  final int pageNumber;
  final String documentId;
  final bool editMode;
  final DrawingTool tool;
  final PenType penType;
  final Color color;
  final double width;
  final double opacity;
  final ShapeKind shapeKind;
  final VoidCallback onPageActivated;
  final VoidCallback onStateChanged;
  @override
  State<PdfPageWithInk> createState() => _PdfPageWithInkState();
}

class _PdfPageWithInkState extends State<PdfPageWithInk> {
  final store = AnnotationStore();
  final strokes = <Stroke>[];
  final redoStrokes = <Stroke>[];
  final selectedStrokes = <Stroke>[];
  final active = <StrokePoint>[];
  Timer? saveTimer;
  Uint8List? image;
  double ratio = .707;
  bool loading = true;
  bool movingSelection = false;
  late final TransformationController transform;
  bool get canUndo => strokes.isNotEmpty;
  bool get canRedo => redoStrokes.isNotEmpty;
  @override
  void initState() {
    super.initState();
    transform = TransformationController();
    _load();
  }

  Future<void> _load() async {
    PdfPage? page;
    try {
      page = await widget.document
          .getPage(widget.pageNumber, autoCloseAndroid: false);
      ratio = page.width / page.height;
      final renderWidth = (page.width * 2).clamp(1.0, 1600.0).toDouble();
      final rendered = await page.render(
          width: renderWidth,
          height: page.height * renderWidth / page.width,
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF');
      image = rendered?.bytes;
      strokes.addAll(
          await store.load(widget.documentId, 'page_${widget.pageNumber}'));
    } catch (e, stack) {
      developer.log(
          'page render failed id=${widget.documentId} page=${widget.pageNumber}: $e',
          name: 'docnote.pdf',
          error: e,
          stackTrace: stack);
    } finally {
      if (page != null) await page.close();
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    saveTimer?.cancel();
    _save();
    transform.dispose();
    super.dispose();
  }

  Future<void> _save() =>
      store.save(widget.documentId, 'page_${widget.pageNumber}', strokes);

  Future<void> saveNow() async {
    saveTimer?.cancel();
    await _save();
  }

  Future<void> _schedule() async {
    saveTimer?.cancel();
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('docnote.settings.autoSave') ?? true) {
      saveTimer = Timer(const Duration(milliseconds: 500), _save);
    }
  }

  void _start(Offset p, double pressure, Size size) {
    widget.onPageActivated();
    if (widget.tool == DrawingTool.eraser) {
      _erase(p, size);
      return;
    }
    final normalized = normalizePoint(p, size, pressure: pressure);
    if (widget.tool == DrawingTool.lasso &&
        selectedStrokes.isNotEmpty &&
        _selectionContains(normalized)) {
      movingSelection = true;
      active
        ..clear()
        ..add(normalized);
      setState(() {});
      return;
    }
    active
      ..clear()
      ..add(normalized);
    setState(() {});
  }

  void _move(Offset p, double pressure, Size size) {
    if (widget.tool == DrawingTool.eraser) {
      _erase(p, size);
      return;
    }
    if (active.isNotEmpty) {
      final point = normalizePoint(p, size, pressure: pressure);
      if (movingSelection) {
        final previous = active.last;
        final dx = point.x - previous.x;
        final dy = point.y - previous.y;
        for (var index = 0; index < selectedStrokes.length; index++) {
          selectedStrokes[index] = _translated(selectedStrokes[index], dx, dy);
          final strokeIndex = strokes
              .indexWhere((stroke) => stroke.id == selectedStrokes[index].id);
          if (strokeIndex >= 0) strokes[strokeIndex] = selectedStrokes[index];
        }
        active
          ..clear()
          ..add(point);
        setState(() {});
        return;
      }
      if (widget.tool == DrawingTool.shape) {
        if (active.length == 1) {
          active.add(point);
        } else {
          active[1] = point;
        }
      } else {
        active.add(point);
      }
    }
    setState(() {});
  }

  void _end() {
    if (active.isEmpty) return;
    if (movingSelection) {
      movingSelection = false;
      active.clear();
      _schedule();
      widget.onStateChanged();
      if (mounted) setState(() {});
      return;
    }
    if (widget.tool == DrawingTool.lasso) {
      final selected = strokes.where((stroke) {
        return stroke.points.any((point) {
          final x = point.x;
          final y = point.y;
          final minX = active.map((item) => item.x).reduce(math.min);
          final maxX = active.map((item) => item.x).reduce(math.max);
          final minY = active.map((item) => item.y).reduce(math.min);
          final maxY = active.map((item) => item.y).reduce(math.max);
          return x >= minX && x <= maxX && y >= minY && y <= maxY;
        });
      }).toList();
      selectedStrokes
        ..clear()
        ..addAll(selected);
      active.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(mainAxisSize: MainAxisSize.min, children: [
            Expanded(child: Text('${selected.length}개 필기를 선택했습니다.')),
            if (selected.isNotEmpty) ...[
              TextButton(
                  onPressed: _duplicateSelection,
                  child:
                      const Text('복제', style: TextStyle(color: Colors.white))),
              TextButton(
                  onPressed: _deleteSelection,
                  child:
                      const Text('삭제', style: TextStyle(color: Colors.white))),
            ],
          ]),
          duration: const Duration(seconds: 4),
        ));
        setState(() {});
      }
      return;
    }
    strokes.add(Stroke(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        documentId: widget.documentId,
        pageId: 'page_${widget.pageNumber}',
        tool: _strokeTool,
        penType: widget.penType,
        points: List.of(active),
        color: widget.color,
        width: widget.width,
        opacity: widget.opacity,
        order: strokes.length,
        createdAt: DateTime.now()));
    redoStrokes.clear();
    active.clear();
    _schedule();
    widget.onStateChanged();
    setState(() {});
  }

  bool _selectionContains(StrokePoint point) {
    final minX = selectedStrokes
        .expand((stroke) => stroke.points)
        .map((item) => item.x)
        .reduce(math.min);
    final maxX = selectedStrokes
        .expand((stroke) => stroke.points)
        .map((item) => item.x)
        .reduce(math.max);
    final minY = selectedStrokes
        .expand((stroke) => stroke.points)
        .map((item) => item.y)
        .reduce(math.min);
    final maxY = selectedStrokes
        .expand((stroke) => stroke.points)
        .map((item) => item.y)
        .reduce(math.max);
    return point.x >= minX &&
        point.x <= maxX &&
        point.y >= minY &&
        point.y <= maxY;
  }

  Stroke _translated(Stroke stroke, double dx, double dy) => Stroke(
        id: stroke.id,
        documentId: stroke.documentId,
        pageId: stroke.pageId,
        tool: stroke.tool,
        penType: stroke.penType,
        points: stroke.points
            .map((point) => StrokePoint((point.x + dx).clamp(0.0, 1.0),
                (point.y + dy).clamp(0.0, 1.0), point.pressure))
            .toList(),
        color: stroke.color,
        width: stroke.width,
        opacity: stroke.opacity,
        order: stroke.order,
        createdAt: stroke.createdAt,
      );

  void _duplicateSelection() {
    if (selectedStrokes.isEmpty) return;
    final copies = selectedStrokes
        .map((stroke) => _translated(
            Stroke(
              id: '${DateTime.now().microsecondsSinceEpoch}_${stroke.id}',
              documentId: stroke.documentId,
              pageId: stroke.pageId,
              tool: stroke.tool,
              penType: stroke.penType,
              points: stroke.points,
              color: stroke.color,
              width: stroke.width,
              opacity: stroke.opacity,
              order: strokes.length,
              createdAt: DateTime.now(),
            ),
            .02,
            .02))
        .toList();
    strokes.addAll(copies);
    selectedStrokes
      ..clear()
      ..addAll(copies);
    redoStrokes.clear();
    _schedule();
    widget.onStateChanged();
    if (mounted) setState(() {});
  }

  void _deleteSelection() {
    if (selectedStrokes.isEmpty) return;
    final ids = selectedStrokes.map((stroke) => stroke.id).toSet();
    strokes.removeWhere((stroke) => ids.contains(stroke.id));
    selectedStrokes.clear();
    redoStrokes.clear();
    _schedule();
    widget.onStateChanged();
    if (mounted) setState(() {});
  }

  StrokeTool get _strokeTool => switch (widget.tool) {
        DrawingTool.highlighter => StrokeTool.highlighter,
        DrawingTool.eraser => StrokeTool.eraser,
        DrawingTool.shape => switch (widget.shapeKind) {
            ShapeKind.line => StrokeTool.shapeLine,
            ShapeKind.rectangle => StrokeTool.shapeRectangle,
            ShapeKind.ellipse => StrokeTool.shapeEllipse,
            ShapeKind.arrow => StrokeTool.shapeArrow,
          },
        DrawingTool.lasso => StrokeTool.lasso,
        _ => StrokeTool.pen
      };
  void _erase(Offset p, Size size) {
    final n = normalizePoint(p, size);
    final radius = (widget.width / size.width).clamp(.002, .12);
    final kept = <Stroke>[];
    var changed = false;
    for (final stroke in strokes) {
      final segments = <List<StrokePoint>>[];
      var segment = <StrokePoint>[];
      for (final point in stroke.points) {
        final dx = point.x - n.x;
        final dy = point.y - n.y;
        if (dx * dx + dy * dy <= radius * radius) {
          changed = true;
          if (segment.isNotEmpty) segments.add(segment);
          segment = <StrokePoint>[];
        } else {
          segment.add(point);
        }
      }
      if (segment.isNotEmpty) segments.add(segment);
      if (segments.length == 1 &&
          segments.single.length == stroke.points.length) {
        kept.add(stroke);
        continue;
      }
      for (var index = 0; index < segments.length; index++) {
        final points = segments[index];
        if (points.isEmpty) continue;
        kept.add(Stroke(
          id: '${stroke.id}_erase_$index',
          documentId: stroke.documentId,
          pageId: stroke.pageId,
          tool: stroke.tool,
          penType: stroke.penType,
          points: points,
          color: stroke.color,
          width: stroke.width,
          opacity: stroke.opacity,
          order: kept.length,
          createdAt: stroke.createdAt,
        ));
      }
    }
    if (changed) {
      strokes
        ..clear()
        ..addAll(kept);
      redoStrokes.clear();
      _schedule();
      widget.onStateChanged();
      setState(() {});
    }
  }

  void undo() {
    if (strokes.isEmpty) return;
    redoStrokes.add(strokes.removeLast());
    _schedule();
    widget.onStateChanged();
    setState(() {});
  }

  void redo() {
    if (redoStrokes.isEmpty) return;
    strokes.add(redoStrokes.removeLast());
    _schedule();
    widget.onStateChanged();
    setState(() {});
  }

  void clearStrokes() {
    if (strokes.isEmpty) return;
    redoStrokes.addAll(strokes);
    strokes.clear();
    _schedule();
    widget.onStateChanged();
    setState(() {});
  }

  void cancelActiveStroke() {
    active.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
          padding: EdgeInsets.all(24),
          child: AspectRatio(
              aspectRatio: .707,
              child: Center(child: CircularProgressIndicator())));
    }
    if (image == null) {
      return const Padding(
          padding: EdgeInsets.all(24),
          child: Text('페이지를 렌더링할 수 없습니다.', textAlign: TextAlign.center));
    }
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: LayoutBuilder(builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxWidth / ratio);
          final content = SizedBox(
              width: size.width,
              height: size.height,
              child: Stack(children: [
                Positioned.fill(child: Image.memory(image!, fit: BoxFit.fill)),
                Positioned.fill(
                    child: IgnorePointer(
                        ignoring: !widget.editMode,
                        child: DrawingCanvas(
                            strokes: strokes,
                            activePoints: active,
                            tool: _strokeTool,
                            penType: widget.penType,
                            color: widget.color,
                            width: widget.width,
                            onStart: _start,
                            onMove: _move,
                            onEnd: _end)))
              ]));
          return InteractiveViewer(
              transformationController: transform,
              panEnabled: !widget.editMode,
              scaleEnabled: !widget.editMode,
              minScale: 1,
              maxScale: 5,
              child: GestureDetector(
                  onTap: widget.onPageActivated, child: content));
        }));
  }
}
