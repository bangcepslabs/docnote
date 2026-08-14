import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/annotation_store.dart';
import '../domain/stroke.dart';

class DrawingEditorPage extends StatefulWidget {
  const DrawingEditorPage(
      {required this.documentId,
      required this.title,
      this.initialPageCount = 1,
      this.pageTemplateId = 'blank',
      this.onPageCountChanged,
      super.key});
  final String documentId;
  final String title;
  final int initialPageCount;
  final String pageTemplateId;
  final ValueChanged<int>? onPageCountChanged;
  @override
  State<DrawingEditorPage> createState() => _DrawingEditorPageState();
}

class _DrawingEditorPageState extends State<DrawingEditorPage>
    with WidgetsBindingObserver {
  final store = AnnotationStore();
  final strokes = <Stroke>[];
  final redo = <Stroke>[];
  final active = <StrokePoint>[];
  Timer? saveTimer;
  StrokeTool tool = StrokeTool.pen;
  Color color = Colors.black;
  double width = 3;
  bool loaded = false;
  bool toolbarVisible = true;
  late int pageCount = widget.initialPageCount;
  int pageIndex = 1;
  String get pageId => 'page_$pageIndex';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    strokes.addAll(await store.load(widget.documentId, pageId));
    if (mounted) setState(() => loaded = true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    saveTimer?.cancel();
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

  Future<void> _save() => store.save(widget.documentId, pageId, strokes);

  Future<void> _switchPage(int next) async {
    if (next < 1 || next > pageCount || next == pageIndex) return;
    await _save();
    saveTimer?.cancel();
    active.clear();
    strokes
      ..clear()
      ..addAll(await store.load(widget.documentId, 'page_$next'));
    redo.clear();
    if (mounted) setState(() => pageIndex = next);
  }

  Future<void> _addPage() async {
    await _save();
    saveTimer?.cancel();
    pageCount++;
    pageIndex = pageCount;
    strokes.clear();
    redo.clear();
    widget.onPageCountChanged?.call(pageCount);
    if (mounted) setState(() {});
  }

  Future<void> _deletePage() async {
    if (pageCount <= 1) return;
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('페이지 삭제'),
              content: Text('$pageIndex번 페이지를 삭제할까요?'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('취소')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('삭제')),
              ],
            ));
    if (ok != true) return;
    await store.save(widget.documentId, pageId, []);
    pageCount--;
    if (pageIndex > pageCount) pageIndex = pageCount;
    strokes
      ..clear()
      ..addAll(await store.load(widget.documentId, pageId));
    redo.clear();
    widget.onPageCountChanged?.call(pageCount);
    if (mounted) setState(() {});
  }

  void _start(Offset p, double pressure, Size size) {
    if (tool == StrokeTool.eraser) {
      _erase(p, size);
      return;
    }
    active
      ..clear()
      ..add(normalizePoint(p, size, pressure: pressure));
    setState(() {});
  }

  void _move(Offset p, double pressure, Size size) {
    if (tool == StrokeTool.eraser) {
      _erase(p, size);
      return;
    }
    if (active.isEmpty) return;
    active.add(normalizePoint(p, size, pressure: pressure));
    setState(() {});
  }

  void _end() {
    if (active.isEmpty) return;
    strokes.add(Stroke(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        documentId: widget.documentId,
        pageId: pageId,
        tool: tool,
        points: List.of(active),
        color: color,
        width: width,
        opacity: tool == StrokeTool.highlighter ? .35 : 1,
        order: strokes.length,
        createdAt: DateTime.now()));
    active.clear();
    redo.clear();
    _scheduleSave();
    setState(() {});
  }

  void _erase(Offset p, Size size) {
    final n = normalizePoint(p, size);
    final radius = (width / size.width).clamp(.002, .12);
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

  void _undo() {
    if (strokes.isEmpty) return;
    redo.add(strokes.removeLast());
    _scheduleSave();
    setState(() {});
  }

  void _redo() {
    if (redo.isEmpty) return;
    strokes.add(redo.removeLast());
    _scheduleSave();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text('${widget.title}  $pageIndex/$pageCount'),
          actions: [
            IconButton(
                onPressed:
                    pageIndex > 1 ? () => _switchPage(pageIndex - 1) : null,
                tooltip: '이전 페이지',
                icon: const Icon(Icons.chevron_left)),
            IconButton(
                onPressed: pageIndex < pageCount
                    ? () => _switchPage(pageIndex + 1)
                    : null,
                tooltip: '다음 페이지',
                icon: const Icon(Icons.chevron_right)),
            IconButton(
                onPressed: _addPage,
                tooltip: '페이지 추가',
                icon: const Icon(Icons.note_add_outlined)),
            IconButton(
                onPressed: pageCount > 1 ? _deletePage : null,
                tooltip: '페이지 삭제',
                icon: const Icon(Icons.delete_outline)),
            IconButton(
                onPressed: strokes.isEmpty ? null : _undo,
                icon: const Icon(Icons.undo)),
            IconButton(
                onPressed: redo.isEmpty ? null : _redo,
                icon: const Icon(Icons.redo)),
            IconButton(
                onPressed: () =>
                    setState(() => toolbarVisible = !toolbarVisible),
                tooltip: toolbarVisible ? '편집 도구 숨기기' : '편집 도구 열기',
                icon: Icon(toolbarVisible
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down)),
            IconButton(
                onPressed: () {
                  strokes.clear();
                  redo.clear();
                  _scheduleSave();
                  setState(() {});
                },
                icon: const Icon(Icons.delete_sweep_outlined)),
          ]),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              if (toolbarVisible) _toolbar(context),
              Expanded(
                  child: Center(
                      child: AspectRatio(
                          aspectRatio: .7,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                                color: Colors.white,
                                boxShadow: [
                                  BoxShadow(
                                      blurRadius: 8, color: Colors.black12)
                                ]),
                            child: DrawingCanvas(
                                strokes: strokes,
                                activePoints: active,
                                tool: tool,
                                color: color,
                                width: width,
                                pageTemplateId: widget.pageTemplateId,
                                onStart: _start,
                                onMove: _move,
                                onEnd: _end),
                          )))),
            ]),
    );
  }

  Widget _toolbar(BuildContext context) => Material(
      color: Theme.of(context).colorScheme.surface,
      child: DecoratedBox(
          decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant))),
          child: SizedBox(
              height: 56,
              child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    IconButton(
                        onPressed: () => setState(() => tool = StrokeTool.pen),
                        color: tool == StrokeTool.pen
                            ? Theme.of(context).colorScheme.primary
                            : null,
                        icon: const Icon(Icons.edit)),
                    IconButton(
                        onPressed: () =>
                            setState(() => tool = StrokeTool.highlighter),
                        color: tool == StrokeTool.highlighter
                            ? Theme.of(context).colorScheme.primary
                            : null,
                        icon: const Icon(Icons.highlight)),
                    IconButton(
                        onPressed: () =>
                            setState(() => tool = StrokeTool.eraser),
                        color: tool == StrokeTool.eraser
                            ? Theme.of(context).colorScheme.primary
                            : null,
                        icon: const Icon(Icons.auto_fix_normal)),
                    PopupMenuButton<Color>(
                        icon: Icon(Icons.color_lens, color: color),
                        onSelected: (v) => setState(() {
                              color = v;
                              tool = StrokeTool.pen;
                            }),
                        itemBuilder: (_) => [
                              Colors.black,
                              Colors.red,
                              Colors.blue,
                              Colors.green,
                              Colors.orange
                            ]
                                .map((v) => PopupMenuItem(
                                    value: v,
                                    child: Icon(Icons.circle, color: v)))
                                .toList()),
                    PopupMenuButton<double>(
                        tooltip: tool == StrokeTool.eraser ? '지우개 크기' : '펜 굵기',
                        icon: Icon(tool == StrokeTool.eraser
                            ? Icons.cleaning_services_outlined
                            : Icons.line_weight),
                        onSelected: (v) => setState(() => width = v),
                        itemBuilder: (_) => (tool == StrokeTool.eraser
                                ? [1, 2, 4, 8, 16, 32]
                                : [2, 4, 8, 14])
                            .map((v) => PopupMenuItem(
                                value: v.toDouble(), child: Text('${v}px')))
                            .toList()),
                  ])))));
}

class DrawingCanvas extends StatelessWidget {
  const DrawingCanvas(
      {required this.strokes,
      required this.activePoints,
      required this.tool,
      this.penType = PenType.ballpoint,
      required this.color,
      required this.width,
      this.pageTemplateId = 'blank',
      required this.onStart,
      required this.onMove,
      required this.onEnd,
      super.key});
  final List<Stroke> strokes;
  final List<StrokePoint> activePoints;
  final StrokeTool tool;
  final PenType penType;
  final Color color;
  final double width;
  final String pageTemplateId;
  final void Function(Offset, double, Size) onStart;
  final void Function(Offset, double, Size) onMove;
  final VoidCallback onEnd;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => onStart(e.localPosition, e.pressure, size),
            onPointerMove: (e) => onMove(e.localPosition, e.pressure, size),
            onPointerUp: (_) => onEnd(),
            child: CustomPaint(
                painter: _NotebookPagePainter(pageTemplateId),
                foregroundPainter: StrokePainter(
                    strokes, activePoints, size, tool, color, width, penType),
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
      [this.activePenType = PenType.ballpoint]);
  final List<Stroke> strokes;
  final List<StrokePoint> active;
  final Size size;
  final StrokeTool activeTool;
  final Color activeColor;
  final double activeWidth;
  final PenType activePenType;
  @override
  void paint(Canvas canvas, Size _) {
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
