import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/annotation_store.dart';
import '../domain/drawing_shape.dart';
import '../domain/drawing_text.dart';
import '../domain/drawing_image.dart';
import '../domain/stroke.dart';

class DrawingEditorPage extends StatefulWidget {
  const DrawingEditorPage(
      {required this.documentId,
      required this.title,
      this.initialPageCount = 1,
      this.pageTemplateId = 'blank',
      this.onPageCountChanged,
      this.onTitleChanged,
      super.key});
  final String documentId;
  final String title;
  final int initialPageCount;
  final String pageTemplateId;
  final ValueChanged<int>? onPageCountChanged;
  final Future<void> Function(String title)? onTitleChanged;
  @override
  State<DrawingEditorPage> createState() => _DrawingEditorPageState();
}

class _DrawingEditorPageState extends State<DrawingEditorPage>
    with WidgetsBindingObserver {
  final store = AnnotationStore();
  final strokes = <Stroke>[];
  final shapes = <DrawingShape>[];
  final texts = <DrawingText>[];
  final images = <DrawingImage>[];
  final imageCache = <String, ui.Image>{};
  final undoHistory = <_PageSnapshot>[];
  final redoHistory = <_PageSnapshot>[];
  final active = <StrokePoint>[];
  final lassoPath = <StrokePoint>[];
  final selectedStrokeIds = <String>{};
  final selectedShapeIds = <String>{};
  final selectedTextIds = <String>{};
  final selectedImageIds = <String>{};
  bool pickingImage = false;
  DrawingText? editingText;
  _PageSnapshot? textEditBaseline;
  final textController = TextEditingController();
  final textFocus = FocusNode();
  double textFontSize = 18;
  _PageSnapshot? selectionMoveBaseline;
  _PageSnapshot? eraserBaseline;
  StrokePoint? selectionMoveOrigin;
  Rect? selectionMoveBounds;
  bool movingSelection = false;
  bool resizingSelection = false;
  bool rotatingSelection = false;
  double rotationStartAngle = 0;
  DrawingShapeType shapeType = DrawingShapeType.line;
  DrawingShape? activeShape;
  Timer? saveTimer;
  StrokeTool tool = StrokeTool.pen;
  Color penColor = Colors.black;
  Color highlighterColor = const Color(0xffd58b3a);
  double penWidth = 3;
  double highlighterWidth = 8;
  double eraserWidth = 10;
  bool loaded = false;
  bool toolbarVisible = true;
  late int pageCount = widget.initialPageCount;
  late String title = widget.title;
  int pageIndex = 1;
  String get pageId => 'page_$pageIndex';
  double get activeWidth => switch (tool) {
        StrokeTool.eraser => eraserWidth,
        StrokeTool.highlighter => highlighterWidth,
        StrokeTool.text => textFontSize,
        _ => penWidth,
      };
  Color get activeColor =>
      tool == StrokeTool.highlighter ? highlighterColor : penColor;

  void _setTool(StrokeTool next) {
    if (next != StrokeTool.text) _finishTextEdit();
    setState(() {
      tool = next;
      active.clear();
      activeShape = null;
      if (next != StrokeTool.lasso) _clearSelectionState();
    });
  }

  void _cancelCanvasInputForViewportGesture() {
    if (active.isEmpty && activeShape == null && lassoPath.isEmpty) return;
    active.clear();
    activeShape = null;
    lassoPath.clear();
    setState(() {});
  }

  void _setWidth(double value) => setState(() {
        switch (tool) {
          case StrokeTool.eraser:
            eraserWidth = value;
          case StrokeTool.highlighter:
            highlighterWidth = value;
          case StrokeTool.text:
            textFontSize = value;
          default:
            penWidth = value;
        }
      });
  void _setColorForTool(StrokeTool target, Color value) => setState(() {
        if (target == StrokeTool.highlighter) {
          highlighterColor = value;
        } else {
          penColor = value;
        }
      });

  Future<void> _showColorPalette() async {
    final targetTool = tool;
    if (targetTool == StrokeTool.eraser) return;
    final currentColor =
        targetTool == StrokeTool.highlighter ? highlighterColor : penColor;
    final selected = await showModalBottomSheet<Color>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text('색상',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final swatch in const [
                  Colors.black,
                  Color(0xff3f6f9f),
                  Color(0xffc95656),
                  Color(0xff4e8b68),
                  Color(0xffd58b3a),
                ])
                  _PaletteColorButton(
                    color: swatch,
                    selected: swatch == currentColor,
                    onTap: () => Navigator.pop(sheetContext, swatch),
                  ),
              ],
            ),
          ]),
        ),
      ),
    );
    if (selected != null && mounted) _setColorForTool(targetTool, selected);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    final page = await store.loadPage(widget.documentId, pageId);
    strokes.addAll(page.strokes);
    shapes.addAll(page.shapes);
    texts.addAll(page.texts);
    images.addAll(page.images);
    await _preloadImages(page.images);
    if (mounted) setState(() => loaded = true);
  }

  Future<void> _preloadImages(Iterable<DrawingImage> values) async {
    for (final image in values) {
      if (imageCache.containsKey(image.imagePath)) continue;
      try {
        final bytes = await File(image.imagePath).readAsBytes();
        imageCache[image.imagePath] = await _decodeImage(bytes);
      } catch (_) {
        // The painter renders a safe placeholder when an external file is gone.
      }
    }
  }

  Future<ui.Image> _decodeImage(Uint8List bytes) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    return completer.future;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    saveTimer?.cancel();
    textController.dispose();
    textFocus.dispose();
    _save();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _save();
    }
  }

  Future<void> _scheduleSave() async {
    saveTimer?.cancel();
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('docnote.settings.autoSave') ?? true) {
      saveTimer = Timer(const Duration(milliseconds: 500), _save);
    }
  }

  Future<void> _save() => store.savePage(
      widget.documentId,
      pageId,
      DrawingPageData(
          strokes: strokes, shapes: shapes, texts: texts, images: images));

  _PageSnapshot _snapshot() => _PageSnapshot(
      strokes: List.of(strokes),
      shapes: List.of(shapes),
      texts: List.of(texts),
      images: List.of(images));

  void _recordHistory([_PageSnapshot? before]) {
    undoHistory.add(before ?? _snapshot());
    if (undoHistory.length > 80) undoHistory.removeAt(0);
    redoHistory.clear();
  }

  void _replacePage(_PageSnapshot snapshot) {
    strokes
      ..clear()
      ..addAll(snapshot.strokes);
    shapes
      ..clear()
      ..addAll(snapshot.shapes);
    texts
      ..clear()
      ..addAll(snapshot.texts);
    images
      ..clear()
      ..addAll(snapshot.images);
  }

  void _replaceLoadedPage(DrawingPageData page) => _replacePage(_PageSnapshot(
      strokes: page.strokes,
      shapes: page.shapes,
      texts: page.texts,
      images: page.images));

  void _clearSelectionState() {
    lassoPath.clear();
    selectedStrokeIds.clear();
    selectedShapeIds.clear();
    selectedTextIds.clear();
    selectedImageIds.clear();
    selectionMoveBaseline = null;
    selectionMoveOrigin = null;
    selectionMoveBounds = null;
    movingSelection = false;
    resizingSelection = false;
    rotatingSelection = false;
    rotationStartAngle = 0;
  }

  Rect? _selectedBounds() {
    final points = <StrokePoint>[];
    for (final stroke in strokes) {
      if (selectedStrokeIds.contains(stroke.id)) points.addAll(stroke.points);
    }
    for (final shape in shapes) {
      if (selectedShapeIds.contains(shape.id)) {
        points.addAll(_shapeSelectionPoints(shape));
      }
    }
    for (final text in texts) {
      if (selectedTextIds.contains(text.id)) {
        final rect = _textRectNormalized(text);
        points.addAll([
          StrokePoint(rect.left, rect.top, 1),
          StrokePoint(rect.right, rect.bottom, 1)
        ]);
      }
    }
    for (final image in images) {
      if (selectedImageIds.contains(image.id)) {
        final rect = _imageRectNormalized(image);
        points.addAll([
          StrokePoint(rect.left, rect.top, 1),
          StrokePoint(rect.right, rect.bottom, 1),
        ]);
      }
    }
    if (points.isEmpty) return null;
    var left = points.first.x;
    var right = points.first.x;
    var top = points.first.y;
    var bottom = points.first.y;
    for (final point in points.skip(1)) {
      left = math.min(left, point.x);
      right = math.max(right, point.x);
      top = math.min(top, point.y);
      bottom = math.max(bottom, point.y);
    }
    return Rect.fromLTRB(left, top, right, bottom).inflate(.015);
  }

  void _scheduleRenameTitle() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _renameTitle();
    });
  }

  Future<void> _renameTitle() async {
    final controller = TextEditingController(text: title);
    final next = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('노트 이름 변경'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 1,
          decoration: const InputDecoration(labelText: '노트 제목'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('저장')),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), controller.dispose);
    final trimmed = next?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == title) return;
    if (!mounted) return;
    setState(() => title = trimmed);
    await widget.onTitleChanged?.call(trimmed);
  }

  Future<void> _switchPage(int next) async {
    if (next < 1 || next > pageCount || next == pageIndex) return;
    await _save();
    saveTimer?.cancel();
    active.clear();
    activeShape = null;
    _replaceLoadedPage(await store.loadPage(widget.documentId, 'page_$next'));
    await _preloadImages(images);
    undoHistory.clear();
    redoHistory.clear();
    _clearSelectionState();
    if (mounted) setState(() => pageIndex = next);
  }

  Future<void> _addPage() async {
    await _save();
    saveTimer?.cancel();
    pageCount++;
    pageIndex = pageCount;
    strokes.clear();
    shapes.clear();
    activeShape = null;
    undoHistory.clear();
    redoHistory.clear();
    _clearSelectionState();
    widget.onPageCountChanged?.call(pageCount);
    if (mounted) setState(() {});
  }

  Future<void> _deletePage() => _deletePageAt(pageIndex);

  Future<void> _showPageNavigator() => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (sheetContext) => _PageNavigatorSheet(
          documentId: widget.documentId,
          pageCount: pageCount,
          selectedPage: pageIndex,
          templateId: widget.pageTemplateId,
          onPageSelected: (next) async {
            Navigator.of(sheetContext).pop();
            await _switchPage(next);
          },
          onAddPage: () async {
            Navigator.of(sheetContext).pop();
            await _addPage();
          },
          onDuplicatePage: (sourcePage) async {
            Navigator.of(sheetContext).pop();
            await _duplicatePage(sourcePage);
          },
          onDeletePage: (targetPage) async {
            Navigator.of(sheetContext).pop();
            await _deletePageAt(targetPage);
          },
        ),
      );

  Future<void> _duplicatePage(int sourcePage) async {
    await _save();
    final source = await store.loadPage(widget.documentId, 'page_$sourcePage');
    final target = pageCount + 1;
    await store.savePage(widget.documentId, 'page_$target', source);
    pageCount = target;
    widget.onPageCountChanged?.call(pageCount);
    if (mounted) setState(() {});
  }

  Future<void> _deletePageAt(int targetPage) async {
    if (pageCount <= 1) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('페이지 삭제'),
        content: Text('$targetPage번 페이지를 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _save();
    await store.deleteNotebookPageAndShift(
      widget.documentId,
      removedPage: targetPage,
      pageCount: pageCount,
    );
    pageCount--;
    pageIndex = math.min(targetPage, pageCount);
    _replaceLoadedPage(await store.loadPage(widget.documentId, pageId));
    await _preloadImages(images);
    undoHistory.clear();
    redoHistory.clear();
    _clearSelectionState();
    widget.onPageCountChanged?.call(pageCount);
    if (mounted) setState(() {});
  }

  void _start(Offset p, double pressure, Size size) {
    if (tool == StrokeTool.shapeLine ||
        tool == StrokeTool.shapeRectangle ||
        tool == StrokeTool.shapeEllipse ||
        tool == StrokeTool.shapeArrow) {
      _shapeStart(p, size);
      return;
    }
    if (tool == StrokeTool.eraser) {
      eraserBaseline = _snapshot();
      _erase(p, size);
      return;
    }
    active
      ..clear()
      ..add(normalizePoint(p, size, pressure: pressure));
    setState(() {});
  }

  void _move(Offset p, double pressure, Size size) {
    if (tool == StrokeTool.shapeLine ||
        tool == StrokeTool.shapeRectangle ||
        tool == StrokeTool.shapeEllipse ||
        tool == StrokeTool.shapeArrow) {
      _shapeMove(p, size);
      return;
    }
    if (tool == StrokeTool.eraser) {
      _erase(p, size);
      return;
    }
    if (active.isEmpty) return;
    final next = normalizePoint(p, size, pressure: pressure);
    final previous = active.last;
    // Keep the latest pressure sample but avoid storing near-identical move
    // events. This reduces stroke size and repaint work without changing the
    // normalized coordinate model or the visible path.
    if ((next.x - previous.x) * (next.x - previous.x) +
            (next.y - previous.y) * (next.y - previous.y) <
        .0000015) {
      active[active.length - 1] = next;
    } else {
      active.add(next);
    }
    setState(() {});
  }

  void _end() {
    if (tool == StrokeTool.shapeLine ||
        tool == StrokeTool.shapeRectangle ||
        tool == StrokeTool.shapeEllipse ||
        tool == StrokeTool.shapeArrow) {
      _shapeEnd();
      return;
    }
    if (tool == StrokeTool.eraser) {
      final baseline = eraserBaseline;
      if (baseline != null && !_samePages(baseline, _snapshot())) {
        _recordHistory(baseline);
      }
      eraserBaseline = null;
      return;
    }
    if (active.isEmpty) return;
    _recordHistory();
    strokes.add(Stroke(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        documentId: widget.documentId,
        pageId: pageId,
        tool: tool,
        points: List.of(active),
        color: activeColor,
        width: activeWidth,
        opacity: tool == StrokeTool.highlighter ? .35 : 1,
        order: strokes.length,
        createdAt: DateTime.now()));
    active.clear();
    _scheduleSave();
    setState(() {});
  }

  void _shapeStart(Offset point, Size size) {
    final normalized = normalizePoint(point, size);
    activeShape = DrawingShape(
      id: 'active-shape',
      documentId: widget.documentId,
      pageId: pageId,
      type: shapeType,
      startPoint: normalized,
      endPoint: normalized,
      color: penColor,
      strokeWidth: penWidth,
      order: shapes.length,
      createdAt: DateTime.now(),
    );
    setState(() {});
  }

  void _shapeMove(Offset point, Size size) {
    final shape = activeShape;
    if (shape == null) return;
    activeShape = shape.copyWith(endPoint: normalizePoint(point, size));
    setState(() {});
  }

  void _shapeEnd() {
    final shape = activeShape;
    activeShape = null;
    if (shape == null ||
        (shape.startPoint.x == shape.endPoint.x &&
            shape.startPoint.y == shape.endPoint.y)) {
      setState(() {});
      return;
    }
    _recordHistory();
    shapes.add(DrawingShape(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      documentId: shape.documentId,
      pageId: shape.pageId,
      type: shape.type,
      startPoint: shape.startPoint,
      endPoint: shape.endPoint,
      color: shape.color,
      strokeWidth: shape.strokeWidth,
      order: shapes.length,
      createdAt: shape.createdAt,
    ));
    _scheduleSave();
    setState(() {});
  }

  void _setShapeType(DrawingShapeType value) => setState(() {
        shapeType = value;
        tool = switch (value) {
          DrawingShapeType.line => StrokeTool.shapeLine,
          DrawingShapeType.rectangle => StrokeTool.shapeRectangle,
          DrawingShapeType.ellipse => StrokeTool.shapeEllipse,
          DrawingShapeType.arrow => StrokeTool.shapeArrow,
        };
        activeShape = null;
      });

  void _erase(Offset p, Size size) {
    final n = normalizePoint(p, size);
    final radius = (activeWidth / size.width).clamp(.002, .12);
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
      _scheduleSave();
      setState(() {});
    }
  }

  void _textTap(Offset point, Size size) {
    if (editingText != null) _finishTextEdit();
    final normalized = normalizePoint(point, size);
    final hit = texts.cast<DrawingText?>().firstWhere(
        (text) =>
            text != null && _textRect(text, size).inflate(8).contains(point),
        orElse: () => null);
    _clearSelectionState();
    textEditBaseline = _snapshot();
    editingText = hit ??
        DrawingText(
          id: '${DateTime.now().microsecondsSinceEpoch}',
          documentId: widget.documentId,
          pageId: pageId,
          text: '',
          position: normalized,
          fontSize: textFontSize,
          color: penColor,
          maxWidth: (1 - normalized.x - .04).clamp(.16, .92),
          order: texts.length,
          createdAt: DateTime.now(),
        );
    textController
      ..text = hit?.text ?? ''
      ..selection = TextSelection.collapsed(offset: hit?.text.length ?? 0);
    setState(() {});
    WidgetsBinding.instance
        .addPostFrameCallback((_) => textFocus.requestFocus());
  }

  void _finishTextEdit() {
    final editing = editingText;
    if (editing == null) return;
    final next = textController.text.trimRight();
    final baseline = textEditBaseline;
    final existing = texts.indexWhere((text) => text.id == editing.id);
    if (next.isNotEmpty) {
      final value = editing.copyWith(text: next);
      if (existing >= 0) {
        texts[existing] = value;
      } else {
        texts.add(value);
      }
      if (baseline != null) _recordHistory(baseline);
      _scheduleSave();
    } else if (existing >= 0) {
      texts.removeAt(existing);
      if (baseline != null) _recordHistory(baseline);
      _scheduleSave();
    }
    editingText = null;
    textEditBaseline = null;
    textFocus.unfocus();
    if (mounted) setState(() {});
  }

  Future<void> _imageTap(Offset point, Size size) async {
    if (pickingImage) return;
    pickingImage = true;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
      );
      final path = result?.files.single.path;
      if (path == null || !mounted) return;
      final source = File(path);
      final saved = await store.copyImageAttachment(widget.documentId, source);
      final decoded = await _decodeImage(await saved.readAsBytes());
      final aspect = decoded.height / decoded.width;
      const width = .45;
      final height = (width * aspect * .7).clamp(.12, .62);
      final normalized = normalizePoint(point, size);
      final left = normalized.x.clamp(0.0, 1 - width).toDouble();
      final top = normalized.y.clamp(0.0, 1 - height).toDouble();
      _recordHistory();
      final image = DrawingImage(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        documentId: widget.documentId,
        pageId: pageId,
        imagePath: saved.path,
        position: StrokePoint(left, top, 1),
        width: width,
        height: height,
        order: images.length,
        createdAt: DateTime.now(),
      );
      imageCache[saved.path] = decoded;
      images.add(image);
      _clearSelectionState();
      selectedImageIds.add(image.id);
      _scheduleSave();
      setState(() {});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('이미지를 불러오지 못했습니다.')));
      }
    } finally {
      pickingImage = false;
    }
  }

  void _undo() {
    if (undoHistory.isEmpty) return;
    redoHistory.add(_snapshot());
    _replacePage(undoHistory.removeLast());
    _clearSelectionState();
    _scheduleSave();
    setState(() {});
  }

  void _redo() {
    if (redoHistory.isEmpty) return;
    undoHistory.add(_snapshot());
    _replacePage(redoHistory.removeLast());
    _clearSelectionState();
    _scheduleSave();
    setState(() {});
  }

  void _selectionStart(Offset point, Size size) {
    final normalized = normalizePoint(point, size);
    final bounds = _selectedBounds();
    final touchesResizeHandle = bounds != null &&
        ((selectedStrokeIds.isEmpty && selectedShapeIds.isNotEmpty) ||
            (selectedStrokeIds.isEmpty &&
                selectedShapeIds.isEmpty &&
                selectedTextIds.isEmpty &&
                selectedImageIds.length == 1)) &&
        _resizeHandleHit(bounds, normalized);
    final touchesRotateHandle = bounds != null &&
        selectedStrokeIds.isEmpty &&
        selectedShapeIds.isNotEmpty &&
        _rotationHandleHit(bounds, normalized);
    if (bounds != null &&
        (bounds.contains(Offset(normalized.x, normalized.y)) ||
            touchesResizeHandle ||
            touchesRotateHandle)) {
      rotatingSelection = touchesRotateHandle;
      resizingSelection = !rotatingSelection && touchesResizeHandle;
      movingSelection = !rotatingSelection && !resizingSelection;
      selectionMoveOrigin = normalized;
      selectionMoveBounds = bounds;
      selectionMoveBaseline = _snapshot();
      if (rotatingSelection) {
        rotationStartAngle = _selectionAngle(bounds, normalized);
      }
      lassoPath.clear();
    } else {
      _clearSelectionState();
      lassoPath.add(normalized);
    }
    setState(() {});
  }

  void _selectionMove(Offset point, Size size) {
    final normalized = normalizePoint(point, size);
    if (!movingSelection && !resizingSelection && !rotatingSelection) {
      lassoPath.add(normalized);
      setState(() {});
      return;
    }
    final origin = selectionMoveOrigin;
    final bounds = selectionMoveBounds;
    final baseline = selectionMoveBaseline;
    if (origin == null || bounds == null || baseline == null) return;
    if (rotatingSelection) {
      final delta = _selectionAngle(bounds, normalized) - rotationStartAngle;
      final pivot = StrokePoint(bounds.center.dx, bounds.center.dy, 1);
      _replacePage(_PageSnapshot(
        strokes: baseline.strokes,
        shapes: baseline.shapes.map((shape) {
          if (!selectedShapeIds.contains(shape.id)) return shape;
          return _rotatedShape(shape, pivot, delta);
        }).toList(),
        texts: baseline.texts,
        images: baseline.images,
      ));
      setState(() {});
      return;
    }
    if (resizingSelection) {
      final targetX = normalized.x.clamp(bounds.left + .02, 1.0);
      final targetY = normalized.y.clamp(bounds.top + .02, 1.0);
      final scaleX = (targetX - bounds.left) / bounds.width;
      final scaleY = (targetY - bounds.top) / bounds.height;
      _replacePage(_PageSnapshot(
        strokes: baseline.strokes,
        shapes: baseline.shapes.map((shape) {
          if (!selectedShapeIds.contains(shape.id)) return shape;
          return shape.copyWith(
            startPoint: _scaledPoint(shape.startPoint, bounds, scaleX, scaleY),
            endPoint: _scaledPoint(shape.endPoint, bounds, scaleX, scaleY),
          );
        }).toList(),
        texts: baseline.texts,
        images: baseline.images.map((image) {
          if (!selectedImageIds.contains(image.id)) return image;
          final aspect = image.height / image.width;
          final width =
              (targetX - bounds.left).clamp(.08, 1 - image.position.x);
          final height = (width * aspect).clamp(.05, 1 - image.position.y);
          return image.copyWith(width: width, height: height);
        }).toList(),
      ));
      setState(() {});
      return;
    }
    final rawDx =
        (normalized.x - origin.x).clamp(-bounds.left, 1 - bounds.right);
    final rawDy =
        (normalized.y - origin.y).clamp(-bounds.top, 1 - bounds.bottom);
    final dx = _snappedSelectionDelta(rawDx, bounds.left, bounds.right);
    final dy = _snappedSelectionDelta(rawDy, bounds.top, bounds.bottom);
    _replacePage(_PageSnapshot(
      strokes: baseline.strokes.map((stroke) {
        if (!selectedStrokeIds.contains(stroke.id)) return stroke;
        return _strokeWithPoints(
            stroke,
            stroke.points
                .map((p) => StrokePoint(p.x + dx, p.y + dy, p.pressure))
                .toList());
      }).toList(),
      shapes: baseline.shapes.map((shape) {
        if (!selectedShapeIds.contains(shape.id)) return shape;
        return shape.copyWith(
          startPoint: _translatedPoint(shape.startPoint, dx, dy),
          endPoint: _translatedPoint(shape.endPoint, dx, dy),
        );
      }).toList(),
      texts: baseline.texts
          .map((text) => selectedTextIds.contains(text.id)
              ? text.copyWith(position: _translatedPoint(text.position, dx, dy))
              : text)
          .toList(),
      images: baseline.images
          .map((image) => selectedImageIds.contains(image.id)
              ? image.copyWith(
                  position: _translatedPoint(image.position, dx, dy))
              : image)
          .toList(),
    ));
    setState(() {});
  }

  void _selectionEnd() {
    if (movingSelection || resizingSelection || rotatingSelection) {
      final baseline = selectionMoveBaseline;
      if (baseline != null && !_samePages(baseline, _snapshot())) {
        _recordHistory(baseline);
        _scheduleSave();
      }
      selectionMoveBaseline = null;
      selectionMoveOrigin = null;
      selectionMoveBounds = null;
      movingSelection = false;
      resizingSelection = false;
      rotatingSelection = false;
      setState(() {});
      return;
    }
    if (lassoPath.length < 3) {
      _clearSelectionState();
      setState(() {});
      return;
    }
    selectedStrokeIds
      ..clear()
      ..addAll(strokes
          .where((stroke) => _strokeIsInsideLasso(stroke, lassoPath))
          .map((stroke) => stroke.id));
    selectedShapeIds
      ..clear()
      ..addAll(shapes
          .where((shape) => _shapeIsInsideLasso(shape, lassoPath))
          .map((shape) => shape.id));
    selectedTextIds
      ..clear()
      ..addAll(texts
          .where((text) => _textIsInsideLasso(text, lassoPath))
          .map((text) => text.id));
    selectedImageIds
      ..clear()
      ..addAll(images
          .where((image) => _imageIsInsideLasso(image, lassoPath))
          .map((image) => image.id));
    lassoPath.clear();
    if (selectedStrokeIds.isNotEmpty ||
        selectedShapeIds.isNotEmpty ||
        selectedTextIds.isNotEmpty ||
        selectedImageIds.isNotEmpty) {
      HapticFeedback.selectionClick();
    }
    setState(() {});
  }

  void _deleteSelection() {
    if (selectedStrokeIds.isEmpty &&
        selectedShapeIds.isEmpty &&
        selectedTextIds.isEmpty &&
        selectedImageIds.isEmpty) return;
    _recordHistory();
    strokes.removeWhere((stroke) => selectedStrokeIds.contains(stroke.id));
    shapes.removeWhere((shape) => selectedShapeIds.contains(shape.id));
    texts.removeWhere((text) => selectedTextIds.contains(text.id));
    images.removeWhere((image) => selectedImageIds.contains(image.id));
    _clearSelectionState();
    _scheduleSave();
    setState(() {});
  }

  void _duplicateSelection() {
    if (selectedStrokeIds.isEmpty &&
        selectedShapeIds.isEmpty &&
        selectedTextIds.isEmpty &&
        selectedImageIds.isEmpty) return;
    final bounds = _selectedBounds();
    if (bounds == null) return;
    _recordHistory();
    final dx = math.min(.03, 1 - bounds.right);
    final dy = math.min(.03, 1 - bounds.bottom);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final copiedStrokeIds = <String>{};
    final copiedShapeIds = <String>{};
    final copiedTextIds = <String>{};
    final copiedImageIds = <String>{};
    final copiedStrokes = strokes
        .where((stroke) => selectedStrokeIds.contains(stroke.id))
        .map((stroke) {
      final id = '${stroke.id}_copy_$stamp';
      copiedStrokeIds.add(id);
      return Stroke(
        id: id,
        documentId: stroke.documentId,
        pageId: stroke.pageId,
        tool: stroke.tool,
        penType: stroke.penType,
        points: stroke.points
            .map((point) => _translatedPoint(point, dx, dy))
            .toList(),
        color: stroke.color,
        width: stroke.width,
        opacity: stroke.opacity,
        order: strokes.length + copiedStrokeIds.length - 1,
        createdAt: DateTime.now(),
      );
    });
    final copiedShapes = shapes
        .where((shape) => selectedShapeIds.contains(shape.id))
        .map((shape) {
      final id = '${shape.id}_copy_$stamp';
      copiedShapeIds.add(id);
      return DrawingShape(
        id: id,
        documentId: shape.documentId,
        pageId: shape.pageId,
        type: shape.type,
        startPoint: _translatedPoint(shape.startPoint, dx, dy),
        endPoint: _translatedPoint(shape.endPoint, dx, dy),
        color: shape.color,
        strokeWidth: shape.strokeWidth,
        rotationRadians: shape.rotationRadians,
        order: shapes.length + copiedShapeIds.length - 1,
        createdAt: DateTime.now(),
      );
    });
    final copiedTexts = texts
        .where((text) => selectedTextIds.contains(text.id))
        .map((text) {
      final id = '${text.id}_copy_$stamp';
      copiedTextIds.add(id);
      return DrawingText(
        id: id,
        documentId: text.documentId,
        pageId: text.pageId,
        text: text.text,
        position: _translatedPoint(text.position, dx, dy),
        fontSize: text.fontSize,
        color: text.color,
        maxWidth: text.maxWidth,
        order: texts.length + copiedTextIds.length - 1,
        createdAt: DateTime.now(),
      );
    });
    final copiedImages = images
        .where((image) => selectedImageIds.contains(image.id))
        .map((image) {
      final id = '${image.id}_copy_$stamp';
      copiedImageIds.add(id);
      return DrawingImage(
        id: id,
        documentId: image.documentId,
        pageId: image.pageId,
        imagePath: image.imagePath,
        position: _translatedPoint(image.position, dx, dy),
        width: image.width,
        height: image.height,
        order: images.length + copiedImageIds.length - 1,
        createdAt: DateTime.now(),
      );
    });
    strokes.addAll(copiedStrokes);
    shapes.addAll(copiedShapes);
    texts.addAll(copiedTexts);
    images.addAll(copiedImages);
    selectedStrokeIds
      ..clear()
      ..addAll(copiedStrokeIds);
    selectedShapeIds
      ..clear()
      ..addAll(copiedShapeIds);
    selectedTextIds
      ..clear()
      ..addAll(copiedTextIds);
    selectedImageIds
      ..clear()
      ..addAll(copiedImageIds);
    _scheduleSave();
    setState(() {});
  }

  Future<void> _showSelectedShapeStyle() async {
    if (selectedShapeIds.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _ShapeStyleSheet(
        onColorSelected: (color) {
          Navigator.of(sheetContext).pop();
          _applySelectedShapeColor(color);
        },
        onWidthSelected: (width) {
          Navigator.of(sheetContext).pop();
          _applySelectedShapeWidth(width);
        },
      ),
    );
  }

  void _applySelectedShapeColor(Color color) {
    if (selectedShapeIds.isEmpty) return;
    _recordHistory();
    for (var index = 0; index < shapes.length; index++) {
      if (selectedShapeIds.contains(shapes[index].id)) {
        shapes[index] = shapes[index].copyWith(color: color);
      }
    }
    _scheduleSave();
    setState(() {});
  }

  void _applySelectedShapeWidth(double width) {
    if (selectedShapeIds.isEmpty) return;
    _recordHistory();
    for (var index = 0; index < shapes.length; index++) {
      if (selectedShapeIds.contains(shapes[index].id)) {
        shapes[index] = shapes[index].copyWith(strokeWidth: width);
      }
    }
    _scheduleSave();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
          title: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: InkWell(
                onTap: _scheduleRenameTitle,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(title.isEmpty ? '새 노트' : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            letterSpacing: -.25,
                          )),
                ),
              ),
            ),
            const SizedBox(width: 7),
            Semantics(
              button: true,
              label: '페이지 탐색, $pageIndex / $pageCount',
              child: InkWell(
                onTap: _showPageNavigator,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Text('$pageIndex/$pageCount',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      )),
                ),
              ),
            ),
          ]),
          actions: [
            IconButton(
                onPressed: undoHistory.isEmpty ? null : _undo,
                tooltip: '실행 취소',
                icon: const Icon(Icons.undo, size: 22)),
            IconButton(
                onPressed: redoHistory.isEmpty ? null : _redo,
                tooltip: '다시 실행',
                icon: const Icon(Icons.redo, size: 22)),
            PopupMenuButton<String>(
              tooltip: '노트 메뉴',
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                switch (value) {
                  case 'rename':
                    _scheduleRenameTitle();
                    break;
                  case 'previous':
                    _switchPage(pageIndex - 1);
                    break;
                  case 'next':
                    _switchPage(pageIndex + 1);
                    break;
                  case 'add':
                    _addPage();
                    break;
                  case 'delete':
                    _deletePage();
                    break;
                  case 'clear':
                    _recordHistory();
                    strokes.clear();
                    shapes.clear();
                    texts.clear();
                    images.clear();
                    activeShape = null;
                    _clearSelectionState();
                    _scheduleSave();
                    setState(() {});
                    break;
                  case 'toolbar':
                    setState(() => toolbarVisible = !toolbarVisible);
                    break;
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('노트 이름 변경')),
                PopupMenuItem(
                    value: 'previous',
                    enabled: pageIndex > 1,
                    child: const Text('이전 페이지')),
                PopupMenuItem(
                    value: 'next',
                    enabled: pageIndex < pageCount,
                    child: const Text('다음 페이지')),
                const PopupMenuItem(value: 'add', child: Text('페이지 추가')),
                PopupMenuItem(
                    value: 'delete',
                    enabled: pageCount > 1,
                    child: const Text('페이지 삭제')),
                PopupMenuItem(
                    value: 'toolbar',
                    child: Text(toolbarVisible ? '도구 숨기기' : '도구 보이기')),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'clear', child: Text('현재 페이지 지우기')),
              ],
            ),
          ]),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              if (toolbarVisible) _toolbar(context),
              Expanded(
                  child: _ZoomableNotebookViewport(
                      onViewportGestureStart:
                          _cancelCanvasInputForViewportGesture,
                      child: Align(
                          alignment: Alignment.topCenter,
                          child: AspectRatio(
                              aspectRatio: .7,
                              child: DecoratedBox(
                                decoration: const BoxDecoration(
                                    color: Colors.white,
                                    boxShadow: [
                                      BoxShadow(
                                          blurRadius: 3, color: Colors.black12)
                                    ]),
                                child: LayoutBuilder(
                                    builder: (context, constraints) =>
                                        Stack(children: [
                                          DrawingCanvas(
                                              strokes: strokes,
                                              texts: texts,
                                              images: images,
                                              imageCache: imageCache,
                                              hiddenTextId: editingText?.id,
                                              shapes: shapes,
                                              activePoints: active,
                                              activeShape: activeShape,
                                              tool: tool,
                                              color: activeColor,
                                              width: activeWidth,
                                              pageTemplateId:
                                                  widget.pageTemplateId,
                                              onStart: _start,
                                              onMove: _move,
                                              onEnd: _end,
                                              lassoPath: lassoPath,
                                              selectedStrokeIds:
                                                  selectedStrokeIds,
                                              selectedShapeIds:
                                                  selectedShapeIds,
                                              selectedTextIds: selectedTextIds,
                                              selectedImageIds:
                                                  selectedImageIds,
                                              onSelectionStart: _selectionStart,
                                              onSelectionMove: _selectionMove,
                                              onSelectionEnd: _selectionEnd,
                                              onTextTap: _textTap,
                                              onImageTap: _imageTap),
                                          if (editingText case final text?)
                                            Positioned(
                                              left: text.position.x *
                                                  constraints.maxWidth,
                                              top: text.position.y *
                                                  constraints.maxHeight,
                                              width: text.maxWidth *
                                                  constraints.maxWidth,
                                              child: TextField(
                                                controller: textController,
                                                focusNode: textFocus,
                                                minLines: 1,
                                                maxLines: null,
                                                style: TextStyle(
                                                    color: text.color,
                                                    fontSize: text.fontSize,
                                                    height: 1.25),
                                                decoration:
                                                    const InputDecoration(
                                                        isDense: true,
                                                        border:
                                                            InputBorder.none),
                                              ),
                                            ),
                                        ])),
                              ))))),
            ]),
    );
  }

  Widget _toolbar(BuildContext context) => EditorToolbar(
        selectedTool: tool,
        width: activeWidth,
        color: activeColor,
        onToolChanged: _setTool,
        onWidthChanged: _setWidth,
        onPaletteRequested: _showColorPalette,
        shapeType: shapeType,
        onShapeTypeChanged: _setShapeType,
        hasSelection: selectedStrokeIds.isNotEmpty ||
            selectedShapeIds.isNotEmpty ||
            selectedTextIds.isNotEmpty ||
            selectedImageIds.isNotEmpty,
        hasShapeSelection: selectedShapeIds.isNotEmpty,
        onDeleteSelection: _deleteSelection,
        onDuplicateSelection: _duplicateSelection,
        onShapeStyleRequested: _showSelectedShapeStyle,
      );
}

class _ZoomableNotebookViewport extends StatefulWidget {
  const _ZoomableNotebookViewport({
    required this.child,
    required this.onViewportGestureStart,
  });

  final Widget child;
  final VoidCallback onViewportGestureStart;

  @override
  State<_ZoomableNotebookViewport> createState() =>
      _ZoomableNotebookViewportState();
}

class _ZoomableNotebookViewportState extends State<_ZoomableNotebookViewport> {
  final _touches = <int, Offset>{};
  Matrix4 _transform = Matrix4.identity();
  Matrix4 _gestureStartTransform = Matrix4.identity();
  Offset? _gestureStartFocal;
  double _gestureStartDistance = 1;
  bool _suppressCanvasInput = false;

  bool _isTouch(PointerEvent event) => event.kind == ui.PointerDeviceKind.touch;

  void _onPointerDown(PointerDownEvent event) {
    if (!_isTouch(event)) return;
    _touches[event.pointer] = event.localPosition;
    if (_touches.length == 2) {
      _gestureStartTransform = _transform.clone();
      _gestureStartFocal = _focalPoint;
      _gestureStartDistance = _touchDistance.clamp(1.0, double.infinity);
      _suppressCanvasInput = true;
      widget.onViewportGestureStart();
      setState(() {});
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_isTouch(event) || !_touches.containsKey(event.pointer)) return;
    _touches[event.pointer] = event.localPosition;
    if (_touches.length < 2 || _gestureStartFocal == null) return;
    final currentFocal = _focalPoint;
    final baseScale = _gestureStartTransform.getMaxScaleOnAxis();
    final relativeScale = (_touchDistance / _gestureStartDistance)
        .clamp(1 / baseScale, 3 / baseScale);
    final delta = currentFocal - _gestureStartFocal!;
    final next = Matrix4.translationValues(delta.dx, delta.dy, 0)
      ..multiply(Matrix4.translationValues(
          _gestureStartFocal!.dx, _gestureStartFocal!.dy, 0))
      ..multiply(Matrix4.diagonal3Values(relativeScale, relativeScale, 1))
      ..multiply(Matrix4.translationValues(
          -_gestureStartFocal!.dx, -_gestureStartFocal!.dy, 0))
      ..multiply(_gestureStartTransform);
    setState(() => _transform = _boundedTransform(next));
  }

  /// Keep zoomed paper reachable without allowing it to drift so far that the
  /// viewport becomes an empty canvas. This only constrains two-finger touch;
  /// stylus and pen coordinates remain untouched.
  Matrix4 _boundedTransform(Matrix4 transform) {
    final viewport = context.size;
    if (viewport == null || viewport.isEmpty) return transform;
    final scale = transform.getMaxScaleOnAxis();
    final maxX = viewport.width * (scale - 1) * .5;
    final maxY = viewport.height * (scale - 1) * .5;
    transform.storage[12] = transform.storage[12].clamp(-maxX, maxX).toDouble();
    transform.storage[13] = transform.storage[13].clamp(-maxY, maxY).toDouble();
    return transform;
  }

  void _onPointerDone(PointerEvent event) {
    if (!_isTouch(event)) return;
    _touches.remove(event.pointer);
    if (_touches.isEmpty) {
      _gestureStartFocal = null;
      if (!_suppressCanvasInput) return;
      _suppressCanvasInput = false;
      setState(() {});
    }
  }

  Offset get _focalPoint {
    final points = _touches.values.toList(growable: false);
    return Offset(
      (points[0].dx + points[1].dx) / 2,
      (points[0].dy + points[1].dy) / 2,
    );
  }

  double get _touchDistance {
    final points = _touches.values.toList(growable: false);
    return (points[0] - points[1]).distance;
  }

  @override
  Widget build(BuildContext context) => ClipRect(
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerDone,
          onPointerCancel: _onPointerDone,
          child: IgnorePointer(
            ignoring: _suppressCanvasInput,
            child: Transform(
              alignment: Alignment.topLeft,
              transform: _transform,
              transformHitTests: true,
              child: widget.child,
            ),
          ),
        ),
      );
}

class _PageNavigatorSheet extends StatelessWidget {
  const _PageNavigatorSheet({
    required this.documentId,
    required this.pageCount,
    required this.selectedPage,
    required this.templateId,
    required this.onPageSelected,
    required this.onAddPage,
    required this.onDuplicatePage,
    required this.onDeletePage,
  });

  final String documentId;
  final int pageCount;
  final int selectedPage;
  final String templateId;
  final ValueChanged<int> onPageSelected;
  final VoidCallback onAddPage;
  final ValueChanged<int> onDuplicatePage;
  final ValueChanged<int> onDeletePage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = (pageCount / 3).ceil();
    final height = (142 + rows * 180)
        .clamp(292.0, MediaQuery.sizeOf(context).height * .64)
        .toDouble();
    return SafeArea(
      top: false,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('페이지',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      )),
              const SizedBox(width: 8),
              Text('$pageCount장',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      )),
              const Spacer(),
              IconButton(
                onPressed: onAddPage,
                tooltip: '페이지 추가',
                icon: const Icon(Icons.add),
              ),
            ]),
            const SizedBox(height: 12),
            Expanded(
              child: GridView.builder(
                itemCount: pageCount,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 112,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 12,
                  childAspectRatio: .68,
                ),
                itemBuilder: (context, index) {
                  final page = index + 1;
                  final selected = page == selectedPage;
                  return Semantics(
                    button: true,
                    selected: selected,
                    label: '$page페이지',
                    child: InkWell(
                      onTap: () => onPageSelected(page),
                      onLongPress: () => _showPageActions(context, page),
                      borderRadius: BorderRadius.circular(6),
                      child: Column(children: [
                        Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(
                                color: selected
                                    ? scheme.primary
                                    : scheme.outlineVariant
                                        .withValues(alpha: .65),
                                width: selected ? 1.4 : .7,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x12000000),
                                  blurRadius: 3,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: _PageThumbnail(
                                documentId: documentId,
                                pageId: 'page_$page',
                                templateId: templateId,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text('$page',
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(
                                  color: selected
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                )),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _showPageActions(BuildContext context, int page) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('페이지 복제'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onDuplicatePage(page);
                },
              ),
              ListTile(
                enabled: pageCount > 1,
                leading: Icon(Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error),
                title: Text('페이지 삭제',
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: pageCount <= 1
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        onDeletePage(page);
                      },
              ),
            ]),
          ),
        ),
      );
}

/// A compact, read-only version of the page canvas.  It deliberately uses the
/// same painters as the editor so page navigation reflects saved handwriting,
/// shapes, text and image objects instead of showing generic paper only.
class _PageThumbnail extends StatefulWidget {
  const _PageThumbnail({
    required this.documentId,
    required this.pageId,
    required this.templateId,
  });

  final String documentId;
  final String pageId;
  final String templateId;

  @override
  State<_PageThumbnail> createState() => _PageThumbnailState();
}

class _PageThumbnailState extends State<_PageThumbnail>
    with AutomaticKeepAliveClientMixin {
  final _store = AnnotationStore();
  DrawingPageData? _page;
  final _imageCache = <String, ui.Image>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final page = await _store.loadPage(widget.documentId, widget.pageId);
    for (final image in page.images) {
      try {
        final bytes = await File(image.imagePath).readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 160);
        final frame = await codec.getNextFrame();
        _imageCache[image.imagePath] = frame.image;
      } catch (_) {
        // The thumbnail retains a lightweight placeholder when an attachment
        // is no longer available; opening the page continues to be safe.
      }
    }
    if (mounted) setState(() => _page = page);
  }

  @override
  void dispose() {
    for (final image in _imageCache.values) {
      image.dispose();
    }
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final page = _page;
    if (page == null) {
      return CustomPaint(
        painter: _NotebookPagePainter(widget.templateId),
        child: const SizedBox.expand(),
      );
    }
    return RepaintBoundary(
        child: LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      return CustomPaint(
        isComplex: true,
        willChange: false,
        painter: _NotebookPagePainter(widget.templateId),
        foregroundPainter: StrokePainter(
          page.strokes,
          const [],
          size,
          StrokeTool.pen,
          Colors.black,
          1,
          PenType.ballpoint,
          const [],
          const {},
          page.shapes,
          null,
          const {},
          page.texts,
          const {},
          null,
          page.images,
          _imageCache,
          const {},
        ),
        child: const SizedBox.expand(),
      );
    }));
  }
}

class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    required this.selectedTool,
    required this.width,
    required this.color,
    required this.onToolChanged,
    required this.onWidthChanged,
    required this.onPaletteRequested,
    required this.shapeType,
    required this.onShapeTypeChanged,
    required this.hasSelection,
    required this.hasShapeSelection,
    required this.onDeleteSelection,
    required this.onDuplicateSelection,
    required this.onShapeStyleRequested,
    super.key,
  });
  final StrokeTool selectedTool;
  final double width;
  final Color color;
  final ValueChanged<StrokeTool> onToolChanged;
  final ValueChanged<double> onWidthChanged;
  final VoidCallback onPaletteRequested;
  final DrawingShapeType shapeType;
  final ValueChanged<DrawingShapeType> onShapeTypeChanged;
  final bool hasSelection;
  final bool hasShapeSelection;
  final VoidCallback onDeleteSelection;
  final VoidCallback onDuplicateSelection;
  final VoidCallback onShapeStyleRequested;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: SizedBox(
          width: double.infinity,
          height: 60,
          child: Row(children: [
            _ToolSelector(
              selectedTool: selectedTool,
              onChanged: onToolChanged,
            ),
            Container(width: 1, height: 28, color: scheme.outlineVariant),
            Expanded(
              child: _EditorToolOptions(
                selectedTool: selectedTool,
                width: width,
                color: color,
                onWidthChanged: onWidthChanged,
                onPaletteRequested: onPaletteRequested,
                shapeType: shapeType,
                onShapeTypeChanged: onShapeTypeChanged,
                hasSelection: hasSelection,
                hasShapeSelection: hasShapeSelection,
                onDeleteSelection: onDeleteSelection,
                onDuplicateSelection: onDuplicateSelection,
                onShapeStyleRequested: onShapeStyleRequested,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ToolSelector extends StatelessWidget {
  const _ToolSelector({required this.selectedTool, required this.onChanged});
  final StrokeTool selectedTool;
  final ValueChanged<StrokeTool> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 160,
        child: Row(children: [
          _EditorToolButton(
              glyph: _EditorToolGlyph.pen,
              label: '펜',
              selected: selectedTool == StrokeTool.pen,
              onTap: () => onChanged(StrokeTool.pen)),
          _EditorToolButton(
              glyph: _EditorToolGlyph.eraser,
              label: '지우개',
              selected: selectedTool == StrokeTool.eraser,
              onTap: () => onChanged(StrokeTool.eraser)),
          _EditorToolButton(
              glyph: _EditorToolGlyph.highlighter,
              label: '형광펜',
              selected: selectedTool == StrokeTool.highlighter,
              onTap: () => onChanged(StrokeTool.highlighter)),
          _EditorToolButton(
              glyph: _EditorToolGlyph.lasso,
              label: '선택',
              selected: selectedTool == StrokeTool.lasso,
              onTap: () => onChanged(StrokeTool.lasso)),
          _AdditionalToolsButton(
            selectedTool: selectedTool,
            onChanged: onChanged,
          ),
        ]),
      );
}

class _AdditionalToolsButton extends StatelessWidget {
  const _AdditionalToolsButton(
      {required this.selectedTool, required this.onChanged});
  final StrokeTool selectedTool;
  final ValueChanged<StrokeTool> onChanged;

  bool get _isAdditionalTool =>
      selectedTool == StrokeTool.shapeLine ||
      selectedTool == StrokeTool.shapeRectangle ||
      selectedTool == StrokeTool.shapeEllipse ||
      selectedTool == StrokeTool.shapeArrow ||
      selectedTool == StrokeTool.text ||
      selectedTool == StrokeTool.image;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '추가 도구',
      selected: _isAdditionalTool,
      child: PopupMenuButton<StrokeTool>(
        tooltip: '추가 도구',
        padding: EdgeInsets.zero,
        position: PopupMenuPosition.under,
        onSelected: onChanged,
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: StrokeTool.shapeLine,
            child: _AdditionalToolMenuItem(
              icon: Icons.category_outlined,
              label: '도형',
            ),
          ),
          PopupMenuItem(
            value: StrokeTool.text,
            child: _AdditionalToolMenuItem(
              icon: Icons.text_fields_rounded,
              label: '텍스트',
            ),
          ),
          PopupMenuItem(
            value: StrokeTool.image,
            child: _AdditionalToolMenuItem(
              icon: Icons.image_outlined,
              label: '이미지',
            ),
          ),
        ],
        child: SizedBox(
          width: 32,
          height: 60,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.more_horiz,
                size: 22,
                color: _isAdditionalTool
                    ? scheme.primary
                    : scheme.onSurfaceVariant),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: _isAdditionalTool ? 15 : 0,
              height: 2,
              color: scheme.primary,
            ),
          ]),
        ),
      ),
    );
  }
}

class _AdditionalToolMenuItem extends StatelessWidget {
  const _AdditionalToolMenuItem({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Text(label),
      ]);
}

class _EditorToolButton extends StatelessWidget {
  const _EditorToolButton(
      {required this.glyph,
      required this.label,
      required this.selected,
      required this.onTap});
  final _EditorToolGlyph glyph;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 32,
          height: 60,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CustomPaint(
                painter: _EditorToolGlyphPainter(
                  glyph,
                  selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: selected ? 15 : 0,
                height: 2,
                color: scheme.primary),
          ]),
        ),
      ),
    );
  }
}

enum _EditorToolGlyph { pen, eraser, highlighter, lasso }

/// Core drawing tools use one compact, stroke-based icon set rather than a
/// mixture of unrelated Material glyphs. The same 1.8px stroke and geometry
/// keeps the toolbar calm while still being legible at phone size.
class _EditorToolGlyphPainter extends CustomPainter {
  const _EditorToolGlyphPainter(this.glyph, this.color);

  final _EditorToolGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    switch (glyph) {
      case _EditorToolGlyph.pen:
        final body = Path()
          ..moveTo(5.2, 16.8)
          ..lineTo(6.4, 12.8)
          ..lineTo(15.8, 3.4)
          ..lineTo(18.6, 6.2)
          ..lineTo(9.2, 15.6)
          ..close();
        canvas.drawPath(body, stroke);
        canvas.drawLine(const Offset(5.2, 16.8), const Offset(9.2, 15.6), stroke);
      case _EditorToolGlyph.eraser:
        final body = Path()
          ..moveTo(6.0, 11.2)
          ..lineTo(11.3, 5.9)
          ..lineTo(18.0, 12.6)
          ..lineTo(12.7, 17.9)
          ..close();
        canvas.drawPath(body, stroke);
        canvas.drawLine(const Offset(9.3, 14.5), const Offset(15.3, 8.5), stroke);
      case _EditorToolGlyph.highlighter:
        final center = Offset(size.width / 2, size.height / 2);
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(-.72);
        canvas.translate(-center.dx, -center.dy);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: center, width: 7.5, height: 15),
            const Radius.circular(1.2),
          ),
          stroke,
        );
        canvas.drawLine(const Offset(7.3, 16.5), const Offset(14.7, 16.5), stroke);
        canvas.restore();
      case _EditorToolGlyph.lasso:
        final loop = Path()
          ..moveTo(16.7, 8.0)
          ..cubicTo(14.8, 4.6, 8.1, 4.5, 5.7, 8.6)
          ..cubicTo(3.5, 12.5, 7.2, 16.6, 11.8, 15.6)
          ..cubicTo(15.7, 14.8, 15.7, 10.2, 12.5, 9.8)
          ..cubicTo(10.1, 9.5, 8.9, 11.6, 10.2, 13.3);
        canvas.drawPath(loop, stroke);
        canvas.drawCircle(const Offset(17.5, 16.9), 1.5, stroke);
        canvas.drawLine(const Offset(15.9, 15.3), const Offset(14.2, 13.6), stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _EditorToolGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}

class _EditorToolOptions extends StatelessWidget {
  const _EditorToolOptions(
      {required this.selectedTool,
      required this.width,
      required this.color,
      required this.onWidthChanged,
      required this.onPaletteRequested,
      required this.shapeType,
      required this.onShapeTypeChanged,
      required this.hasSelection,
      required this.hasShapeSelection,
      required this.onDeleteSelection,
      required this.onDuplicateSelection,
      required this.onShapeStyleRequested});
  final StrokeTool selectedTool;
  final double width;
  final Color color;
  final ValueChanged<double> onWidthChanged;
  final VoidCallback onPaletteRequested;
  final DrawingShapeType shapeType;
  final ValueChanged<DrawingShapeType> onShapeTypeChanged;
  final bool hasSelection;
  final bool hasShapeSelection;
  final VoidCallback onDeleteSelection;
  final VoidCallback onDuplicateSelection;
  final VoidCallback onShapeStyleRequested;
  @override
  Widget build(BuildContext context) {
    if (selectedTool == StrokeTool.image) return const SizedBox.shrink();
    if (_isShapeTool(selectedTool)) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(children: [
          for (final type in DrawingShapeType.values)
            _ShapeTypeButton(
              type: type,
              selected: type == shapeType,
              onTap: () => onShapeTypeChanged(type),
            ),
        ]),
      );
    }
    if (selectedTool == StrokeTool.lasso) {
      return Align(
        alignment: Alignment.centerLeft,
        child: hasSelection
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  onPressed: onDuplicateSelection,
                  tooltip: '선택 항목 복제',
                  icon: const Icon(Icons.content_copy_outlined),
                ),
                if (hasShapeSelection)
                  IconButton(
                    onPressed: onShapeStyleRequested,
                    tooltip: '선택한 도형 스타일',
                    icon: const Icon(Icons.tune_rounded),
                  ),
                IconButton(
                  onPressed: onDeleteSelection,
                  tooltip: '선택한 필기 삭제',
                  icon: const Icon(Icons.delete_outline),
                  color: Theme.of(context).colorScheme.error,
                ),
              ])
            : const SizedBox.shrink(),
      );
    }
    final isEraser = selectedTool == StrokeTool.eraser;
    final isText = selectedTool == StrokeTool.text;
    final widths = isText
        ? const [14.0, 18.0, 24.0]
        : isEraser
            ? const [4.0, 16.0, 32.0]
            : const [2.0, 8.0, 14.0];
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isText ? 0 : 4),
      child: Row(children: [
        for (final value in widths)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: _StrokeWidthOption(
                value: value,
                selected: _isSelectedWidth(value),
                compact: isText,
                onTap: () => onWidthChanged(value)),
          ),
        if (!isEraser) ...[
          Container(
              width: 1,
              height: 24,
              margin: const EdgeInsets.symmetric(horizontal: 5),
              color: scheme.outlineVariant),
          _ColorDot(color: color, selected: true, onTap: onPaletteRequested),
          const SizedBox(width: 4),
          _PaletteButton(onTap: onPaletteRequested),
        ],
      ]),
    );
  }

  bool _isSelectedWidth(double candidate) {
    if (selectedTool == StrokeTool.eraser) {
      return candidate ==
          (width <= 7
              ? 4
              : width <= 24
                  ? 16
                  : 32);
    }
    if (selectedTool == StrokeTool.text) {
      return candidate ==
          (width <= 16
              ? 14
              : width <= 21
                  ? 18
                  : 24);
    }
    return candidate ==
        (width <= 4
            ? 2
            : width <= 10
                ? 8
                : 14);
  }

  bool _isShapeTool(StrokeTool tool) =>
      tool == StrokeTool.shapeLine ||
      tool == StrokeTool.shapeRectangle ||
      tool == StrokeTool.shapeEllipse ||
      tool == StrokeTool.shapeArrow;
}

class _ShapeTypeButton extends StatelessWidget {
  const _ShapeTypeButton(
      {required this.type, required this.selected, required this.onTap});
  final DrawingShapeType type;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = switch (type) {
      DrawingShapeType.line => Icons.horizontal_rule_rounded,
      DrawingShapeType.rectangle => Icons.crop_square_rounded,
      DrawingShapeType.ellipse => Icons.circle_outlined,
      DrawingShapeType.arrow => Icons.arrow_right_alt_rounded,
    };
    final label = switch (type) {
      DrawingShapeType.line => '직선',
      DrawingShapeType.rectangle => '사각형',
      DrawingShapeType.ellipse => '타원',
      DrawingShapeType.arrow => '화살표',
    };
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 32,
          height: 60,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon,
                size: 22,
                color: selected ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(height: 5),
            AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: selected ? 14 : 0,
                height: 2,
                color: scheme.primary),
          ]),
        ),
      ),
    );
  }
}

class _StrokeWidthOption extends StatelessWidget {
  const _StrokeWidthOption(
      {required this.value,
      required this.selected,
      required this.onTap,
      this.compact = false});
  final double value;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: compact ? 22 : 32,
          height: 32,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: value <= 4
                  ? 18
                  : value <= 10
                      ? 24
                      : compact
                          ? 20
                          : 30,
              height: (value / 2).clamp(2, 8),
              decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xff326b9e)
                      : const Color(0xff65717c),
                  borderRadius: BorderRadius.circular(6)),
            ),
            const SizedBox(height: 5),
            AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: selected ? 16 : 0,
                height: 2,
                color: const Color(0xff377ab7)),
          ]),
        ),
      );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot(
      {required this.color, required this.selected, required this.onTap});
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: 28,
          height: 28,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color:
                      selected ? const Color(0xff377ab7) : Colors.transparent,
                  width: 2)),
          child: DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        ),
      );
}

class _PaletteButton extends StatelessWidget {
  const _PaletteButton({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '색상 팔레트 열기',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: const SizedBox(
            width: 28,
            height: 28,
            child: Center(
              child: Icon(Icons.keyboard_arrow_down_rounded,
                  size: 22, color: Color(0xff5f6b76)),
            ),
          ),
        ),
      );
}

class _PaletteColorButton extends StatelessWidget {
  const _PaletteColorButton(
      {required this.color, required this.selected, required this.onTap});
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          width: 48,
          height: 48,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
                color: selected
                    ? const Color(0xff377ab7)
                    : const Color(0xffd9e0e5),
                width: selected ? 2 : 1),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      );
}

class _ShapeStyleSheet extends StatelessWidget {
  const _ShapeStyleSheet(
      {required this.onColorSelected, required this.onWidthSelected});
  final ValueChanged<Color> onColorSelected;
  final ValueChanged<double> onWidthSelected;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text('도형 스타일',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('색상', style: Theme.of(context).textTheme.labelLarge),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: 12, children: [
                for (final color in const [
                  Colors.black,
                  Color(0xff3f6f9f),
                  Color(0xffc95656),
                  Color(0xff4e8b68),
                  Color(0xffd58b3a),
                ])
                  _PaletteColorButton(
                      color: color,
                      selected: false,
                      onTap: () => onColorSelected(color)),
              ]),
            ),
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerLeft,
              child:
                  Text('선 굵기', style: Theme.of(context).textTheme.labelLarge),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: 10, children: [
                for (final width in const [2.0, 5.0, 9.0])
                  _ShapeWidthButton(
                    width: width,
                    onTap: () => onWidthSelected(width),
                  ),
              ]),
            ),
          ]),
        ),
      );
}

class _ShapeWidthButton extends StatelessWidget {
  const _ShapeWidthButton({required this.width, required this.onTap});
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(54, 42),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: Container(
          width: 24,
          height: width,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.onSurface,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      );
}

Stroke _strokeWithPoints(Stroke stroke, List<StrokePoint> points) => Stroke(
      id: stroke.id,
      documentId: stroke.documentId,
      pageId: stroke.pageId,
      tool: stroke.tool,
      penType: stroke.penType,
      points: points,
      color: stroke.color,
      width: stroke.width,
      opacity: stroke.opacity,
      order: stroke.order,
      createdAt: stroke.createdAt,
    );

bool _sameStrokePoints(List<Stroke> before, List<Stroke> after) {
  if (before.length != after.length) return false;
  for (var index = 0; index < before.length; index++) {
    final a = before[index];
    final b = after[index];
    if (a.id != b.id || a.points.length != b.points.length) return false;
    for (var pointIndex = 0; pointIndex < a.points.length; pointIndex++) {
      final pa = a.points[pointIndex];
      final pb = b.points[pointIndex];
      if (pa.x != pb.x || pa.y != pb.y) return false;
    }
  }
  return true;
}

class _PageSnapshot {
  const _PageSnapshot(
      {required this.strokes,
      required this.shapes,
      required this.texts,
      required this.images});
  final List<Stroke> strokes;
  final List<DrawingShape> shapes;
  final List<DrawingText> texts;
  final List<DrawingImage> images;
}

bool _samePages(_PageSnapshot before, _PageSnapshot after) =>
    _sameStrokePoints(before.strokes, after.strokes) &&
    _sameShapes(before.shapes, after.shapes) &&
    _sameTexts(before.texts, after.texts) &&
    _sameImages(before.images, after.images);

bool _sameImages(List<DrawingImage> before, List<DrawingImage> after) {
  if (before.length != after.length) return false;
  for (var index = 0; index < before.length; index++) {
    final a = before[index];
    final b = after[index];
    if (a.id != b.id ||
        a.imagePath != b.imagePath ||
        a.position.x != b.position.x ||
        a.position.y != b.position.y ||
        a.width != b.width ||
        a.height != b.height) return false;
  }
  return true;
}

bool _sameTexts(List<DrawingText> before, List<DrawingText> after) {
  if (before.length != after.length) return false;
  for (var index = 0; index < before.length; index++) {
    final a = before[index];
    final b = after[index];
    if (a.id != b.id ||
        a.text != b.text ||
        a.position.x != b.position.x ||
        a.position.y != b.position.y ||
        a.fontSize != b.fontSize ||
        a.color != b.color) return false;
  }
  return true;
}

bool _sameShapes(List<DrawingShape> before, List<DrawingShape> after) {
  if (before.length != after.length) return false;
  for (var index = 0; index < before.length; index++) {
    final a = before[index];
    final b = after[index];
    if (a.id != b.id ||
        a.startPoint.x != b.startPoint.x ||
        a.startPoint.y != b.startPoint.y ||
        a.endPoint.x != b.endPoint.x ||
        a.endPoint.y != b.endPoint.y) {
      return false;
    }
  }
  return true;
}

StrokePoint _translatedPoint(StrokePoint point, double dx, double dy) =>
    StrokePoint(point.x + dx, point.y + dy, point.pressure);

Rect _textRectNormalized(DrawingText text) {
  final lines = '\n'.allMatches(text.text).length + 1;
  final height = (text.fontSize * 1.25 * lines / 900).clamp(.02, .6);
  return Rect.fromLTWH(text.position.x, text.position.y, text.maxWidth, height);
}

Rect _textRect(DrawingText text, Size size) => Rect.fromLTWH(
    text.position.x * size.width,
    text.position.y * size.height,
    text.maxWidth * size.width,
    _textRectNormalized(text).height * size.height);

Rect _imageRectNormalized(DrawingImage image) => Rect.fromLTWH(
    image.position.x, image.position.y, image.width, image.height);

bool _imageIsInsideLasso(DrawingImage image, List<StrokePoint> polygon) {
  final rect = _imageRectNormalized(image);
  final points = [
    StrokePoint(rect.left, rect.top, 1),
    StrokePoint(rect.right, rect.top, 1),
    StrokePoint(rect.left, rect.bottom, 1),
    StrokePoint(rect.right, rect.bottom, 1),
    StrokePoint(rect.center.dx, rect.center.dy, 1),
  ];
  return points.where((point) => _pointInPolygon(point, polygon)).length >= 3;
}

bool _textIsInsideLasso(DrawingText text, List<StrokePoint> polygon) {
  final rect = _textRectNormalized(text);
  final points = [
    StrokePoint(rect.left, rect.top, 1),
    StrokePoint(rect.right, rect.top, 1),
    StrokePoint(rect.left, rect.bottom, 1),
    StrokePoint(rect.right, rect.bottom, 1),
    StrokePoint(rect.center.dx, rect.center.dy, 1),
  ];
  return points.where((point) => _pointInPolygon(point, polygon)).length >= 3;
}

StrokePoint _scaledPoint(
        StrokePoint point, Rect bounds, double scaleX, double scaleY) =>
    StrokePoint(
      bounds.left + (point.x - bounds.left) * scaleX,
      bounds.top + (point.y - bounds.top) * scaleY,
      point.pressure,
    );

bool _resizeHandleHit(Rect bounds, StrokePoint point) =>
    (point.x - bounds.right).abs() <= .03 &&
    (point.y - bounds.bottom).abs() <= .03;

double _snappedSelectionDelta(double delta, double start, double end) {
  const targets = [.04, .5, .96];
  const threshold = .012;
  final center = (start + end) / 2;
  for (final target in targets) {
    for (final current in [start + delta, center + delta, end + delta]) {
      final adjustment = target - current;
      if (adjustment.abs() <= threshold) return delta + adjustment;
    }
  }
  return delta;
}

bool _rotationHandleHit(Rect bounds, StrokePoint point) =>
    (point.x - bounds.center.dx).abs() <= .04 &&
    (point.y - (bounds.top - .055)).abs() <= .04;

double _selectionAngle(Rect bounds, StrokePoint point) =>
    math.atan2(point.y - bounds.center.dy, point.x - bounds.center.dx);

StrokePoint _rotatePoint(StrokePoint point, StrokePoint pivot, double radians) {
  final dx = point.x - pivot.x;
  final dy = point.y - pivot.y;
  final cos = math.cos(radians);
  final sin = math.sin(radians);
  return StrokePoint(
    pivot.x + dx * cos - dy * sin,
    pivot.y + dx * sin + dy * cos,
    point.pressure,
  );
}

DrawingShape _rotatedShape(
    DrawingShape shape, StrokePoint selectionPivot, double radians) {
  if (shape.type == DrawingShapeType.line ||
      shape.type == DrawingShapeType.arrow) {
    return shape.copyWith(
      startPoint: _rotatePoint(shape.startPoint, selectionPivot, radians),
      endPoint: _rotatePoint(shape.endPoint, selectionPivot, radians),
    );
  }
  final center = StrokePoint((shape.startPoint.x + shape.endPoint.x) / 2,
      (shape.startPoint.y + shape.endPoint.y) / 2, 1);
  final rotatedCenter = _rotatePoint(center, selectionPivot, radians);
  final dx = rotatedCenter.x - center.x;
  final dy = rotatedCenter.y - center.y;
  return shape.copyWith(
    startPoint: _translatedPoint(shape.startPoint, dx, dy),
    endPoint: _translatedPoint(shape.endPoint, dx, dy),
    rotationRadians: shape.rotationRadians + radians,
  );
}

List<StrokePoint> _shapeSelectionPoints(DrawingShape shape) {
  final start = shape.startPoint;
  final end = shape.endPoint;
  if (shape.type == DrawingShapeType.line ||
      shape.type == DrawingShapeType.arrow) {
    return [start, end];
  }
  final pivot = StrokePoint((start.x + end.x) / 2, (start.y + end.y) / 2, 1);
  return [
    start,
    end,
    StrokePoint(start.x, end.y, 1),
    StrokePoint(end.x, start.y, 1),
  ].map((point) => _rotatePoint(point, pivot, shape.rotationRadians)).toList();
}

bool _strokeIsInsideLasso(Stroke stroke, List<StrokePoint> polygon) {
  if (stroke.points.isEmpty) return false;
  final inside =
      stroke.points.where((point) => _pointInPolygon(point, polygon)).length;
  return inside >= math.max(1, (stroke.points.length * .6).ceil());
}

bool _shapeIsInsideLasso(DrawingShape shape, List<StrokePoint> polygon) {
  final points = _shapeSelectionPoints(shape);
  final start = points.first;
  final end = points[1];
  final center = StrokePoint((start.x + end.x) / 2, (start.y + end.y) / 2, 1);
  if (shape.type == DrawingShapeType.line ||
      shape.type == DrawingShapeType.arrow) {
    return [start, center, end]
            .where((point) => _pointInPolygon(point, polygon))
            .length >=
        2;
  }
  final corners = [...points, center];
  return corners.where((point) => _pointInPolygon(point, polygon)).length >= 3;
}

bool _pointInPolygon(StrokePoint point, List<StrokePoint> polygon) {
  var inside = false;
  for (var index = 0, previous = polygon.length - 1;
      index < polygon.length;
      previous = index++) {
    final current = polygon[index];
    final prior = polygon[previous];
    final crosses = (current.y > point.y) != (prior.y > point.y);
    if (crosses &&
        point.x <
            (prior.x - current.x) *
                    (point.y - current.y) /
                    (prior.y - current.y) +
                current.x) {
      inside = !inside;
    }
  }
  return inside;
}

class DrawingCanvas extends StatelessWidget {
  const DrawingCanvas(
      {required this.strokes,
      this.texts = const [],
      this.images = const [],
      this.imageCache = const {},
      this.hiddenTextId,
      this.shapes = const [],
      required this.activePoints,
      this.activeShape,
      required this.tool,
      this.penType = PenType.ballpoint,
      required this.color,
      required this.width,
      this.pageTemplateId = 'blank',
      required this.onStart,
      required this.onMove,
      required this.onEnd,
      this.lassoPath = const [],
      this.selectedStrokeIds = const {},
      this.selectedShapeIds = const {},
      this.selectedTextIds = const {},
      this.selectedImageIds = const {},
      this.onSelectionStart,
      this.onSelectionMove,
      this.onSelectionEnd,
      this.onTextTap,
      this.onImageTap,
      super.key});
  final List<Stroke> strokes;
  final List<DrawingText> texts;
  final List<DrawingImage> images;
  final Map<String, ui.Image> imageCache;
  final String? hiddenTextId;
  final List<DrawingShape> shapes;
  final List<StrokePoint> activePoints;
  final DrawingShape? activeShape;
  final StrokeTool tool;
  final PenType penType;
  final Color color;
  final double width;
  final String pageTemplateId;
  final void Function(Offset, double, Size) onStart;
  final void Function(Offset, double, Size) onMove;
  final VoidCallback onEnd;
  final List<StrokePoint> lassoPath;
  final Set<String> selectedStrokeIds;
  final Set<String> selectedShapeIds;
  final Set<String> selectedTextIds;
  final Set<String> selectedImageIds;
  final void Function(Offset, Size)? onSelectionStart;
  final void Function(Offset, Size)? onSelectionMove;
  final VoidCallback? onSelectionEnd;
  final void Function(Offset, Size)? onTextTap;
  final void Function(Offset, Size)? onImageTap;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) =>
                tool == StrokeTool.lasso && onSelectionStart != null
                    ? onSelectionStart!(e.localPosition, size)
                    : tool == StrokeTool.text && onTextTap != null
                        ? onTextTap!(e.localPosition, size)
                        : tool == StrokeTool.image && onImageTap != null
                            ? onImageTap!(e.localPosition, size)
                            : onStart(e.localPosition, e.pressure, size),
            onPointerMove: (e) =>
                tool == StrokeTool.lasso && onSelectionMove != null
                    ? onSelectionMove!(e.localPosition, size)
                    : tool == StrokeTool.text
                        ? null
                        : tool == StrokeTool.image
                            ? null
                            : onMove(e.localPosition, e.pressure, size),
            onPointerUp: (_) =>
                tool == StrokeTool.lasso && onSelectionEnd != null
                    ? onSelectionEnd!()
                    : tool == StrokeTool.text
                        ? null
                        : tool == StrokeTool.image
                            ? null
                            : onEnd(),
            child: CustomPaint(
                painter: _NotebookPagePainter(pageTemplateId),
                foregroundPainter: StrokePainter(
                    strokes,
                    activePoints,
                    size,
                    tool,
                    color,
                    width,
                    penType,
                    lassoPath,
                    selectedStrokeIds,
                    shapes,
                    activeShape,
                    selectedShapeIds,
                    texts,
                    selectedTextIds,
                    hiddenTextId,
                    images,
                    imageCache,
                    selectedImageIds),
                child: const SizedBox.expand()));
      });
}

class _NotebookPagePainter extends CustomPainter {
  const _NotebookPagePainter(this.templateId);
  final String templateId;

  @override
  void paint(Canvas canvas, Size size) {
    if (templateId == 'blank') return;
    final line = Paint()
      ..color = const Color(0xffd7e1eb)
      ..strokeWidth = 1;
    if (templateId == 'grid' ||
        templateId == 'graph5' ||
        templateId == 'dotted') {
      final gap = templateId == 'graph5' ? 18.0 : 24.0;
      for (double x = gap; x < size.width; x += gap) {
        if (templateId == 'grid' || templateId == 'graph5') {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
        }
        for (double y = gap; y < size.height; y += gap) {
          if (templateId == 'dotted') {
            canvas.drawCircle(Offset(x, y), 1, line);
          } else if (x == gap) {
            canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
          }
        }
      }
      return;
    }
    if (templateId == 'kanban') {
      for (var column = 1; column < 3; column++) {
        final x = size.width * column / 3;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
      }
      canvas.drawLine(Offset(0, 52), Offset(size.width, 52), line);
      for (double y = 104; y < size.height; y += 84) {
        canvas.drawLine(Offset(20, y), Offset(size.width - 20, y), line);
      }
      return;
    }
    if (templateId == 'timetable' || templateId == 'habit') {
      final columns = templateId == 'timetable' ? 5 : 7;
      final rows = templateId == 'timetable' ? 7 : 5;
      for (var column = 1; column < columns; column++) {
        final x = size.width * column / columns;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
      }
      for (var row = 1; row < rows; row++) {
        final y = size.height * row / rows;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      }
      return;
    }
    if (templateId == 'cornell') {
      canvas.drawLine(Offset(size.width * .28, 0),
          Offset(size.width * .28, size.height), line);
      canvas.drawLine(Offset(0, size.height * .79),
          Offset(size.width, size.height * .79), line);
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
      for (var column = 1; column < columns; column++) {
        final x = size.width * column / columns;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
      }
      canvas.drawLine(Offset(0, 44), Offset(size.width, 44), line);
    }
    final start = templateId == 'meeting' ? 62.0 : 36.0;
    final gap = templateId == 'ruledWide' ? 48.0 : 36.0;
    for (double y = start; y < size.height; y += gap) {
      canvas.drawLine(Offset(20, y), Offset(size.width - 20, y), line);
      if (templateId == 'checklist') {
        canvas.drawRect(Rect.fromLTWH(20, y - 16, 11, 11),
            line..style = PaintingStyle.stroke);
        line.style = PaintingStyle.stroke;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _NotebookPagePainter oldDelegate) =>
      oldDelegate.templateId != templateId;
}

class StrokePainter extends CustomPainter {
  StrokePainter(this.strokes, this.active, this.size, this.activeTool,
      this.activeColor, this.activeWidth,
      [this.activePenType = PenType.ballpoint,
      this.lassoPath = const [],
      this.selectedStrokeIds = const {},
      this.shapes = const [],
      this.activeShape,
      this.selectedShapeIds = const {},
      this.texts = const [],
      this.selectedTextIds = const {},
      this.hiddenTextId,
      this.images = const [],
      this.imageCache = const {},
      this.selectedImageIds = const {}]);
  final List<Stroke> strokes;
  final List<StrokePoint> active;
  final Size size;
  final StrokeTool activeTool;
  final Color activeColor;
  final double activeWidth;
  final PenType activePenType;
  final List<StrokePoint> lassoPath;
  final Set<String> selectedStrokeIds;
  final List<DrawingShape> shapes;
  final DrawingShape? activeShape;
  final Set<String> selectedShapeIds;
  final List<DrawingText> texts;
  final Set<String> selectedTextIds;
  final String? hiddenTextId;
  final List<DrawingImage> images;
  final Map<String, ui.Image> imageCache;
  final Set<String> selectedImageIds;
  @override
  void paint(Canvas canvas, Size _) {
    for (final image in images) {
      _paintImage(canvas, image);
    }
    for (final shape in shapes) {
      _paintShape(canvas, shape);
    }
    for (final text in texts) {
      if (text.id != hiddenTextId) _paintText(canvas, text);
    }
    if (activeShape case final shape?) _paintShape(canvas, shape);
    final all = [...strokes];
    if (active.isNotEmpty) {
      all.add(Stroke(
          id: 'active',
          documentId: '',
          pageId: '',
          tool: activeTool,
          penType: activePenType,
          points: active,
          color: activeColor,
          width: activeWidth,
          opacity: activeTool == StrokeTool.highlighter ? .35 : 1,
          order: 0,
          createdAt: DateTime.now()));
    }
    for (final stroke in all) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = stroke.color.withValues(alpha: _opacityFor(stroke))
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (stroke.tool == StrokeTool.eraser) {
        paint.blendMode = ui.BlendMode.clear;
      }
      if (stroke.tool == StrokeTool.shapeLine ||
          stroke.tool == StrokeTool.shapeRectangle ||
          stroke.tool == StrokeTool.shapeEllipse ||
          stroke.tool == StrokeTool.shapeArrow) {
        final start = restorePoint(stroke.points.first, size);
        final end = restorePoint(stroke.points.last, size);
        paint.strokeWidth = stroke.width;
        final rect = Rect.fromPoints(start, end);
        switch (stroke.tool) {
          case StrokeTool.shapeLine:
            canvas.drawLine(start, end, paint);
          case StrokeTool.shapeRectangle:
            canvas.drawRect(rect, paint);
          case StrokeTool.shapeEllipse:
            canvas.drawOval(rect, paint);
          case StrokeTool.shapeArrow:
            canvas.drawLine(start, end, paint);
            final direction = end - start;
            final angle = math.atan2(direction.dy, direction.dx);
            const wing = math.pi / 7;
            final length = 12.0 + stroke.width * 1.5;
            final left = end -
                Offset(math.cos(angle - wing) * length,
                    math.sin(angle - wing) * length);
            final right = end -
                Offset(math.cos(angle + wing) * length,
                    math.sin(angle + wing) * length);
            canvas.drawLine(end, left, paint);
            canvas.drawLine(end, right, paint);
          case StrokeTool.pen:
          case StrokeTool.highlighter:
          case StrokeTool.eraser:
          case StrokeTool.lasso:
          case StrokeTool.text:
          case StrokeTool.image:
            break;
        }
        continue;
      }
      for (var index = 0; index < stroke.points.length - 1; index++) {
        final start = stroke.points[index];
        final end = stroke.points[index + 1];
        paint.strokeWidth =
            (_widthFor(stroke, start) + _widthFor(stroke, end)) / 2;
        canvas.drawLine(
            restorePoint(start, size), restorePoint(end, size), paint);
      }
      if (stroke.points.length == 1) {
        final point = stroke.points.first;
        canvas.drawCircle(
            restorePoint(point, size), _widthFor(stroke, point) / 2, paint);
      }
    }
    _paintLasso(canvas);
    _paintSelectionBounds(canvas);
  }

  void _paintText(Canvas canvas, DrawingText text) {
    final painter = TextPainter(
      text: TextSpan(
          text: text.text,
          style: TextStyle(color: text.color, fontSize: text.fontSize)),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: text.maxWidth * size.width);
    painter.paint(canvas, restorePoint(text.position, size));
  }

  void _paintImage(Canvas canvas, DrawingImage image) {
    final rect = _imageRectNormalized(image);
    final destination = Rect.fromLTWH(
        rect.left * size.width,
        rect.top * size.height,
        rect.width * size.width,
        rect.height * size.height);
    final decoded = imageCache[image.imagePath];
    if (decoded == null) {
      final paint = Paint()..color = const Color(0xffeef1f4);
      canvas.drawRect(destination, paint);
      final icon = TextPainter(
        text: const TextSpan(
            text: 'Image unavailable',
            style: TextStyle(color: Color(0xff66717d), fontSize: 11)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: destination.width - 12);
      icon.paint(canvas, destination.topLeft + const Offset(6, 6));
      return;
    }
    canvas.drawImageRect(
        decoded,
        Rect.fromLTWH(
            0, 0, decoded.width.toDouble(), decoded.height.toDouble()),
        destination,
        Paint()..filterQuality = FilterQuality.medium);
  }

  void _paintShape(Canvas canvas, DrawingShape shape) {
    final start = restorePoint(shape.startPoint, size);
    final end = restorePoint(shape.endPoint, size);
    final paint = Paint()
      ..color = shape.color
      ..strokeWidth = shape.strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final center = Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(shape.rotationRadians);
    canvas.translate(-center.dx, -center.dy);
    switch (shape.type) {
      case DrawingShapeType.line:
        canvas.drawLine(start, end, paint);
      case DrawingShapeType.rectangle:
        canvas.drawRect(Rect.fromPoints(start, end), paint);
      case DrawingShapeType.ellipse:
        canvas.drawOval(Rect.fromPoints(start, end), paint);
      case DrawingShapeType.arrow:
        canvas.drawLine(start, end, paint);
        final direction = end - start;
        if (direction.distance < .5) return;
        final angle = math.atan2(direction.dy, direction.dx);
        const wing = math.pi / 7;
        final length = 12.0 + shape.strokeWidth * 1.5;
        final left = end -
            Offset(math.cos(angle - wing) * length,
                math.sin(angle - wing) * length);
        final right = end -
            Offset(math.cos(angle + wing) * length,
                math.sin(angle + wing) * length);
        canvas.drawLine(end, left, paint);
        canvas.drawLine(end, right, paint);
    }
    canvas.restore();
  }

  void _paintLasso(Canvas canvas) {
    if (lassoPath.length < 2) return;
    final paint = Paint()
      ..color = const Color(0xff5f7e98)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    for (var index = 0; index < lassoPath.length - 1; index += 2) {
      canvas.drawLine(
        restorePoint(lassoPath[index], size),
        restorePoint(lassoPath[index + 1], size),
        paint,
      );
    }
  }

  void _paintSelectionBounds(Canvas canvas) {
    if (selectedStrokeIds.isEmpty &&
        selectedShapeIds.isEmpty &&
        selectedTextIds.isEmpty &&
        selectedImageIds.isEmpty) return;
    final selected = strokes
        .where((stroke) => selectedStrokeIds.contains(stroke.id))
        .expand((stroke) => stroke.points)
        .toList();
    for (final shape in shapes) {
      if (selectedShapeIds.contains(shape.id)) {
        selected.addAll(_shapeSelectionPoints(shape));
      }
    }
    for (final text in texts) {
      if (selectedTextIds.contains(text.id)) {
        final rect = _textRectNormalized(text);
        selected.addAll([
          StrokePoint(rect.left, rect.top, 1),
          StrokePoint(rect.right, rect.bottom, 1),
        ]);
      }
    }
    for (final image in images) {
      if (selectedImageIds.contains(image.id)) {
        final rect = _imageRectNormalized(image);
        selected.addAll([
          StrokePoint(rect.left, rect.top, 1),
          StrokePoint(rect.right, rect.bottom, 1),
        ]);
      }
    }
    if (selected.isEmpty) return;
    var left = selected.first.x;
    var right = selected.first.x;
    var top = selected.first.y;
    var bottom = selected.first.y;
    for (final point in selected.skip(1)) {
      left = math.min(left, point.x);
      right = math.max(right, point.x);
      top = math.min(top, point.y);
      bottom = math.max(bottom, point.y);
    }
    final rect = Rect.fromLTRB(left, top, right, bottom).inflate(.008);
    final selectionRect = Rect.fromLTRB(
      rect.left * size.width,
      rect.top * size.height,
      rect.right * size.width,
      rect.bottom * size.height,
    );
    final selectionShape = RRect.fromRectAndRadius(
      selectionRect,
      const Radius.circular(3),
    );
    final border = Paint()
      ..color = const Color(0xff5c86aa)
      ..strokeWidth = .9
      ..style = PaintingStyle.stroke;
    canvas.drawRRect(
      selectionShape,
      Paint()
        ..color = const Color(0xff5c86aa).withValues(alpha: .055)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(selectionShape, border);
    final guide = Paint()
      ..color = const Color(0xff5c86aa).withValues(alpha: .38)
      ..strokeWidth = .7;
    if ((rect.center.dx - .5).abs() <= .012) {
      canvas.drawLine(Offset(size.width / 2, 0),
          Offset(size.width / 2, size.height), guide);
    }
    if ((rect.center.dy - .5).abs() <= .012) {
      canvas.drawLine(Offset(0, size.height / 2),
          Offset(size.width, size.height / 2), guide);
    }
    if (selectedStrokeIds.isEmpty &&
        selectedTextIds.isEmpty &&
        selectedShapeIds.isNotEmpty) {
      final rotateCenter =
          Offset(rect.center.dx * size.width, (rect.top - .055) * size.height);
      canvas.drawLine(
          Offset(rect.center.dx * size.width, rect.top * size.height),
          rotateCenter,
          border);
      _paintSelectionHandle(canvas, rotateCenter);
      final center = Offset(rect.right * size.width, rect.bottom * size.height);
      _paintSelectionHandle(canvas, center);
    } else if (selectedStrokeIds.isEmpty &&
        selectedTextIds.isEmpty &&
        selectedShapeIds.isEmpty &&
        selectedImageIds.length == 1) {
      final center = Offset(rect.right * size.width, rect.bottom * size.height);
      _paintSelectionHandle(canvas, center);
    }
  }

  void _paintSelectionHandle(Canvas canvas, Offset center) {
    canvas.drawCircle(center, 5, Paint()..color = const Color(0xff5c86aa));
    canvas.drawCircle(center, 2, Paint()..color = const Color(0xfff9fbfd));
  }

  double _widthFor(Stroke stroke, StrokePoint point) =>
      stroke.tool == StrokeTool.pen
          ? stroke.width *
              _penWidthFactor(stroke.penType) *
              (.65 + point.pressure * .7)
          : stroke.width;

  double _penWidthFactor(PenType type) => switch (type) {
        PenType.ballpoint => 1,
        PenType.fountain => 1.15,
        PenType.pencil => .85,
        PenType.marker => 1.25,
      };

  double _opacityFor(Stroke stroke) => stroke.tool == StrokeTool.pen
      ? stroke.opacity *
          switch (stroke.penType) {
            PenType.pencil => .78,
            _ => 1,
          }
      : stroke.opacity;
  @override
  bool shouldRepaint(covariant StrokePainter old) => true;
}
