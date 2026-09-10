import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/annotation_store.dart';
import '../domain/drawing_shape.dart';
import '../domain/drawing_text.dart';
import '../domain/drawing_image.dart';
import '../domain/stroke.dart';

enum EraserMode { partial, wholeStroke }

enum LassoMode { freeform, rectangle }

const _drawingPerfEnabled = kDebugMode || kProfileMode;
const _toolbarPopupAnimation = AnimationStyle(
  curve: Curves.easeOutCubic,
  reverseCurve: Curves.easeInCubic,
  duration: Duration(milliseconds: 160),
  reverseDuration: Duration(milliseconds: 120),
);

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
  bool get _perfEnabled => kDebugMode || kProfileMode;
  bool _instrumentationEnabled = true;
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
  final canvasRevision = ValueNotifier<int>(0);
  final staticRevisionNotifier = ValueNotifier<int>(0);
  int staticRevision = 0;
  int _editorBuilds = 0;
  int _pointerMoves = 0;
  int _painterRepaints = 0;
  int _staticPainterRepaints = 0;
  int _activePainterRepaints = 0;
  int _activeRevisionUpdates = 0;
  // Pointer moves can arrive faster than Flutter can present a frame. Keep
  // collecting points immediately, but coalesce active-layer invalidations to
  // at most one notifier update per frame.
  bool _activeRevisionScheduled = false;
  int _activeRevisionGeneration = 0;
  int _undoEstimatedBytes = 0;
  int _redoEstimatedBytes = 0;
  int _staticObjectPaintCount = 0;
  int _rawMoveEvents = 0;
  int _acceptedPoints = 0;
  int _rejectedNearPoints = 0;
  double _totalPointDistancePx = 0;
  double _minPointDistancePx = double.infinity;
  double _maxPointDistancePx = 0;
  int _pathBuildCount = 0;
  int _pathBuildTotalUs = 0;
  int _pathBuildMaxUs = 0;
  int _fullPathRebuildCount = 0;
  int _incrementalSegmentBuildCount = 0;
  int _incrementalBuildTotalUs = 0;
  int _incrementalBuildMaxUs = 0;
  int _activePaintTotalUs = 0;
  int _activePaintMaxUs = 0;
  int _activePaintSamples = 0;
  int _overlayPaintTotalUs = 0;
  int _overlayPaintMaxUs = 0;
  int _overlayPaintSamples = 0;
  int _pictureDrawTotalUs = 0;
  int _pictureDrawMaxUs = 0;
  int _pictureDrawSamples = 0;
  int _activePathDrawTotalUs = 0;
  int _activePathDrawMaxUs = 0;
  int _activePathDrawSamples = 0;
  Stopwatch? _strokeClock;
  Duration _frameTotal = Duration.zero;
  Duration _frameMax = Duration.zero;
  int _frameSamples = 0;
  final _frameDurationsUs = <int>[];
  final _buildDurationsUs = <int>[];
  final _rasterDurationsUs = <int>[];
  _PerfSample? _lastPerfSample;
  bool _benchmarkReplayActive = false;
  bool _useIncrementalActivePath = true;
  bool pickingImage = false;
  DrawingText? editingText;
  _PageSnapshot? textEditBaseline;
  final textController = TextEditingController();
  final textFocus = FocusNode();
  double textFontSize = 18;
  bool textBold = false;
  String textAlignment = 'left';
  _PageSnapshot? selectionMoveBaseline;
  _PageSnapshot? eraserBaseline;
  StrokePoint? selectionMoveOrigin;
  Rect? selectionMoveBounds;
  bool movingSelection = false;
  bool resizingSelection = false;
  _ResizeHandle? activeResizeHandle;
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
  double highlighterOpacity = .35;
  double eraserWidth = 10;
  EraserMode eraserMode = EraserMode.partial;
  LassoMode lassoMode = LassoMode.freeform;
  bool lassoIncludeStrokes = true;
  bool lassoIncludeTexts = true;
  bool lassoIncludeImages = true;
  bool loaded = false;
  bool toolbarVisible = true;
  late int pageCount = widget.initialPageCount;
  late String title = widget.title;
  int pageIndex = 1;
  int pageRotation = 0;
  String get pageId => 'page_$pageIndex';
  double get activeWidth => switch (tool) {
        StrokeTool.eraser => eraserWidth,
        StrokeTool.highlighter => highlighterWidth,
        StrokeTool.text => textFontSize,
        _ => penWidth,
      };
  Color get activeColor =>
      tool == StrokeTool.highlighter ? highlighterColor : penColor;

  void _bumpCanvas({bool staticLayer = false}) {
    canvasRevision.value++;
    if (_perfEnabled && !staticLayer) {
      _activeRevisionUpdates++;
    }
    if (staticLayer) {
      staticRevision++;
      staticRevisionNotifier.value++;
    }
  }

  void _bumpActiveCanvas() {
    if (_activeRevisionScheduled) return;
    _activeRevisionScheduled = true;
    final generation = ++_activeRevisionGeneration;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      if (generation != _activeRevisionGeneration) return;
      _activeRevisionScheduled = false;
      if (!mounted) return;
      canvasRevision.value++;
      if (_perfEnabled) _activeRevisionUpdates++;
    });
  }

  void _flushActiveCanvas() {
    if (!_activeRevisionScheduled) return;
    // The scheduled callback may still run later in this frame. Mark it as
    // consumed and publish the latest active points now so pointer-up never
    // commits a stroke before its final segment is visible.
    _activeRevisionScheduled = false;
    _activeRevisionGeneration++;
    canvasRevision.value++;
    if (_perfEnabled) _activeRevisionUpdates++;
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    if (!_perfEnabled || _strokeClock == null) return;
    for (final timing in timings) {
      final frame = timing.buildDuration + timing.rasterDuration;
      _frameTotal += frame;
      if (frame > _frameMax) _frameMax = frame;
      _frameSamples++;
      _frameDurationsUs.add(frame.inMicroseconds);
      _buildDurationsUs.add(timing.buildDuration.inMicroseconds);
      _rasterDurationsUs.add(timing.rasterDuration.inMicroseconds);
    }
  }

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
    _bumpCanvas();
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
                  (color: Colors.black, label: '검정'),
                  (color: Color(0xff3f6f9f), label: '파랑'),
                  (color: Color(0xffc95656), label: '빨강'),
                  (color: Color(0xff4e8b68), label: '초록'),
                  (color: Color(0xffd58b3a), label: '주황'),
                ])
                  _PaletteColorButton(
                    color: swatch.color,
                    label: swatch.label,
                    selected: swatch.color == currentColor,
                    onTap: () => Navigator.pop(sheetContext, swatch.color),
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
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    _load();
  }

  Future<void> _load() async {
    final page = await store.loadPage(widget.documentId, pageId);
    final prefs = await SharedPreferences.getInstance();
    pageRotation = prefs.getInt(_rotationKey(pageId)) ?? 0;
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
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    _activeRevisionScheduled = false;
    canvasRevision.dispose();
    staticRevisionNotifier.dispose();
    saveTimer?.cancel();
    // Decoded page images are native resources; release them when leaving the
    // editor so long editing sessions do not retain bitmap memory.
    for (final image in imageCache.values) {
      image.dispose();
    }
    imageCache.clear();
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

  /// Creates an in-memory workload for profiling. It is debug-only and never
  /// scheduled for persistence, so user documents are not modified on disk.
  void _loadDebugBenchmark(int count) {
    if (!_perfEnabled) return;
    strokes
      ..clear()
      ..addAll(List.generate(count, (index) {
        final y = .08 + (index % 80) * .0105;
        final x = .06 + ((index * 37) % 88) / 1000;
        return Stroke(
          id: 'benchmark-$count-$index',
          documentId: widget.documentId,
          pageId: pageId,
          tool: StrokeTool.pen,
          points: [
            StrokePoint(x, y, 1),
            StrokePoint((x + .08).clamp(.0, .98), (y + .018).clamp(.0, .98), 1),
            StrokePoint((x + .16).clamp(.0, .98), (y + .006).clamp(.0, .98), 1),
          ],
          color: const Color(0xff263238),
          width: 3,
          opacity: 1,
          order: index,
          createdAt: DateTime.now(),
        );
      }));
    shapes.clear();
    images.clear();
    _clearSelectionState();
    _bumpCanvas(staticLayer: true);
    setState(() {});
  }

  List<Offset> _debugReplayPath(String preset) {
    switch (preset) {
      case 'straightSlow':
        return [
          for (var i = 0; i < 80; i++) Offset(.12 + i * .009, .18 + i * .002)
        ];
      case 'straightFast':
        return [
          for (var i = 0; i < 24; i++) Offset(.12 + i * .03, .28 + i * .004)
        ];
      case 'circle':
        return [
          for (var i = 0; i <= 96; i++)
            Offset(.5 + .28 * math.cos(i * 2 * math.pi / 96),
                .42 + .18 * math.sin(i * 2 * math.pi / 96)),
        ];
      case 'zigzag':
        return [
          for (var i = 0; i < 80; i++)
            Offset(.12 + i * .009, .25 + (i.isEven ? .08 : -.08)),
        ];
      case 'handwritingLike':
        return [
          for (var i = 0; i < 120; i++)
            Offset(.12 + i * .0065,
                .42 + .035 * math.sin(i * .28) + .012 * math.sin(i * .83)),
        ];
      case 'longCurve250':
      case 'longCurve500':
      case 'longCurve1000':
        final count = int.parse(preset.replaceAll('longCurve', ''));
        return [
          for (var i = 0; i < count; i++)
            Offset(.08 + .84 * i / (count - 1),
                .42 + .22 * math.sin(i * 2 * math.pi / 110)),
        ];
      default:
        return _debugReplayPath('straightSlow');
    }
  }

  Future<void> _runDebugReplay(String preset,
      {bool pressureReplay = false}) async {
    if (!_perfEnabled || !mounted) return;
    final renderSize = MediaQuery.sizeOf(context).width;
    final size = Size(renderSize, renderSize / .7);
    final points = _debugReplayPath(preset);
    final previousTool = tool;
    tool = StrokeTool.pen;
    _benchmarkReplayActive = true;
    try {
      double pressureAt(int index) => pressureReplay
          ? (.5 + .5 * math.sin(index * 2 * math.pi / 37)).clamp(.1, 1.0)
          : 1.0;
      _start(
          Offset(points.first.dx * size.width, points.first.dy * size.height),
          pressureAt(0),
          size);
      for (var index = 1; index < points.length; index++) {
        final point = points[index];
        await Future<void>.delayed(const Duration(milliseconds: 8));
        _move(Offset(point.dx * size.width, point.dy * size.height),
            pressureAt(index), size);
      }
      _end();
      await SchedulerBinding.instance.endOfFrame;
    } finally {
      _benchmarkReplayActive = false;
      tool = previousTool;
    }
  }

  Future<void> _runDebugReplayBenchmark() async {
    if (!_perfEnabled || !mounted) return;
    final originalPage = _snapshot();
    final originalUndo = List<_PageSnapshot>.of(undoHistory);
    final originalRedo = List<_PageSnapshot>.of(redoHistory);
    const workloads = kProfileMode ? [500, 1000] : [100, 500, 1000];
    const presets = kProfileMode
        ? ['circle', 'handwritingLike']
        : [
            'straightSlow',
            'straightFast',
            'circle',
            'zigzag',
            'handwritingLike'
          ];
    debugPrint(
        '[DrawingBenchmark] begin mode=${kProfileMode ? 'profile' : 'debug'} runs=5 warmup=1');
    try {
      for (final workload in workloads) {
        for (final preset in presets) {
          // Reset before every preset so each series has exactly the same
          // committed-object workload and never includes prior replay strokes.
          _loadDebugBenchmark(workload);
          await SchedulerBinding.instance.endOfFrame;
          final samples = <_PerfSample>[];
          for (var run = 0; run < 6; run++) {
            await _runDebugReplay(preset);
            if (run == 0) {
              debugPrint(
                  '[DrawingBenchmark] warmup workload=$workload replay=$preset');
            } else {
              final sample = _lastPerfSample;
              if (sample != null) {
                samples.add(sample);
                debugPrint(
                    '[DrawingBenchmark] workload=$workload replay=$preset run=$run '
                    'raw=${sample.rawMoveEvents} accepted=${sample.acceptedPoints} '
                    'rejected=${sample.rejectedNearPoints} reduction=${sample.reductionRate.toStringAsFixed(1)}% '
                    'avgDistance=${sample.avgPointDistance.toStringAsFixed(2)} '
                    'minDistance=${sample.minPointDistance.toStringAsFixed(2)} '
                    'maxDistance=${sample.maxPointDistance.toStringAsFixed(2)} '
                    'totalDistance=${sample.totalStrokeDistance.toStringAsFixed(2)} '
                    'pathCount=${sample.pathBuildCount} pathAvgUs=${sample.pathBuildAvgUs} pathMaxUs=${sample.pathBuildMaxUs} '
                    'editorBuilds=${sample.editorBuilds} staticRepaints=${sample.staticPainterRepaints} '
                    'activeRepaints=${sample.activePainterRepaints} staticObjects=${sample.staticObjectPaintCount} '
                    'avgFrame=${sample.avgFrameMs.toStringAsFixed(2)} p95=${sample.p95FrameMs.toStringAsFixed(2)} '
                    'maxFrame=${sample.maxFrameMs.toStringAsFixed(2)} elapsed=${sample.strokeElapsedMs}');
              }
            }
          }
          _logReplayAggregate(workload, preset, samples);
        }
      }
      debugPrint('[DrawingBenchmark] end');
    } finally {
      _replacePage(originalPage);
      undoHistory
        ..clear()
        ..addAll(originalUndo);
      redoHistory
        ..clear()
        ..addAll(originalRedo);
      active.clear();
      activeShape = null;
      _refreshHistoryMemoryEstimate();
      if (mounted) setState(() {});
    }
  }

  Future<void> _runLongStrokeBenchmark({bool pressureReplay = false}) async {
    if (!_perfEnabled || !mounted) return;
    final originalPage = _snapshot();
    final originalUndo = List<_PageSnapshot>.of(undoHistory);
    final originalRedo = List<_PageSnapshot>.of(redoHistory);
    const workloads = [250, 500, 1000];
    try {
      debugPrint('[DrawingBenchmark] long-stroke begin runs=5 warmup=1');
      for (final workload in workloads) {
        final preset = 'longCurve$workload';
        _loadDebugBenchmark(workload);
        await SchedulerBinding.instance.endOfFrame;
        final samples = <_PerfSample>[];
        for (var run = 0; run < 6; run++) {
          await _runDebugReplay(preset, pressureReplay: pressureReplay);
          final sample = _lastPerfSample;
          if (run > 0 && sample != null) samples.add(sample);
        }
        _logReplayAggregate(workload, preset, samples,
            label: pressureReplay
                ? 'long-pressure-incremental'
                : (_useIncrementalActivePath
                    ? 'long-incremental'
                    : 'long-legacy'));
      }
      debugPrint('[DrawingBenchmark] long-stroke end');
    } finally {
      _replacePage(originalPage);
      undoHistory
        ..clear()
        ..addAll(originalUndo);
      redoHistory
        ..clear()
        ..addAll(originalRedo);
      active.clear();
      activeShape = null;
      _refreshHistoryMemoryEstimate();
      if (mounted) setState(() {});
    }
  }

  /// Runs the small matrix used to attribute frame spikes. It deliberately
  /// changes no drawing behavior; only the runtime cache and instrumentation
  /// switches are toggled around the same replay input.
  Future<void> _runFrameDiagnosisBenchmark() async {
    if (!_perfEnabled || !mounted) return;
    const workloads = [500, 1000];
    const presets = ['circle', 'handwritingLike'];
    final oldIncremental = _useIncrementalActivePath;
    final oldInstrumentation = _instrumentationEnabled;
    const configs = [
      ('incremental+on', true, true),
      ('incremental+off', true, false),
      ('legacy+off', false, false),
    ];
    debugPrint(
        '[DrawingDiagnosis] begin mode=${kProfileMode ? 'profile' : 'debug'}');
    try {
      for (final config in configs) {
        _useIncrementalActivePath = config.$2;
        _instrumentationEnabled = config.$3;
        for (final workload in workloads) {
          for (final preset in presets) {
            _loadDebugBenchmark(workload);
            await SchedulerBinding.instance.endOfFrame;
            final samples = <_PerfSample>[];
            for (var run = 0; run < 6; run++) {
              await _runDebugReplay(preset);
              final sample = _lastPerfSample;
              if (run > 0 && sample != null) {
                samples.add(sample);
              }
            }
            _logReplayAggregate(workload, preset, samples, label: config.$1);
          }
        }
      }
    } finally {
      _useIncrementalActivePath = oldIncremental;
      _instrumentationEnabled = oldInstrumentation;
    }
    debugPrint('[DrawingDiagnosis] end');
  }

  void _logReplayAggregate(
      int workload, String preset, List<_PerfSample> samples,
      {String label = 'incremental+instrumentation'}) {
    if (samples.isEmpty) return;
    double avg(num Function(_PerfSample) value) =>
        samples
            .map((sample) => value(sample).toDouble())
            .reduce((a, b) => a + b) /
        samples.length;
    double max(num Function(_PerfSample) value) =>
        samples.map((sample) => value(sample).toDouble()).reduce(math.max);
    debugPrint(
        '[DrawingBenchmarkAggregate] mode=$label workload=$workload replay=$preset '
        'runs=${samples.length} '
        'rawAvg=${avg((s) => s.rawMoveEvents).toStringAsFixed(1)} rawMax=${max((s) => s.rawMoveEvents).round()} '
        'acceptedAvg=${avg((s) => s.acceptedPoints).toStringAsFixed(1)} acceptedMax=${max((s) => s.acceptedPoints).round()} '
        'rejectedAvg=${avg((s) => s.rejectedNearPoints).toStringAsFixed(1)} rejectedMax=${max((s) => s.rejectedNearPoints).round()} '
        'reductionAvg=${avg((s) => s.reductionRate).toStringAsFixed(1)}% reductionMax=${max((s) => s.reductionRate).toStringAsFixed(1)}% '
        'distanceAvg=${avg((s) => s.avgPointDistance).toStringAsFixed(2)} totalDistanceAvg=${avg((s) => s.totalStrokeDistance).toStringAsFixed(2)} '
        'pathAvgUs=${avg((s) => s.pathBuildAvgUs).round()} pathMaxUs=${max((s) => s.pathBuildMaxUs).round()} '
        'fullRebuildAvg=${avg((s) => s.fullPathRebuildCount).toStringAsFixed(1)} '
        'incrementalSegmentsAvg=${avg((s) => s.incrementalSegmentBuildCount).toStringAsFixed(1)} '
        'incrementalAvgUs=${avg((s) => s.incrementalBuildAvgUs).round()} incrementalMaxUs=${max((s) => s.incrementalBuildMaxUs).round()} '
        'activePaintAvgUs=${avg((s) => s.activePaintAvgUs).round()} activePaintMaxUs=${max((s) => s.activePaintMaxUs).round()} '
        'pictureDrawAvgUs=${avg((s) => s.pictureDrawAvgUs).round()} pictureDrawMaxUs=${max((s) => s.pictureDrawMaxUs).round()} '
        'activePathDrawAvgUs=${avg((s) => s.activePathDrawAvgUs).round()} activePathDrawMaxUs=${max((s) => s.activePathDrawMaxUs).round()} '
        'overlayPaintAvgUs=${avg((s) => s.overlayPaintAvgUs).round()} overlayPaintMaxUs=${max((s) => s.overlayPaintMaxUs).round()} '
        'buildAvg=${avg((s) => s.buildAvgMs).toStringAsFixed(2)} buildP95=${avg((s) => s.buildP95Ms).toStringAsFixed(2)} buildMax=${max((s) => s.buildMaxMs).toStringAsFixed(2)} '
        'rasterAvg=${avg((s) => s.rasterAvgMs).toStringAsFixed(2)} rasterP95=${avg((s) => s.rasterP95Ms).toStringAsFixed(2)} rasterMax=${max((s) => s.rasterMaxMs).toStringAsFixed(2)} '
        'editorBuildsAvg=${avg((s) => s.editorBuilds).toStringAsFixed(1)} staticRepaintsAvg=${avg((s) => s.staticPainterRepaints).toStringAsFixed(1)} '
        'activeRepaintsAvg=${avg((s) => s.activePainterRepaints).toStringAsFixed(1)} activeRevisionAvg=${avg((s) => s.activeRevisionUpdates).toStringAsFixed(1)} '
        'staticObjectsAvg=${avg((s) => s.staticObjectPaintCount).toStringAsFixed(1)} '
        'frameAvg=${avg((s) => s.avgFrameMs).toStringAsFixed(2)} frameP95Avg=${avg((s) => s.p95FrameMs).toStringAsFixed(2)} '
        'frameMax=${max((s) => s.maxFrameMs).toStringAsFixed(2)} elapsedAvg=${avg((s) => s.strokeElapsedMs).round()} elapsedMax=${max((s) => s.strokeElapsedMs).round()}');
  }

  void _recordHistory([_PageSnapshot? before]) {
    final snapshot = before ?? _snapshot();
    undoHistory.add(snapshot);
    if (undoHistory.length > 80) undoHistory.removeAt(0);
    redoHistory.clear();
    _refreshHistoryMemoryEstimate();
  }

  int _estimateSnapshotBytes(_PageSnapshot snapshot) {
    // Runtime estimate only: domain objects remain shared between snapshots,
    // so count the list/point payload that a snapshot keeps reachable. This
    // does not affect the persisted format or undo semantics.
    var points = 0;
    for (final stroke in snapshot.strokes) {
      points += stroke.points.length;
    }
    return 256 +
        snapshot.strokes.length * 160 +
        snapshot.shapes.length * 160 +
        snapshot.texts.length * 192 +
        snapshot.images.length * 192 +
        points * 32;
  }

  void _refreshHistoryMemoryEstimate() {
    if (!_perfEnabled) return;
    _undoEstimatedBytes = undoHistory.fold<int>(
        0, (total, snapshot) => total + _estimateSnapshotBytes(snapshot));
    _redoEstimatedBytes = redoHistory.fold<int>(
        0, (total, snapshot) => total + _estimateSnapshotBytes(snapshot));
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
    _bumpCanvas(staticLayer: true);
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
    activeResizeHandle = null;
    rotatingSelection = false;
    rotationStartAngle = 0;
    _bumpCanvas();
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
    final prefs = await SharedPreferences.getInstance();
    pageRotation = prefs.getInt(_rotationKey('page_$next')) ?? 0;
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
    pageRotation = 0;
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
          onDeletePages: (pages) async {
            Navigator.of(sheetContext).pop();
            await _deletePages(pages);
          },
          onMovePage: (page, direction) async {
            Navigator.of(sheetContext).pop();
            await _movePage(page, direction);
          },
          onMovePageTo: (source, target) async {
            Navigator.of(sheetContext).pop();
            final direction = source < target ? 1 : -1;
            var current = source;
            while (current != target) {
              await _movePage(current, direction);
              current += direction;
            }
          },
        ),
      );

  Future<void> _movePage(int sourcePage, int direction) async {
    final targetPage = sourcePage + direction;
    if (targetPage < 1 || targetPage > pageCount) return;
    await _save();
    await store.swapNotebookPages(widget.documentId,
        firstPage: sourcePage, secondPage: targetPage);
    final prefs = await SharedPreferences.getInstance();
    final sourceRotation = prefs.getInt(_rotationKey('page_$sourcePage')) ?? 0;
    final targetRotation = prefs.getInt(_rotationKey('page_$targetPage')) ?? 0;
    await prefs.setInt(_rotationKey('page_$sourcePage'), targetRotation);
    await prefs.setInt(_rotationKey('page_$targetPage'), sourceRotation);
    if (pageIndex == sourcePage) {
      pageIndex = targetPage;
    } else if (pageIndex == targetPage) {
      pageIndex = sourcePage;
    }
    _replaceLoadedPage(await store.loadPage(widget.documentId, pageId));
    pageRotation = prefs.getInt(_rotationKey(pageId)) ?? 0;
    await _preloadImages(images);
    undoHistory.clear();
    redoHistory.clear();
    _clearSelectionState();
    if (mounted) setState(() {});
  }

  Future<void> _duplicatePage(int sourcePage) async {
    await _save();
    final source = await store.loadPage(widget.documentId, 'page_$sourcePage');
    await _shiftRotationKeysAfterInsert(sourcePage, pageCount);
    await store.insertNotebookPage(widget.documentId,
        sourcePage: sourcePage, pageCount: pageCount);
    await store.savePage(widget.documentId, 'page_${sourcePage + 1}', source);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_rotationKey('page_${sourcePage + 1}'),
        prefs.getInt(_rotationKey('page_$sourcePage')) ?? 0);
    pageCount++;
    if (pageIndex > sourcePage) pageIndex++;
    widget.onPageCountChanged?.call(pageCount);
    if (mounted) setState(() {});
  }

  String _rotationKey(String page) =>
      'docnote.pageRotation.${widget.documentId}.$page';

  Future<void> _rotatePage() async {
    pageRotation = (pageRotation + 1) % 4;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_rotationKey(pageId), pageRotation);
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
    await _shiftRotationKeysAfterDelete(targetPage, pageCount);
    await store.deleteNotebookPageAndShift(
      widget.documentId,
      removedPage: targetPage,
      pageCount: pageCount,
    );
    pageCount--;
    pageIndex = math.min(targetPage, pageCount);
    _replaceLoadedPage(await store.loadPage(widget.documentId, pageId));
    final prefs = await SharedPreferences.getInstance();
    pageRotation = prefs.getInt(_rotationKey(pageId)) ?? 0;
    await _preloadImages(images);
    undoHistory.clear();
    redoHistory.clear();
    _clearSelectionState();
    widget.onPageCountChanged?.call(pageCount);
    if (mounted) setState(() {});
  }

  Future<void> _deletePages(Set<int> targets) async {
    if (targets.isEmpty || targets.length >= pageCount) return;
    await _save();
    for (final target in targets.toList()..sort((a, b) => b.compareTo(a))) {
      await _shiftRotationKeysAfterDelete(target, pageCount);
      await store.deleteNotebookPageAndShift(widget.documentId,
          removedPage: target, pageCount: pageCount);
      pageCount--;
    }
    pageIndex = math.min(pageIndex, pageCount);
    _replaceLoadedPage(await store.loadPage(widget.documentId, pageId));
    final prefs = await SharedPreferences.getInstance();
    pageRotation = prefs.getInt(_rotationKey(pageId)) ?? 0;
    await _preloadImages(images);
    undoHistory.clear();
    redoHistory.clear();
    _clearSelectionState();
    widget.onPageCountChanged?.call(pageCount);
    if (mounted) setState(() {});
  }

  Future<void> _shiftRotationKeysAfterDelete(
      int removedPage, int oldPageCount) async {
    final prefs = await SharedPreferences.getInstance();
    for (var page = removedPage; page < oldPageCount; page++) {
      final next = prefs.getInt(_rotationKey('page_${page + 1}'));
      final key = _rotationKey('page_$page');
      if (next == null) {
        await prefs.remove(key);
      } else {
        await prefs.setInt(key, next);
      }
    }
    await prefs.remove(_rotationKey('page_$oldPageCount'));
  }

  Future<void> _shiftRotationKeysAfterInsert(
      int sourcePage, int oldPageCount) async {
    final prefs = await SharedPreferences.getInstance();
    for (var page = oldPageCount; page > sourcePage; page--) {
      final previous = prefs.getInt(_rotationKey('page_$page'));
      final key = _rotationKey('page_${page + 1}');
      if (previous == null) {
        await prefs.remove(key);
      } else {
        await prefs.setInt(key, previous);
      }
    }
  }

  void _start(Offset p, double pressure, Size size) {
    if (_perfEnabled) {
      _editorBuilds = 0;
      _painterRepaints = 0;
      _staticPainterRepaints = 0;
      _activePainterRepaints = 0;
      _activeRevisionUpdates = 0;
      _staticObjectPaintCount = 0;
      _pointerMoves = 0;
      _strokeClock = Stopwatch()..start();
      _frameTotal = Duration.zero;
      _frameMax = Duration.zero;
      _frameSamples = 0;
      _frameDurationsUs.clear();
      _buildDurationsUs.clear();
      _rasterDurationsUs.clear();
      _pathBuildCount = 0;
      _pathBuildTotalUs = 0;
      _pathBuildMaxUs = 0;
      _fullPathRebuildCount = 0;
      _incrementalSegmentBuildCount = 0;
      _incrementalBuildTotalUs = 0;
      _incrementalBuildMaxUs = 0;
      _activePaintTotalUs = 0;
      _activePaintMaxUs = 0;
      _activePaintSamples = 0;
      _overlayPaintTotalUs = 0;
      _overlayPaintMaxUs = 0;
      _overlayPaintSamples = 0;
      _pictureDrawTotalUs = 0;
      _pictureDrawMaxUs = 0;
      _pictureDrawSamples = 0;
      _activePathDrawTotalUs = 0;
      _activePathDrawMaxUs = 0;
      _activePathDrawSamples = 0;
      _rawMoveEvents = 0;
      _acceptedPoints = 1;
      _rejectedNearPoints = 0;
      _totalPointDistancePx = 0;
      _minPointDistancePx = double.infinity;
      _maxPointDistancePx = 0;
    }
    if (tool == StrokeTool.shapeLine ||
        tool == StrokeTool.shapeRectangle ||
        tool == StrokeTool.shapeEllipse ||
        tool == StrokeTool.shapeArrow ||
        tool == StrokeTool.shapeTriangle) {
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
    _bumpCanvas();
  }

  void _move(Offset p, double pressure, Size size) {
    _pointerMoves++;
    _rawMoveEvents++;
    if (tool == StrokeTool.shapeLine ||
        tool == StrokeTool.shapeRectangle ||
        tool == StrokeTool.shapeEllipse ||
        tool == StrokeTool.shapeArrow ||
        tool == StrokeTool.shapeTriangle) {
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
    // Compare movement in physical canvas pixels rather than normalized
    // coordinates so sampling stays consistent across phone/tablet sizes.
    final dxPixels = (next.x - previous.x) * size.width;
    final dyPixels = (next.y - previous.y) * size.height;
    final distance = math.sqrt(dxPixels * dxPixels + dyPixels * dyPixels);
    _totalPointDistancePx += distance;
    _minPointDistancePx = math.min(_minPointDistancePx, distance);
    _maxPointDistancePx = math.max(_maxPointDistancePx, distance);
    // Keep the pre-optimization normalized threshold for this baseline. The
    // physical pixel distance above is instrumentation only at this stage.
    final normalizedDx = next.x - previous.x;
    final normalizedDy = next.y - previous.y;
    final normalizedDistanceSquared =
        normalizedDx * normalizedDx + normalizedDy * normalizedDy;
    if (normalizedDistanceSquared < .0000015) {
      active[active.length - 1] = next;
      _rejectedNearPoints++;
    } else {
      active.add(next);
      _acceptedPoints++;
    }
    _bumpActiveCanvas();
  }

  List<double> _timingStats(List<int> values) {
    if (values.isEmpty) return [0, 0, 0];
    final sorted = List<int>.of(values)..sort();
    final average = sorted.reduce((a, b) => a + b) / sorted.length / 1000.0;
    final p95 = sorted[((sorted.length - 1) * .95).round()] / 1000.0;
    final max = sorted.last / 1000.0;
    return [average, p95, max];
  }

  void _end() {
    if (tool == StrokeTool.shapeLine ||
        tool == StrokeTool.shapeRectangle ||
        tool == StrokeTool.shapeEllipse ||
        tool == StrokeTool.shapeArrow ||
        tool == StrokeTool.shapeTriangle) {
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
    _flushActiveCanvas();
    _recordHistory();
    strokes.add(Stroke(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        documentId: widget.documentId,
        pageId: pageId,
        tool: tool,
        points: List.of(active),
        color: activeColor,
        width: activeWidth,
        opacity: tool == StrokeTool.highlighter ? highlighterOpacity : 1,
        order: strokes.length,
        createdAt: DateTime.now()));
    active.clear();
    if (!_benchmarkReplayActive) _scheduleSave();
    setState(() {});
    _bumpCanvas(staticLayer: true);
    if (_perfEnabled) {
      _strokeClock?.stop();
      final points = strokes.last.points.length;
      final averageMs = _frameSamples == 0
          ? 0.0
          : _frameTotal.inMicroseconds / _frameSamples / 1000.0;
      final sortedFrames = List<int>.of(_frameDurationsUs)..sort();
      final p95Ms = sortedFrames.isEmpty
          ? 0.0
          : sortedFrames[((sortedFrames.length - 1) * .95).round()] / 1000.0;
      final buildStats = _timingStats(_buildDurationsUs);
      final rasterStats = _timingStats(_rasterDurationsUs);
      _lastPerfSample = _PerfSample(
        rawMoveEvents: _rawMoveEvents,
        acceptedPoints: points,
        rejectedNearPoints: _rejectedNearPoints,
        avgPointDistance:
            _rawMoveEvents == 0 ? 0 : _totalPointDistancePx / _rawMoveEvents,
        minPointDistance:
            _minPointDistancePx.isFinite ? _minPointDistancePx : 0.0,
        maxPointDistance: _maxPointDistancePx,
        totalStrokeDistance: _totalPointDistancePx,
        pathBuildCount: _pathBuildCount,
        pathBuildAvgUs: _pathBuildCount == 0
            ? 0
            : (_pathBuildTotalUs / _pathBuildCount).round(),
        pathBuildMaxUs: _pathBuildMaxUs,
        fullPathRebuildCount: _fullPathRebuildCount,
        incrementalSegmentBuildCount: _incrementalSegmentBuildCount,
        incrementalBuildAvgUs: _incrementalSegmentBuildCount == 0
            ? 0
            : (_incrementalBuildTotalUs / _incrementalSegmentBuildCount)
                .round(),
        incrementalBuildMaxUs: _incrementalBuildMaxUs,
        activePaintAvgUs: _activePaintSamples == 0
            ? 0
            : (_activePaintTotalUs / _activePaintSamples).round(),
        activePaintMaxUs: _activePaintMaxUs,
        overlayPaintAvgUs: _overlayPaintSamples == 0
            ? 0
            : (_overlayPaintTotalUs / _overlayPaintSamples).round(),
        overlayPaintMaxUs: _overlayPaintMaxUs,
        pictureDrawAvgUs: _pictureDrawSamples == 0
            ? 0
            : (_pictureDrawTotalUs / _pictureDrawSamples).round(),
        pictureDrawMaxUs: _pictureDrawMaxUs,
        activePathDrawAvgUs: _activePathDrawSamples == 0
            ? 0
            : (_activePathDrawTotalUs / _activePathDrawSamples).round(),
        activePathDrawMaxUs: _activePathDrawMaxUs,
        editorBuilds: _editorBuilds,
        staticPainterRepaints: _staticPainterRepaints,
        activePainterRepaints: _activePainterRepaints,
        activeRevisionUpdates: _activeRevisionUpdates,
        staticObjectPaintCount: _staticObjectPaintCount,
        avgFrameMs: averageMs,
        p95FrameMs: p95Ms,
        maxFrameMs: _frameMax.inMicroseconds / 1000.0,
        strokeElapsedMs: _strokeClock?.elapsedMilliseconds ?? 0,
        buildAvgMs: buildStats[0],
        buildP95Ms: buildStats[1],
        buildMaxMs: buildStats[2],
        rasterAvgMs: rasterStats[0],
        rasterP95Ms: rasterStats[1],
        rasterMaxMs: rasterStats[2],
      );
      debugPrint('[DrawingPerf] moves=$_pointerMoves points=$points '
          'editorBuilds=$_editorBuilds painterRepaints=$_painterRepaints '
          'staticPainterRepaints=$_staticPainterRepaints '
          'activePainterRepaints=$_activePainterRepaints '
          'activeRevisionUpdates=$_activeRevisionUpdates '
          'staticObjectPaintCount=$_staticObjectPaintCount '
          'rawMoveEvents=$_rawMoveEvents acceptedPoints=$_acceptedPoints '
          'rejectedNearPoints=$_rejectedNearPoints '
          'avgPointDistancePx=${_rawMoveEvents == 0 ? 0 : (_totalPointDistancePx / _rawMoveEvents).toStringAsFixed(2)} '
          'minPointDistancePx=${_minPointDistancePx.isFinite ? _minPointDistancePx.toStringAsFixed(2) : 0} '
          'maxPointDistancePx=${_maxPointDistancePx.toStringAsFixed(2)} '
          'pathBuildCount=$_pathBuildCount pathBuildAvgUs=${_pathBuildCount == 0 ? 0 : (_pathBuildTotalUs / _pathBuildCount).round()} pathBuildMaxUs=$_pathBuildMaxUs '
          'fullPathRebuildCount=$_fullPathRebuildCount incrementalSegmentBuildCount=$_incrementalSegmentBuildCount '
          'incrementalBuildAvgUs=${_incrementalSegmentBuildCount == 0 ? 0 : (_incrementalBuildTotalUs / _incrementalSegmentBuildCount).round()} incrementalBuildMaxUs=$_incrementalBuildMaxUs '
          'activePaintAvgUs=${_activePaintSamples == 0 ? 0 : (_activePaintTotalUs / _activePaintSamples).round()} activePaintMaxUs=$_activePaintMaxUs '
          'overlayPaintAvgUs=${_overlayPaintSamples == 0 ? 0 : (_overlayPaintTotalUs / _overlayPaintSamples).round()} overlayPaintMaxUs=$_overlayPaintMaxUs '
          'undoDepth=${undoHistory.length} redoDepth=${redoHistory.length} '
          'undoEstimateKb=${(_undoEstimatedBytes / 1024).toStringAsFixed(1)} redoEstimateKb=${(_redoEstimatedBytes / 1024).toStringAsFixed(1)} '
          'frames=$_frameSamples avg=${averageMs.toStringAsFixed(2)}ms '
          'max=${(_frameMax.inMicroseconds / 1000.0).toStringAsFixed(2)}ms '
          'elapsed=${_strokeClock?.elapsedMilliseconds}ms');
      _strokeClock = null;
    }
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
    _bumpCanvas();
  }

  void _shapeMove(Offset point, Size size) {
    final shape = activeShape;
    if (shape == null) return;
    activeShape = shape.copyWith(endPoint: normalizePoint(point, size));
    _bumpCanvas();
  }

  void _shapeEnd() {
    final shape = activeShape;
    activeShape = null;
    if (shape == null ||
        (shape.startPoint.x == shape.endPoint.x &&
            shape.startPoint.y == shape.endPoint.y)) {
      _bumpCanvas(staticLayer: true);
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
    _bumpCanvas(staticLayer: true);
    setState(() {});
  }

  void _setShapeType(DrawingShapeType value) => setState(() {
        shapeType = value;
        tool = switch (value) {
          DrawingShapeType.line => StrokeTool.shapeLine,
          DrawingShapeType.rectangle => StrokeTool.shapeRectangle,
          DrawingShapeType.ellipse => StrokeTool.shapeEllipse,
          DrawingShapeType.arrow => StrokeTool.shapeArrow,
          DrawingShapeType.triangle => StrokeTool.shapeTriangle,
        };
        activeShape = null;
      });

  void _erase(Offset p, Size size) {
    final n = normalizePoint(p, size);
    final radius = (activeWidth / size.width).clamp(.002, .12);
    final kept = <Stroke>[];
    var changed = false;
    for (final stroke in strokes) {
      if (eraserMode == EraserMode.wholeStroke) {
        final intersectsEraser = stroke.points.any((point) {
          final dx = point.x - n.x;
          final dy = point.y - n.y;
          return dx * dx + dy * dy <= radius * radius;
        });
        if (intersectsEraser) {
          changed = true;
          continue;
        }
        kept.add(stroke);
        continue;
      }
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
      _bumpCanvas(staticLayer: true);
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
          bold: textBold,
          alignment: textAlignment,
        );
    if (hit != null) {
      textFontSize = hit.fontSize;
      penColor = hit.color;
      textBold = hit.bold;
      textAlignment = hit.alignment;
    }
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
      final value = editing.copyWith(
        text: next,
        fontSize: textFontSize,
        color: penColor,
        bold: textBold,
        alignment: textAlignment,
      );
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
    _bumpCanvas(staticLayer: true);
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
      _bumpCanvas(staticLayer: true);
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

  Future<void> _cropSelectedImage() async {
    if (selectedImageIds.length != 1) return;
    final id = selectedImageIds.first;
    final image = images.firstWhere((value) => value.id == id);
    var left = image.cropLeft;
    var top = image.cropTop;
    var right = image.cropRight;
    var bottom = image.cropBottom;
    final result = await showDialog<(double, double, double, double)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('이미지 자르기'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            _CropPreview(
              path: image.imagePath,
              crop: Rect.fromLTRB(left, top, right, bottom),
              onChanged: (crop) => setDialogState(() {
                left = crop.left;
                top = crop.top;
                right = crop.right;
                bottom = crop.bottom;
              }),
            ),
            const SizedBox(height: 12),
            _CropSlider(
                label: '왼쪽',
                value: left,
                min: 0,
                max: right - .05,
                onChanged: (value) => setDialogState(() => left = value)),
            _CropSlider(
                label: '위쪽',
                value: top,
                min: 0,
                max: bottom - .05,
                onChanged: (value) => setDialogState(() => top = value)),
            _CropSlider(
                label: '오른쪽',
                value: right,
                min: left + .05,
                max: 1,
                onChanged: (value) => setDialogState(() => right = value)),
            _CropSlider(
                label: '아래쪽',
                value: bottom,
                min: top + .05,
                max: 1,
                onChanged: (value) => setDialogState(() => bottom = value)),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소')),
            FilledButton(
                onPressed: () =>
                    Navigator.pop(context, (left, top, right, bottom)),
                child: const Text('적용')),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    _recordHistory();
    final updated = image.copyWith(
        cropLeft: result.$1,
        cropTop: result.$2,
        cropRight: result.$3,
        cropBottom: result.$4);
    images[images.indexWhere((value) => value.id == id)] = updated;
    _scheduleSave();
    _bumpCanvas(staticLayer: true);
    setState(() {});
  }

  void _undo() {
    if (undoHistory.isEmpty) return;
    redoHistory.add(_snapshot());
    _replacePage(undoHistory.removeLast());
    _refreshHistoryMemoryEstimate();
    _clearSelectionState();
    _scheduleSave();
    _bumpCanvas();
    setState(() {});
  }

  void _redo() {
    if (redoHistory.isEmpty) return;
    undoHistory.add(_snapshot());
    _replacePage(redoHistory.removeLast());
    _refreshHistoryMemoryEstimate();
    _clearSelectionState();
    _scheduleSave();
    _bumpCanvas(staticLayer: true);
    setState(() {});
  }

  void _selectionStart(Offset point, Size size) {
    final normalized = normalizePoint(point, size);
    final bounds = _selectedBounds();
    final resizeHandle =
        bounds == null ? null : _resizeHandleHit(bounds, normalized);
    final touchesResizeHandle = bounds != null &&
        ((selectedStrokeIds.isEmpty && selectedShapeIds.isNotEmpty) ||
            (selectedStrokeIds.isEmpty &&
                selectedShapeIds.isEmpty &&
                selectedTextIds.isEmpty &&
                selectedImageIds.length == 1)) &&
        resizeHandle != null;
    final touchesRotateHandle = bounds != null &&
        selectedStrokeIds.isEmpty &&
        ((selectedShapeIds.isNotEmpty &&
                selectedTextIds.isEmpty &&
                selectedImageIds.isEmpty) ||
            (selectedShapeIds.isEmpty &&
                selectedTextIds.isEmpty &&
                selectedImageIds.length == 1)) &&
        _rotationHandleHit(bounds, normalized);
    if (bounds != null &&
        (bounds.contains(Offset(normalized.x, normalized.y)) ||
            touchesResizeHandle ||
            touchesRotateHandle)) {
      rotatingSelection = touchesRotateHandle;
      resizingSelection = !rotatingSelection && touchesResizeHandle;
      activeResizeHandle = resizingSelection ? resizeHandle : null;
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
      activeResizeHandle = null;
      lassoPath.add(normalized);
    }
    _bumpCanvas();
    setState(() {});
  }

  void _selectionMove(Offset point, Size size) {
    final normalized = normalizePoint(point, size);
    if (!movingSelection && !resizingSelection && !rotatingSelection) {
      lassoPath.add(normalized);
      _bumpCanvas();
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
        images: baseline.images.map((image) {
          if (!selectedImageIds.contains(image.id)) return image;
          return image.copyWith(rotationRadians: image.rotationRadians + delta);
        }).toList(),
      ));
      _bumpCanvas();
      setState(() {});
      return;
    }
    if (resizingSelection) {
      final handle = activeResizeHandle ?? _ResizeHandle.bottomRight;
      final targetX = normalized.x.clamp(.0, 1.0);
      final targetY = normalized.y.clamp(.0, 1.0);
      final left = handle.horizontal == -1
          ? targetX.clamp(0.0, bounds.right - .02)
          : bounds.left;
      final right = handle.horizontal == 1
          ? targetX.clamp(bounds.left + .02, 1.0)
          : bounds.right;
      final top = handle.vertical == -1
          ? targetY.clamp(0.0, bounds.bottom - .02)
          : bounds.top;
      final bottom = handle.vertical == 1
          ? targetY.clamp(bounds.top + .02, 1.0)
          : bounds.bottom;
      final targetBounds = Rect.fromLTRB(left, top, right, bottom);
      final scaleX = targetBounds.width / bounds.width;
      final scaleY = targetBounds.height / bounds.height;
      _replacePage(_PageSnapshot(
        strokes: baseline.strokes,
        shapes: baseline.shapes.map((shape) {
          if (!selectedShapeIds.contains(shape.id)) return shape;
          return shape.copyWith(
            startPoint: _scaledPoint(shape.startPoint, bounds, scaleX, scaleY,
                offset: Offset(targetBounds.left - bounds.left,
                    targetBounds.top - bounds.top)),
            endPoint: _scaledPoint(shape.endPoint, bounds, scaleX, scaleY,
                offset: Offset(targetBounds.left - bounds.left,
                    targetBounds.top - bounds.top)),
          );
        }).toList(),
        texts: baseline.texts,
        images: baseline.images.map((image) {
          if (!selectedImageIds.contains(image.id)) return image;
          return image.copyWith(
              position: StrokePoint(targetBounds.left, targetBounds.top, 1),
              width: targetBounds.width,
              height: targetBounds.height);
        }).toList(),
      ));
      setState(() {});
      return;
    }
    final rawDx =
        (normalized.x - origin.x).clamp(-bounds.left, 1 - bounds.right);
    final rawDy =
        (normalized.y - origin.y).clamp(-bounds.top, 1 - bounds.bottom);
    final dx = _snappedSelectionDelta(rawDx, bounds.left, bounds.right)
        .clamp(-bounds.left, 1 - bounds.right);
    final dy = _snappedSelectionDelta(rawDy, bounds.top, bounds.bottom)
        .clamp(-bounds.top, 1 - bounds.bottom);
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
    _bumpCanvas();
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
      activeResizeHandle = null;
      movingSelection = false;
      resizingSelection = false;
      rotatingSelection = false;
      _bumpCanvas();
      setState(() {});
      return;
    }
    if (lassoPath.length < 3) {
      _clearSelectionState();
      _bumpCanvas();
      setState(() {});
      return;
    }
    final selectionPolygon = _lassoSelectionPolygon();
    final selectionBounds = _pointsBounds(selectionPolygon);
    selectedStrokeIds.clear();
    if (lassoIncludeStrokes) {
      selectedStrokeIds.addAll(strokes
          .where((stroke) =>
              _strokeIsInsideLasso(stroke, selectionPolygon, selectionBounds))
          .map((stroke) => stroke.id));
    }
    selectedShapeIds
      ..clear()
      ..addAll(lassoIncludeStrokes
          ? shapes
              .where((shape) =>
                  _shapeIsInsideLasso(shape, selectionPolygon, selectionBounds))
              .map((shape) => shape.id)
          : const <String>[]);
    selectedTextIds
      ..clear()
      ..addAll(lassoIncludeTexts
          ? texts
              .where((text) =>
                  _textIsInsideLasso(text, selectionPolygon, selectionBounds))
              .map((text) => text.id)
          : const <String>[]);
    selectedImageIds
      ..clear()
      ..addAll(lassoIncludeImages
          ? images
              .where((image) =>
                  _imageIsInsideLasso(image, selectionPolygon, selectionBounds))
              .map((image) => image.id)
          : const <String>[]);
    lassoPath.clear();
    if (selectedStrokeIds.isNotEmpty ||
        selectedShapeIds.isNotEmpty ||
        selectedTextIds.isNotEmpty ||
        selectedImageIds.isNotEmpty) {
      HapticFeedback.selectionClick();
    }
    _bumpCanvas();
    setState(() {});
  }

  List<StrokePoint> _lassoSelectionPolygon() {
    if (lassoMode == LassoMode.freeform) return List.of(lassoPath);
    final left = lassoPath.map((point) => point.x).reduce(math.min);
    final right = lassoPath.map((point) => point.x).reduce(math.max);
    final top = lassoPath.map((point) => point.y).reduce(math.min);
    final bottom = lassoPath.map((point) => point.y).reduce(math.max);
    return [
      StrokePoint(left, top, 1),
      StrokePoint(right, top, 1),
      StrokePoint(right, bottom, 1),
      StrokePoint(left, bottom, 1),
    ];
  }

  void _deleteSelection() {
    if (selectedStrokeIds.isEmpty &&
        selectedShapeIds.isEmpty &&
        selectedTextIds.isEmpty &&
        selectedImageIds.isEmpty) {
      return;
    }
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
        selectedImageIds.isEmpty) {
      return;
    }
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
    final copiedTexts =
        texts.where((text) => selectedTextIds.contains(text.id)).map((text) {
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
        bold: text.bold,
        alignment: text.alignment,
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
        rotationRadians: image.rotationRadians,
        cropLeft: image.cropLeft,
        cropTop: image.cropTop,
        cropRight: image.cropRight,
        cropBottom: image.cropBottom,
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
    _bumpCanvas(staticLayer: true);
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

  Future<void> _showSelectedTextColor() async {
    if (selectedTextIds.isEmpty) return;
    final current =
        texts.firstWhere((text) => selectedTextIds.contains(text.id)).color;
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
              child: Text('텍스트 색상',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              children: [
                for (final swatch in const [
                  (color: Colors.black, label: '검정'),
                  (color: Color(0xff3f6f9f), label: '파랑'),
                  (color: Color(0xffc95656), label: '빨강'),
                  (color: Color(0xff4e8b68), label: '초록'),
                  (color: Color(0xffd58b3a), label: '주황'),
                ])
                  _PaletteColorButton(
                    color: swatch.color,
                    label: swatch.label,
                    selected: swatch.color == current,
                    onTap: () => Navigator.pop(sheetContext, swatch.color),
                  ),
              ],
            ),
          ]),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    _recordHistory();
    for (var index = 0; index < texts.length; index++) {
      if (selectedTextIds.contains(texts[index].id)) {
        texts[index] = texts[index].copyWith(color: selected);
      }
    }
    _scheduleSave();
    _bumpCanvas(staticLayer: true);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_perfEnabled) _editorBuilds++;
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
                    _bumpCanvas(staticLayer: true);
                    setState(() {});
                    break;
                  case 'toolbar':
                    setState(() => toolbarVisible = !toolbarVisible);
                    break;
                  case 'rotate':
                    _rotatePage();
                    break;
                  case 'benchmark100':
                    _loadDebugBenchmark(100);
                    break;
                  case 'benchmark500':
                    _loadDebugBenchmark(500);
                    break;
                  case 'benchmark1000':
                    _loadDebugBenchmark(1000);
                    break;
                  case 'benchmarkReplay':
                    _runDebugReplayBenchmark();
                    break;
                  case 'toggleIncremental':
                    if (_perfEnabled) {
                      setState(() => _useIncrementalActivePath =
                          !_useIncrementalActivePath);
                    }
                    break;
                  case 'frameDiagnosis':
                    _runFrameDiagnosisBenchmark();
                    break;
                  case 'longStrokeBenchmark':
                    _runLongStrokeBenchmark();
                    break;
                  case 'pressureStrokeBenchmark':
                    _runLongStrokeBenchmark(pressureReplay: true);
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
                    value: 'rotate',
                    child:
                        Text(pageRotation == 0 ? '페이지 시계 방향 회전' : '페이지 회전 계속')),
                PopupMenuItem(
                    value: 'delete',
                    enabled: pageCount > 1,
                    child: const Text('페이지 삭제')),
                PopupMenuItem(
                    value: 'toolbar',
                    child: Text(toolbarVisible ? '도구 숨기기' : '도구 보이기')),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'clear', child: Text('현재 페이지 지우기')),
                if (kDebugMode || kProfileMode) ...[
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                      value: 'benchmark100', child: Text('DEBUG: 100 strokes')),
                  const PopupMenuItem(
                      value: 'benchmark500', child: Text('DEBUG: 500 strokes')),
                  const PopupMenuItem(
                      value: 'benchmark1000',
                      child: Text('DEBUG: 1000 strokes')),
                  const PopupMenuItem(
                      value: 'benchmarkReplay',
                      child: Text('DEBUG: replay baseline (5x)')),
                  PopupMenuItem(
                      value: 'toggleIncremental',
                      child: Text(_useIncrementalActivePath
                          ? 'DEBUG: legacy full path'
                          : 'DEBUG: incremental path')),
                  const PopupMenuItem(
                      value: 'frameDiagnosis',
                      child: Text('DEBUG/Profile: frame diagnosis')),
                  const PopupMenuItem(
                      value: 'longStrokeBenchmark',
                      child: Text('DEBUG: long stroke benchmark')),
                  const PopupMenuItem(
                      value: 'pressureStrokeBenchmark',
                      child: Text('DEBUG: pressure stroke benchmark')),
                ],
              ],
            ),
          ]),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                    top: toolbarVisible ? 50 : 0,
                    child: _ZoomableNotebookViewport(
                        onViewportGestureStart:
                            _cancelCanvasInputForViewportGesture,
                        child: Align(
                            alignment: Alignment.topCenter,
                            child: RotatedBox(
                                quarterTurns: pageRotation,
                                child: AspectRatio(
                                    aspectRatio:
                                        pageRotation.isEven ? .7 : 1 / .7,
                                    child: DecoratedBox(
                                      decoration: const BoxDecoration(
                                          color: Colors.white,
                                          boxShadow: [
                                            BoxShadow(
                                                blurRadius: 3,
                                                color: Colors.black12)
                                          ]),
                                      child: LayoutBuilder(
                                          builder: (context, constraints) =>
                                              Stack(children: [
                                                AnimatedSwitcher(
                                                  duration: const Duration(
                                                      milliseconds: 220),
                                                  switchInCurve:
                                                      Curves.easeOutCubic,
                                                  switchOutCurve:
                                                      Curves.easeInCubic,
                                                  transitionBuilder:
                                                      (child, animation) =>
                                                          FadeTransition(
                                                    opacity: animation,
                                                    child: SlideTransition(
                                                      position: Tween<Offset>(
                                                        begin: const Offset(
                                                            .018, 0),
                                                        end: Offset.zero,
                                                      ).animate(animation),
                                                      child: child,
                                                    ),
                                                  ),
                                                  child: DrawingCanvas(
                                                      key: ValueKey(pageIndex),
                                                      strokes: strokes,
                                                      texts: texts,
                                                      images: images,
                                                      imageCache: imageCache,
                                                      hiddenTextId:
                                                          editingText?.id,
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
                                                      selectedTextIds:
                                                          selectedTextIds,
                                                      selectedImageIds:
                                                          selectedImageIds,
                                                      onSelectionStart:
                                                          _selectionStart,
                                                      onSelectionMove:
                                                          _selectionMove,
                                                      onSelectionEnd:
                                                          _selectionEnd,
                                                      onTextTap: _textTap,
                                                      onImageTap: _imageTap,
                                                      repaint: canvasRevision,
                                                      staticRepaint:
                                                          staticRevisionNotifier,
                                                      revision:
                                                          canvasRevision.value,
                                                      staticRevision:
                                                          staticRevision,
                                                      useIncrementalActivePath:
                                                          _useIncrementalActivePath,
                                                      instrumentationEnabled:
                                                          _instrumentationEnabled,
                                                      onPaint: () {
                                                        if (_perfEnabled) {
                                                          _painterRepaints++;
                                                          _activePainterRepaints++;
                                                        }
                                                      },
                                                      onStaticPaint: () {
                                                        if (_perfEnabled) {
                                                          _staticPainterRepaints++;
                                                        }
                                                      },
                                                      onStaticObjectPaint: () {
                                                        if (_perfEnabled) {
                                                          _staticObjectPaintCount++;
                                                        }
                                                      },
                                                      onPathBuild: (elapsed) {
                                                        if (_perfEnabled &&
                                                            _instrumentationEnabled) {
                                                          _pathBuildCount++;
                                                          final us = elapsed
                                                              .inMicroseconds;
                                                          _pathBuildTotalUs +=
                                                              us;
                                                          _pathBuildMaxUs =
                                                              math.max(
                                                                  _pathBuildMaxUs,
                                                                  us);
                                                        }
                                                      },
                                                      onIncrementalPathBuild:
                                                          (elapsed) {
                                                        if (_perfEnabled &&
                                                            _instrumentationEnabled) {
                                                          _incrementalSegmentBuildCount++;
                                                          final us = elapsed
                                                              .inMicroseconds;
                                                          _incrementalBuildTotalUs +=
                                                              us;
                                                          _incrementalBuildMaxUs =
                                                              math.max(
                                                                  _incrementalBuildMaxUs,
                                                                  us);
                                                        }
                                                      },
                                                      onFullPathRebuild: () {
                                                        if (_perfEnabled &&
                                                            _instrumentationEnabled) {
                                                          _fullPathRebuildCount++;
                                                        }
                                                      },
                                                      onActivePaint: (elapsed) {
                                                        if (_perfEnabled) {
                                                          final us = elapsed
                                                              .inMicroseconds;
                                                          _activePaintTotalUs +=
                                                              us;
                                                          _activePaintMaxUs =
                                                              math.max(
                                                                  _activePaintMaxUs,
                                                                  us);
                                                          _activePaintSamples++;
                                                        }
                                                      },
                                                      onPictureDraw: (elapsed) {
                                                        if (_perfEnabled &&
                                                            _instrumentationEnabled) {
                                                          final us = elapsed
                                                              .inMicroseconds;
                                                          _pictureDrawSamples++;
                                                          _pictureDrawTotalUs +=
                                                              us;
                                                          _pictureDrawMaxUs =
                                                              math.max(
                                                                  _pictureDrawMaxUs,
                                                                  us);
                                                        }
                                                      },
                                                      onActivePathDraw:
                                                          (elapsed) {
                                                        if (_perfEnabled &&
                                                            _instrumentationEnabled) {
                                                          final us = elapsed
                                                              .inMicroseconds;
                                                          _activePathDrawSamples++;
                                                          _activePathDrawTotalUs +=
                                                              us;
                                                          _activePathDrawMaxUs =
                                                              math.max(
                                                                  _activePathDrawMaxUs,
                                                                  us);
                                                        }
                                                      },
                                                      onOverlayPaint:
                                                          (elapsed) {
                                                        if (_perfEnabled) {
                                                          final us = elapsed
                                                              .inMicroseconds;
                                                          _overlayPaintTotalUs +=
                                                              us;
                                                          _overlayPaintMaxUs =
                                                              math.max(
                                                                  _overlayPaintMaxUs,
                                                                  us);
                                                          _overlayPaintSamples++;
                                                        }
                                                      }),
                                                ),
                                                if (editingText
                                                    case final text?)
                                                  Positioned(
                                                    left: text.position.x *
                                                        constraints.maxWidth,
                                                    top: text.position.y *
                                                        constraints.maxHeight,
                                                    width: text.maxWidth *
                                                        constraints.maxWidth,
                                                    child: TextField(
                                                      controller:
                                                          textController,
                                                      focusNode: textFocus,
                                                      minLines: 1,
                                                      maxLines: null,
                                                      style: TextStyle(
                                                          color: text.color,
                                                          fontSize:
                                                              text.fontSize,
                                                          fontWeight: text.bold
                                                              ? FontWeight.w700
                                                              : FontWeight.w400,
                                                          height: 1.25),
                                                      textAlign:
                                                          _textAlignValue(
                                                              text.alignment),
                                                      decoration:
                                                          const InputDecoration(
                                                              isDense: true,
                                                              border:
                                                                  InputBorder
                                                                      .none),
                                                    ),
                                                  ),
                                                if (tool == StrokeTool.lasso &&
                                                    editingText == null)
                                                  if (_selectedBounds()
                                                      case final bounds?)
                                                    _SelectionContextMenuOverlay(
                                                      bounds: bounds,
                                                      canvasSize: constraints,
                                                      hasShapeSelection:
                                                          selectedShapeIds
                                                              .isNotEmpty,
                                                      hasTextSelection:
                                                          selectedTextIds
                                                              .isNotEmpty,
                                                      hasSingleImageSelection:
                                                          selectedImageIds
                                                                  .length ==
                                                              1,
                                                      onDuplicate:
                                                          _duplicateSelection,
                                                      onShapeStyle:
                                                          _showSelectedShapeStyle,
                                                      onTextColor:
                                                          _showSelectedTextColor,
                                                      onCrop:
                                                          _cropSelectedImage,
                                                      onDelete:
                                                          _deleteSelection,
                                                    ),
                                              ])),
                                    )))))),
                if (toolbarVisible)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _toolbar(context),
                  ),
              ],
            ),
    );
  }

  Widget _toolbar(BuildContext context) => DrawingToolbar(
        selectedTool: tool,
        width: activeWidth,
        color: activeColor,
        highlighterOpacity: highlighterOpacity,
        eraserMode: eraserMode,
        onToolChanged: _setTool,
        onWidthChanged: _setWidth,
        onColorChanged: (value) => _setColorForTool(tool, value),
        onHighlighterOpacityChanged: (value) =>
            setState(() => highlighterOpacity = value),
        onEraserModeChanged: (value) => setState(() => eraserMode = value),
        lassoMode: lassoMode,
        lassoIncludeStrokes: lassoIncludeStrokes,
        lassoIncludeTexts: lassoIncludeTexts,
        lassoIncludeImages: lassoIncludeImages,
        onLassoModeChanged: (value) => setState(() => lassoMode = value),
        onLassoIncludeStrokesChanged: (value) =>
            setState(() => lassoIncludeStrokes = value),
        onLassoIncludeTextsChanged: (value) =>
            setState(() => lassoIncludeTexts = value),
        onLassoIncludeImagesChanged: (value) =>
            setState(() => lassoIncludeImages = value),
        onPaletteRequested: _showColorPalette,
        shapeType: shapeType,
        onShapeTypeChanged: _setShapeType,
        hasSelection: selectedStrokeIds.isNotEmpty ||
            selectedShapeIds.isNotEmpty ||
            selectedTextIds.isNotEmpty ||
            selectedImageIds.isNotEmpty,
        hasShapeSelection: selectedShapeIds.isNotEmpty,
        hasSingleImageSelection: selectedImageIds.length == 1,
        onDeleteSelection: _deleteSelection,
        onDuplicateSelection: _duplicateSelection,
        onShapeStyleRequested: _showSelectedShapeStyle,
        onCropRequested: _cropSelectedImage,
        textBold: textBold,
        textAlignment: textAlignment,
        onTextBoldChanged: (value) => setState(() => textBold = value),
        onTextAlignmentChanged: (value) =>
            setState(() => textAlignment = value),
      );
}

class _SelectionContextMenuOverlay extends StatelessWidget {
  const _SelectionContextMenuOverlay({
    required this.bounds,
    required this.canvasSize,
    required this.hasShapeSelection,
    required this.hasTextSelection,
    required this.hasSingleImageSelection,
    required this.onDuplicate,
    required this.onShapeStyle,
    required this.onTextColor,
    required this.onCrop,
    required this.onDelete,
  });

  final Rect bounds;
  final BoxConstraints canvasSize;
  final bool hasShapeSelection;
  final bool hasTextSelection;
  final bool hasSingleImageSelection;
  final VoidCallback onDuplicate;
  final VoidCallback onShapeStyle;
  final VoidCallback onTextColor;
  final VoidCallback onCrop;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const menuWidth = 208.0;
    final left = (bounds.center.dx * canvasSize.maxWidth - menuWidth / 2)
        .clamp(8.0, math.max(8.0, canvasSize.maxWidth - menuWidth))
        .toDouble();
    final above = bounds.top * canvasSize.maxHeight - 48;
    final top = above >= 6
        ? above
        : (bounds.bottom * canvasSize.maxHeight + 8)
            .clamp(6.0, math.max(6.0, canvasSize.maxHeight - 44))
            .toDouble();
    return Positioned(
      left: left,
      top: top,
      width: menuWidth,
      height: 40,
      child: Material(
        color: scheme.surface,
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _SelectionMenuButton(
              icon: Icons.content_copy_outlined,
              label: '복제',
              onPressed: onDuplicate,
            ),
            if (hasShapeSelection)
              _SelectionMenuButton(
                icon: Icons.palette_outlined,
                label: '스타일',
                onPressed: onShapeStyle,
              ),
            if (hasTextSelection)
              _SelectionMenuButton(
                icon: Icons.palette_outlined,
                label: '색상',
                onPressed: onTextColor,
              ),
            if (hasSingleImageSelection)
              _SelectionMenuButton(
                icon: Icons.crop_outlined,
                label: '자르기',
                onPressed: onCrop,
              ),
            _SelectionMenuButton(
              icon: Icons.delete_outline_rounded,
              label: '삭제',
              color: scheme.error,
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectionMenuButton extends StatelessWidget {
  const _SelectionMenuButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: Tooltip(
          message: label,
          child: IconButton(
            onPressed: onPressed,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: Icon(icon, size: 19, color: color),
          ),
        ),
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
    required this.onDeletePages,
    required this.onMovePage,
    required this.onMovePageTo,
  });

  final String documentId;
  final int pageCount;
  final int selectedPage;
  final String templateId;
  final ValueChanged<int> onPageSelected;
  final VoidCallback onAddPage;
  final ValueChanged<int> onDuplicatePage;
  final ValueChanged<int> onDeletePage;
  final ValueChanged<Set<int>> onDeletePages;
  final void Function(int page, int direction) onMovePage;
  final void Function(int source, int target) onMovePageTo;

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
              IconButton(
                onPressed: () => _showMultiDelete(context),
                tooltip: '여러 페이지 삭제',
                icon: const Icon(Icons.checklist_outlined),
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
                  return DragTarget<int>(
                    onWillAcceptWithDetails: (details) => details.data != page,
                    onAcceptWithDetails: (details) =>
                        onMovePageTo(details.data, page),
                    builder: (context, candidates, rejected) {
                      final hovering = candidates.isNotEmpty;
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
                              child: AnimatedScale(
                                scale: hovering ? 1.035 : 1,
                                duration: const Duration(milliseconds: 140),
                                curve: Curves.easeOutCubic,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  decoration: BoxDecoration(
                                    color: hovering
                                        ? scheme.primaryContainer
                                            .withValues(alpha: .35)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(5),
                                    border: Border.all(
                                      color: hovering || selected
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
                                    child: Stack(children: [
                                      Positioned.fill(
                                        child: _PageThumbnail(
                                          documentId: documentId,
                                          pageId: 'page_$page',
                                          templateId: templateId,
                                        ),
                                      ),
                                      Positioned(
                                        right: 3,
                                        top: 3,
                                        child: LongPressDraggable<int>(
                                          data: page,
                                          feedback: Material(
                                            color: scheme.surface,
                                            elevation: 4,
                                            borderRadius:
                                                BorderRadius.circular(6),
                                            child: SizedBox(
                                              width: 72,
                                              height: 96,
                                              child: Center(
                                                  child: Text('$page페이지')),
                                            ),
                                          ),
                                          child: Icon(Icons.drag_indicator,
                                              size: 14,
                                              color: scheme.onSurfaceVariant
                                                  .withValues(alpha: .5)),
                                        ),
                                      ),
                                    ]),
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
              _PageActionButton(
                enabled: page > 1,
                icon: Icons.arrow_upward,
                label: '앞 페이지로 이동',
                onTap: page <= 1
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        onMovePage(page, -1);
                      },
              ),
              _PageActionButton(
                enabled: page < pageCount,
                icon: Icons.arrow_downward,
                label: '뒤 페이지로 이동',
                onTap: page >= pageCount
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        onMovePage(page, 1);
                      },
              ),
              _PageActionButton(
                icon: Icons.copy_outlined,
                label: '페이지 복제',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onDuplicatePage(page);
                },
              ),
              _PageActionButton(
                enabled: pageCount > 1,
                icon: Icons.delete_outline,
                label: '페이지 삭제',
                destructive: true,
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

  Future<void> _showMultiDelete(BuildContext context) async {
    final selected = <int>{};
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('페이지 여러 장 관리'),
          content: SizedBox(
            width: 320,
            height: 300,
            child: ListView.builder(
              itemCount: pageCount,
              itemBuilder: (_, index) {
                final page = index + 1;
                return CheckboxListTile(
                  dense: true,
                  title: Text('$page페이지'),
                  value: selected.contains(page),
                  onChanged: pageCount - selected.length <= 1 &&
                          !selected.contains(page)
                      ? null
                      : (value) => setState(() {
                            if (value == true) {
                              selected.add(page);
                            } else {
                              selected.remove(page);
                            }
                          }),
                );
              },
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('취소')),
            FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.pop(dialogContext, true),
                child: const Text('선택 페이지 삭제')),
          ],
        ),
      ),
    );
    if (result == true && selected.isNotEmpty) onDeletePages(selected);
  }
}

class _PageActionButton extends StatelessWidget {
  const _PageActionButton(
      {required this.icon,
      required this.label,
      required this.onTap,
      this.enabled = true,
      this.destructive = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool enabled;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = !enabled
        ? scheme.onSurface.withValues(alpha: .38)
        : destructive
            ? scheme.error
            : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: color.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(icon, size: 18, color: color)),
            ),
            const SizedBox(width: 12),
            Text(label,
                style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
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

class DrawingToolbar extends StatefulWidget {
  const DrawingToolbar({
    required this.selectedTool,
    required this.width,
    required this.color,
    required this.highlighterOpacity,
    required this.eraserMode,
    required this.lassoMode,
    required this.lassoIncludeStrokes,
    required this.lassoIncludeTexts,
    required this.lassoIncludeImages,
    required this.onToolChanged,
    required this.onWidthChanged,
    required this.onColorChanged,
    required this.onHighlighterOpacityChanged,
    required this.onEraserModeChanged,
    required this.onLassoModeChanged,
    required this.onLassoIncludeStrokesChanged,
    required this.onLassoIncludeTextsChanged,
    required this.onLassoIncludeImagesChanged,
    required this.onPaletteRequested,
    required this.shapeType,
    required this.onShapeTypeChanged,
    required this.hasSelection,
    required this.hasShapeSelection,
    required this.hasSingleImageSelection,
    required this.onDeleteSelection,
    required this.onDuplicateSelection,
    required this.onShapeStyleRequested,
    required this.onCropRequested,
    required this.textBold,
    required this.textAlignment,
    required this.onTextBoldChanged,
    required this.onTextAlignmentChanged,
    super.key,
  });
  final StrokeTool selectedTool;
  final double width;
  final Color color;
  final double highlighterOpacity;
  final EraserMode eraserMode;
  final LassoMode lassoMode;
  final bool lassoIncludeStrokes;
  final bool lassoIncludeTexts;
  final bool lassoIncludeImages;
  final ValueChanged<StrokeTool> onToolChanged;
  final ValueChanged<double> onWidthChanged;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onHighlighterOpacityChanged;
  final ValueChanged<EraserMode> onEraserModeChanged;
  final ValueChanged<LassoMode> onLassoModeChanged;
  final ValueChanged<bool> onLassoIncludeStrokesChanged;
  final ValueChanged<bool> onLassoIncludeTextsChanged;
  final ValueChanged<bool> onLassoIncludeImagesChanged;
  final VoidCallback onPaletteRequested;
  final DrawingShapeType shapeType;
  final ValueChanged<DrawingShapeType> onShapeTypeChanged;
  final bool hasSelection;
  final bool hasShapeSelection;
  final bool hasSingleImageSelection;
  final VoidCallback onDeleteSelection;
  final VoidCallback onDuplicateSelection;
  final VoidCallback onShapeStyleRequested;
  final VoidCallback onCropRequested;
  final bool textBold;
  final String textAlignment;
  final ValueChanged<bool> onTextBoldChanged;
  final ValueChanged<String> onTextAlignmentChanged;

  @override
  State<DrawingToolbar> createState() => _DrawingToolbarState();
}

class _DrawingToolbarState extends State<DrawingToolbar> {
  void _selectTool(StrokeTool tool) {
    widget.onToolChanged(tool);
  }

  Future<void> _showInsertMenu(BuildContext context) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          MediaQuery.sizeOf(context).width - 150, 92, 12, 0),
      color: Theme.of(context).colorScheme.surface,
      elevation: 3,
      popUpAnimationStyle: _toolbarPopupAnimation,
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      items: const [
        PopupMenuItem(
          value: 'text',
          height: 44,
          child: Row(children: [
            Icon(Icons.text_fields_rounded, size: 19),
            SizedBox(width: 10),
            Text('텍스트'),
          ]),
        ),
        PopupMenuItem(
          value: 'image',
          height: 44,
          child: Row(children: [
            Icon(Icons.image_outlined, size: 19),
            SizedBox(width: 10),
            Text('이미지'),
          ]),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    _selectTool(choice == 'text' ? StrokeTool.text : StrokeTool.image);
  }

  @override
  Widget build(BuildContext context) {
    return _IntegratedEditorToolbar(
      toolbar: widget,
      onToolChanged: _selectTool,
      onInsertTap: () => _showInsertMenu(context),
    ); /*
    final selectedTool = widget.selectedTool;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          PrimaryToolBar(
            selectedTool: selectedTool,
            onChanged: _selectTool,
            onWritingTap: _selectWriting,
            onInsertTap: () => _showInsertMenu(context),
          ),
          if (_activeMenuVisible)
            Positioned(
              top: 54,
              left: 0,
              right: 0,
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: .82,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 390),
                    child: Material(
                      color: scheme.primaryContainer.withValues(alpha: .16),
                      elevation: 2,
                      shadowColor: scheme.primary.withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(14),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          child: _isWriting(selectedTool)
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _WritingToolSwitcher(
                                      selectedTool: selectedTool,
                                      onSelected: (tool) {
                                        widget.onToolChanged(tool);
                                        setState(
                                            () => _activeMenuVisible = true);
                                      },
                                    ),
                                    ToolOptionsBar(
                                      key: ValueKey(selectedTool),
                                      selectedTool: selectedTool,
                                      width: widget.width,
                                      color: widget.color,
                                      highlighterOpacity:
                                          widget.highlighterOpacity,
                                      eraserMode: widget.eraserMode,
                                      lassoMode: widget.lassoMode,
                                      lassoIncludeStrokes:
                                          widget.lassoIncludeStrokes,
                                      lassoIncludeTexts:
                                          widget.lassoIncludeTexts,
                                      lassoIncludeImages:
                                          widget.lassoIncludeImages,
                                      onWidthChanged: widget.onWidthChanged,
                                      onColorChanged: widget.onColorChanged,
                                      onHighlighterOpacityChanged:
                                          widget.onHighlighterOpacityChanged,
                                      onEraserModeChanged:
                                          widget.onEraserModeChanged,
                                      onLassoModeChanged:
                                          widget.onLassoModeChanged,
                                      onLassoIncludeStrokesChanged:
                                          widget.onLassoIncludeStrokesChanged,
                                      onLassoIncludeTextsChanged:
                                          widget.onLassoIncludeTextsChanged,
                                      onLassoIncludeImagesChanged:
                                          widget.onLassoIncludeImagesChanged,
                                      onPaletteRequested:
                                          widget.onPaletteRequested,
                                      shapeType: widget.shapeType,
                                      onShapeTypeChanged:
                                          widget.onShapeTypeChanged,
                                      hasSelection: widget.hasSelection,
                                      hasShapeSelection:
                                          widget.hasShapeSelection,
                                      hasSingleImageSelection:
                                          widget.hasSingleImageSelection,
                                      onDeleteSelection:
                                          widget.onDeleteSelection,
                                      onDuplicateSelection:
                                          widget.onDuplicateSelection,
                                      onShapeStyleRequested:
                                          widget.onShapeStyleRequested,
                                      onCropRequested: widget.onCropRequested,
                                    ),
                                  ],
                                )
                              : ToolOptionsBar(
                                  key: ValueKey(selectedTool),
                                  selectedTool: selectedTool,
                                  width: widget.width,
                                  color: widget.color,
                                  highlighterOpacity: widget.highlighterOpacity,
                                  eraserMode: widget.eraserMode,
                                  lassoMode: widget.lassoMode,
                                  lassoIncludeStrokes:
                                      widget.lassoIncludeStrokes,
                                  lassoIncludeTexts: widget.lassoIncludeTexts,
                                  lassoIncludeImages: widget.lassoIncludeImages,
                                  onWidthChanged: widget.onWidthChanged,
                                  onColorChanged: widget.onColorChanged,
                                  onHighlighterOpacityChanged:
                                      widget.onHighlighterOpacityChanged,
                                  onEraserModeChanged:
                                      widget.onEraserModeChanged,
                                  onLassoModeChanged: widget.onLassoModeChanged,
                                  onLassoIncludeStrokesChanged:
                                      widget.onLassoIncludeStrokesChanged,
                                  onLassoIncludeTextsChanged:
                                      widget.onLassoIncludeTextsChanged,
                                  onLassoIncludeImagesChanged:
                                      widget.onLassoIncludeImagesChanged,
                                  onPaletteRequested: widget.onPaletteRequested,
                                  shapeType: widget.shapeType,
                                  onShapeTypeChanged: widget.onShapeTypeChanged,
                                  hasSelection: widget.hasSelection,
                                  hasShapeSelection: widget.hasShapeSelection,
                                  hasSingleImageSelection:
                                      widget.hasSingleImageSelection,
                                  onDeleteSelection: widget.onDeleteSelection,
                                  onDuplicateSelection:
                                      widget.onDuplicateSelection,
                                  onShapeStyleRequested:
                                      widget.onShapeStyleRequested,
                                  onCropRequested: widget.onCropRequested,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
    */
  }
}

class _IntegratedEditorToolbar extends StatelessWidget {
  const _IntegratedEditorToolbar({
    required this.toolbar,
    required this.onToolChanged,
    required this.onInsertTap,
  });
  final DrawingToolbar toolbar;
  final ValueChanged<StrokeTool> onToolChanged;
  final VoidCallback onInsertTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = toolbar.selectedTool;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Material(
            color: scheme.surface,
            elevation: 2,
            shadowColor: Colors.black.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                height: 42,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(children: [
                    _EditorToolButton(Icons.select_all_rounded,
                        StrokeTool.lasso, selected, onToolChanged, '올가미'),
                    _EditorToolButton(Icons.draw_rounded, StrokeTool.pen,
                        selected, onToolChanged, '펜'),
                    _EditorToolButton(Icons.backspace_outlined,
                        StrokeTool.eraser, selected, onToolChanged, '지우개'),
                    _EditorToolButton(Icons.highlight_rounded,
                        StrokeTool.highlighter, selected, onToolChanged, '형광펜'),
                    _EditorToolButton(Icons.polyline_rounded,
                        StrokeTool.shapeLine, selected, onToolChanged, '도형'),
                    _EditorToolButton(Icons.text_fields_rounded,
                        StrokeTool.text, selected, onToolChanged, '텍스트'),
                    _EditorToolButton(Icons.image_rounded, StrokeTool.image,
                        selected, onToolChanged, '이미지'),
                    IconButton(
                      tooltip: '삽입 도구',
                      onPressed: onInsertTap,
                      icon: const Icon(Icons.add_rounded),
                    ),
                    const SizedBox(width: 12),
                  ]),
                ),
              ),
              Divider(
                  height: 1,
                  thickness: 1,
                  color: scheme.outlineVariant.withValues(alpha: .35)),
              ToolOptionsBar(
                selectedTool: selected,
                width: toolbar.width,
                color: toolbar.color,
                highlighterOpacity: toolbar.highlighterOpacity,
                eraserMode: toolbar.eraserMode,
                lassoMode: toolbar.lassoMode,
                lassoIncludeStrokes: toolbar.lassoIncludeStrokes,
                lassoIncludeTexts: toolbar.lassoIncludeTexts,
                lassoIncludeImages: toolbar.lassoIncludeImages,
                onWidthChanged: toolbar.onWidthChanged,
                onColorChanged: toolbar.onColorChanged,
                onHighlighterOpacityChanged:
                    toolbar.onHighlighterOpacityChanged,
                onEraserModeChanged: toolbar.onEraserModeChanged,
                onLassoModeChanged: toolbar.onLassoModeChanged,
                onLassoIncludeStrokesChanged:
                    toolbar.onLassoIncludeStrokesChanged,
                onLassoIncludeTextsChanged: toolbar.onLassoIncludeTextsChanged,
                onLassoIncludeImagesChanged:
                    toolbar.onLassoIncludeImagesChanged,
                onPaletteRequested: toolbar.onPaletteRequested,
                shapeType: toolbar.shapeType,
                onShapeTypeChanged: toolbar.onShapeTypeChanged,
                hasSelection: toolbar.hasSelection,
                hasShapeSelection: toolbar.hasShapeSelection,
                hasSingleImageSelection: toolbar.hasSingleImageSelection,
                onDeleteSelection: toolbar.onDeleteSelection,
                onDuplicateSelection: toolbar.onDuplicateSelection,
                onShapeStyleRequested: toolbar.onShapeStyleRequested,
                onCropRequested: toolbar.onCropRequested,
                textBold: toolbar.textBold,
                textAlignment: toolbar.textAlignment,
                onTextBoldChanged: toolbar.onTextBoldChanged,
                onTextAlignmentChanged: toolbar.onTextAlignmentChanged,
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _EditorToolButton extends StatelessWidget {
  const _EditorToolButton(
      this.icon, this.tool, this.selectedTool, this.onTap, this.label);
  final IconData icon;
  final StrokeTool tool;
  final StrokeTool selectedTool;
  final ValueChanged<StrokeTool> onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = tool == selectedTool ||
        (_isShapeToolValue(tool) && _isShapeToolValue(selectedTool));
    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: () => onTap(tool),
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 40,
            height: 36,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: isSelected
                  ? scheme.primaryContainer.withValues(alpha: .82)
                  : null,
              border: isSelected
                  ? Border.all(
                      color: scheme.primary.withValues(alpha: .12), width: 1)
                  : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon,
                    size: 21,
                    color:
                        isSelected ? scheme.primary : scheme.onSurfaceVariant),
                if (isSelected)
                  Positioned(
                    bottom: 2,
                    child: Container(
                      width: 12,
                      height: 2,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PrimaryToolBar extends StatelessWidget {
  const PrimaryToolBar({
    required this.selectedTool,
    required this.onChanged,
    required this.onWritingTap,
    required this.onInsertTap,
    super.key,
  });
  final StrokeTool selectedTool;
  final ValueChanged<StrokeTool> onChanged;
  final VoidCallback onWritingTap;
  final VoidCallback onInsertTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
        height: 58,
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Material(
              color: scheme.surface,
              elevation: 2,
              shadowColor: Colors.black.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  child: Row(children: [
                    _CategoryToolButton(
                        icon: Icons.gesture_rounded,
                        label: '선택',
                        selected: selectedTool == StrokeTool.lasso,
                        onTap: () => onChanged(StrokeTool.lasso)),
                    _CategoryToolButton(
                        icon: Icons.edit_rounded,
                        label: '필기',
                        selected: selectedTool == StrokeTool.pen ||
                            selectedTool == StrokeTool.highlighter,
                        onTap: onWritingTap),
                    _CategoryToolButton(
                        icon: Icons.cleaning_services_outlined,
                        label: '지우개',
                        selected: selectedTool == StrokeTool.eraser,
                        onTap: () => onChanged(StrokeTool.eraser)),
                    _CategoryToolButton(
                        icon: Icons.category_outlined,
                        label: '도형',
                        selected: _isShapeToolValue(selectedTool),
                        onTap: () => onChanged(StrokeTool.shapeLine)),
                    _CategoryToolButton(
                        icon: Icons.add_rounded,
                        label: '삽입',
                        selected: selectedTool == StrokeTool.text ||
                            selectedTool == StrokeTool.image,
                        onTap: onInsertTap),
                  ]),
                ),
              ),
            )));
  }
}

class _CategoryToolButton extends StatelessWidget {
  const _CategoryToolButton(
      {required this.icon,
      required this.label,
      required this.selected,
      required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 58,
          height: 46,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer.withValues(alpha: .72)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon,
              size: 22,
              color: selected ? scheme.primary : scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class ToolOptionsBar extends StatelessWidget {
  const ToolOptionsBar(
      {required this.selectedTool,
      required this.width,
      required this.color,
      required this.highlighterOpacity,
      required this.eraserMode,
      required this.lassoMode,
      required this.lassoIncludeStrokes,
      required this.lassoIncludeTexts,
      required this.lassoIncludeImages,
      required this.onWidthChanged,
      required this.onColorChanged,
      required this.onHighlighterOpacityChanged,
      required this.onEraserModeChanged,
      required this.onLassoModeChanged,
      required this.onLassoIncludeStrokesChanged,
      required this.onLassoIncludeTextsChanged,
      required this.onLassoIncludeImagesChanged,
      required this.onPaletteRequested,
      required this.shapeType,
      required this.onShapeTypeChanged,
      required this.hasSelection,
      required this.hasShapeSelection,
      required this.hasSingleImageSelection,
      required this.onDeleteSelection,
      required this.onDuplicateSelection,
      required this.onShapeStyleRequested,
      required this.onCropRequested,
      this.textBold = false,
      this.textAlignment = 'left',
      this.onTextBoldChanged,
      this.onTextAlignmentChanged,
      super.key});
  final StrokeTool selectedTool;
  final double width;
  final Color color;
  final double highlighterOpacity;
  final EraserMode eraserMode;
  final LassoMode lassoMode;
  final bool lassoIncludeStrokes;
  final bool lassoIncludeTexts;
  final bool lassoIncludeImages;
  final ValueChanged<double> onWidthChanged;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onHighlighterOpacityChanged;
  final ValueChanged<EraserMode> onEraserModeChanged;
  final ValueChanged<LassoMode> onLassoModeChanged;
  final ValueChanged<bool> onLassoIncludeStrokesChanged;
  final ValueChanged<bool> onLassoIncludeTextsChanged;
  final ValueChanged<bool> onLassoIncludeImagesChanged;
  final VoidCallback onPaletteRequested;
  final DrawingShapeType shapeType;
  final ValueChanged<DrawingShapeType> onShapeTypeChanged;
  final bool hasSelection;
  final bool hasShapeSelection;
  final bool hasSingleImageSelection;
  final VoidCallback onDeleteSelection;
  final VoidCallback onDuplicateSelection;
  final VoidCallback onShapeStyleRequested;
  final VoidCallback onCropRequested;
  final bool textBold;
  final String textAlignment;
  final ValueChanged<bool>? onTextBoldChanged;
  final ValueChanged<String>? onTextAlignmentChanged;
  @override
  Widget build(BuildContext context) {
    if (selectedTool == StrokeTool.pen) {
      return PenOptionsBar(
          width: width,
          color: color,
          onWidthChanged: onWidthChanged,
          onColorChanged: onColorChanged,
          onPaletteRequested: onPaletteRequested);
    }
    if (selectedTool == StrokeTool.highlighter) {
      return HighlighterOptionsBar(
          width: width,
          color: color,
          opacity: highlighterOpacity,
          onWidthChanged: onWidthChanged,
          onColorChanged: onColorChanged,
          onOpacityChanged: onHighlighterOpacityChanged,
          onPaletteRequested: onPaletteRequested);
    }
    if (selectedTool == StrokeTool.eraser) {
      return EraserOptionsBar(
        width: width,
        mode: eraserMode,
        onWidthChanged: onWidthChanged,
        onModeChanged: onEraserModeChanged,
      );
    }
    if (selectedTool == StrokeTool.image) {
      return _ContextActionRow(
        icon: Icons.crop_outlined,
        label: hasSingleImageSelection ? '이미지 자르기' : '이미지를 선택해 자르기',
        onTap: hasSingleImageSelection ? onCropRequested : null,
      );
    }
    if (_isShapeTool(selectedTool)) {
      return ShapeOptionsBar(
        shapeType: shapeType,
        width: width,
        color: color,
        onShapeTypeChanged: onShapeTypeChanged,
        onWidthChanged: onWidthChanged,
        onColorChanged: onColorChanged,
        onPaletteRequested: onPaletteRequested,
      );
    }
    if (selectedTool == StrokeTool.lasso) {
      return LassoOptionsBar(
        hasSelection: hasSelection,
        hasShapeSelection: hasShapeSelection,
        mode: lassoMode,
        includeStrokes: lassoIncludeStrokes,
        includeTexts: lassoIncludeTexts,
        includeImages: lassoIncludeImages,
        onModeChanged: onLassoModeChanged,
        onIncludeStrokesChanged: onLassoIncludeStrokesChanged,
        onIncludeTextsChanged: onLassoIncludeTextsChanged,
        onIncludeImagesChanged: onLassoIncludeImagesChanged,
        onDuplicateSelection: onDuplicateSelection,
        onDeleteSelection: onDeleteSelection,
        onShapeStyleRequested: onShapeStyleRequested,
      );
    }
    return TextOptionsBar(
        width: width,
        color: color,
        onWidthChanged: onWidthChanged,
        onColorChanged: onColorChanged,
        onPaletteRequested: onPaletteRequested,
        bold: textBold,
        alignment: textAlignment,
        onBoldChanged: onTextBoldChanged,
        onAlignmentChanged: onTextAlignmentChanged);
  }

  bool _isShapeTool(StrokeTool tool) => _isShapeToolValue(tool);
}

bool _isShapeToolValue(StrokeTool tool) =>
    tool == StrokeTool.shapeLine ||
    tool == StrokeTool.shapeRectangle ||
    tool == StrokeTool.shapeEllipse ||
    tool == StrokeTool.shapeArrow ||
    tool == StrokeTool.shapeTriangle;

class PenOptionsBar extends StatelessWidget {
  const PenOptionsBar({
    required this.width,
    required this.color,
    required this.onWidthChanged,
    required this.onColorChanged,
    required this.onPaletteRequested,
    super.key,
  });
  final double width;
  final Color color;
  final ValueChanged<double> onWidthChanged;
  final ValueChanged<Color> onColorChanged;
  final VoidCallback onPaletteRequested;

  @override
  Widget build(BuildContext context) => _InkOptionsLayout(
        label: '펜',
        icon: Icons.edit_outlined,
        width: width,
        min: 1,
        max: 12,
        color: color,
        onWidthChanged: onWidthChanged,
        onColorChanged: onColorChanged,
        onPaletteRequested: onPaletteRequested,
      );
}

class HighlighterOptionsBar extends StatelessWidget {
  const HighlighterOptionsBar({
    required this.width,
    required this.color,
    required this.opacity,
    required this.onWidthChanged,
    required this.onColorChanged,
    required this.onOpacityChanged,
    required this.onPaletteRequested,
    super.key,
  });
  final double width;
  final Color color;
  final double opacity;
  final ValueChanged<double> onWidthChanged;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onOpacityChanged;
  final VoidCallback onPaletteRequested;

  @override
  Widget build(BuildContext context) => _InkOptionsLayout(
        label: '형광펜',
        icon: Icons.border_color_outlined,
        width: width,
        min: 4,
        max: 30,
        color: color,
        onWidthChanged: onWidthChanged,
        onColorChanged: onColorChanged,
        onPaletteRequested: onPaletteRequested,
        trailing: _OpacityButton(value: opacity, onChanged: onOpacityChanged),
      );
}

class EraserOptionsBar extends StatelessWidget {
  const EraserOptionsBar({
    required this.width,
    required this.mode,
    required this.onWidthChanged,
    required this.onModeChanged,
    super.key,
  });
  final double width;
  final EraserMode mode;
  final ValueChanged<double> onWidthChanged;
  final ValueChanged<EraserMode> onModeChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          _WidthPresetGroup(
            value: width,
            values: const [4, 10, 24],
            color: Theme.of(context).colorScheme.primary,
            semanticLabel: '지우개 크기 프리셋',
            onChanged: onWidthChanged,
            onDetailsRequested: () => _showWidthValuePopover(
              context,
              title: '지우개 크기',
              value: width,
              min: 2,
              max: 50,
              color: Theme.of(context).colorScheme.primary,
              onChanged: onWidthChanged,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: SizedBox(
              width: 34,
              child: Text(
                '${width.round()} px',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          _EraserModeSegmentedControl(
            mode: mode,
            onChanged: onModeChanged,
          ),
        ]),
      );
}

class _EraserModeSegmentedControl extends StatelessWidget {
  const _EraserModeSegmentedControl({
    required this.mode,
    required this.onChanged,
  });
  final EraserMode mode;
  final ValueChanged<EraserMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '지우개 방식',
      child: Container(
        height: 30,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer.withValues(alpha: .62),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _EraserModeSegment(
            label: '부분',
            selected: mode == EraserMode.partial,
            onTap: () => onChanged(EraserMode.partial),
          ),
          _EraserModeSegment(
            label: '획 전체',
            selected: mode == EraserMode.wholeStroke,
            onTap: () => onChanged(EraserMode.wholeStroke),
          ),
        ]),
      ),
    );
  }
}

class _EraserModeSegment extends StatelessWidget {
  const _EraserModeSegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label 모드',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer.withValues(alpha: .72)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
          ),
        ),
      ),
    );
  }
}

class ShapeOptionsBar extends StatelessWidget {
  const ShapeOptionsBar({
    required this.shapeType,
    required this.width,
    required this.color,
    required this.onShapeTypeChanged,
    required this.onWidthChanged,
    required this.onColorChanged,
    required this.onPaletteRequested,
    super.key,
  });
  final DrawingShapeType shapeType;
  final double width;
  final Color color;
  final ValueChanged<DrawingShapeType> onShapeTypeChanged;
  final ValueChanged<double> onWidthChanged;
  final ValueChanged<Color> onColorChanged;
  final VoidCallback onPaletteRequested;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final type in DrawingShapeType.values)
            _ShapeTypeButton(
              type: type,
              selected: type == shapeType,
              onTap: () => onShapeTypeChanged(type),
            ),
          const SizedBox(width: 4),
          _ShapeDetailsButton(
            width: width,
            color: color,
            onWidthChanged: onWidthChanged,
            onPaletteRequested: onPaletteRequested,
          ),
        ]),
      );
}

class _ShapeDetailsButton extends StatelessWidget {
  const _ShapeDetailsButton(
      {required this.width,
      required this.color,
      required this.onWidthChanged,
      required this.onPaletteRequested});
  final double width;
  final Color color;
  final ValueChanged<double> onWidthChanged;
  final VoidCallback onPaletteRequested;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: '도형 선과 색상 설정',
        padding: EdgeInsets.zero,
        elevation: 3,
        color: Theme.of(context).colorScheme.surface,
        popUpAnimationStyle: _toolbarPopupAnimation,
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onSelected: (value) {
          switch (value) {
            case 'thin':
              onWidthChanged(1);
            case 'medium':
              onWidthChanged(4);
            case 'thick':
              onWidthChanged(8);
            case 'color':
              onPaletteRequested();
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'thin',
            height: 40,
            child: _ShapeSettingRow(
                label: '얇은 선', width: 2, selected: width <= 2, color: color),
          ),
          PopupMenuItem(
            value: 'medium',
            height: 40,
            child: _ShapeSettingRow(
                label: '보통 선',
                width: 5,
                selected: width > 2 && width < 8,
                color: color),
          ),
          PopupMenuItem(
            value: 'thick',
            height: 40,
            child: _ShapeSettingRow(
                label: '굵은 선', width: 9, selected: width >= 8, color: color),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'color',
            height: 40,
            child: Row(children: [
              Icon(Icons.palette_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              const Text('색상 선택'),
              const Spacer(),
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .outlineVariant
                        .withValues(alpha: .7),
                  ),
                ),
              ),
            ]),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(Icons.tune_rounded,
              size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
}

class _ShapeSettingRow extends StatelessWidget {
  const _ShapeSettingRow({
    required this.label,
    required this.width,
    required this.selected,
    required this.color,
  });
  final String label;
  final double width;
  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      SizedBox(
        width: 28,
        child: Center(
          child: Container(
            width: 22,
            height: width.clamp(2, 8),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Text(label),
      const Spacer(),
      if (selected) Icon(Icons.check_rounded, size: 18, color: scheme.primary),
    ]);
  }
}

class LassoOptionsBar extends StatelessWidget {
  const LassoOptionsBar({
    required this.hasSelection,
    required this.hasShapeSelection,
    required this.mode,
    required this.includeStrokes,
    required this.includeTexts,
    required this.includeImages,
    required this.onModeChanged,
    required this.onIncludeStrokesChanged,
    required this.onIncludeTextsChanged,
    required this.onIncludeImagesChanged,
    required this.onDuplicateSelection,
    required this.onDeleteSelection,
    required this.onShapeStyleRequested,
    super.key,
  });
  final bool hasSelection;
  final bool hasShapeSelection;
  final LassoMode mode;
  final bool includeStrokes;
  final bool includeTexts;
  final bool includeImages;
  final ValueChanged<LassoMode> onModeChanged;
  final ValueChanged<bool> onIncludeStrokesChanged;
  final ValueChanged<bool> onIncludeTextsChanged;
  final ValueChanged<bool> onIncludeImagesChanged;
  final VoidCallback onDuplicateSelection;
  final VoidCallback onDeleteSelection;
  final VoidCallback onShapeStyleRequested;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          const Icon(Icons.gesture_outlined, size: 18),
          const SizedBox(width: 6),
          _LassoModeSegmentedControl(mode: mode, onChanged: onModeChanged),
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            tooltip: '선택 대상 옵션',
            padding: EdgeInsets.zero,
            elevation: 3,
            color: Theme.of(context).colorScheme.surface,
            popUpAnimationStyle: _toolbarPopupAnimation,
            menuPadding: const EdgeInsets.symmetric(vertical: 4),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            onSelected: (value) {
              switch (value) {
                case 'strokes':
                  onIncludeStrokesChanged(!includeStrokes);
                case 'texts':
                  onIncludeTextsChanged(!includeTexts);
                case 'images':
                  onIncludeImagesChanged(!includeImages);
              }
            },
            itemBuilder: (_) => [
              _lassoIncludeItem(
                  value: 'strokes',
                  label: '필기 포함',
                  icon: Icons.draw_outlined,
                  checked: includeStrokes),
              _lassoIncludeItem(
                  value: 'texts',
                  label: '텍스트 포함',
                  icon: Icons.text_fields_rounded,
                  checked: includeTexts),
              _lassoIncludeItem(
                  value: 'images',
                  label: '이미지 포함',
                  icon: Icons.image_outlined,
                  checked: includeImages),
            ],
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.tune_outlined, size: 18),
            ),
          ),
          if (hasSelection) ...[
            IconButton(
                onPressed: onDuplicateSelection,
                tooltip: '선택 항목 복제',
                icon: const Icon(Icons.content_copy_outlined, size: 20)),
            if (hasShapeSelection)
              IconButton(
                  onPressed: onShapeStyleRequested,
                  tooltip: '선택한 도형 스타일',
                  icon: const Icon(Icons.tune_rounded, size: 20)),
            IconButton(
                onPressed: onDeleteSelection,
                tooltip: '선택 항목 삭제',
                color: Theme.of(context).colorScheme.error,
                icon: const Icon(Icons.delete_outline, size: 20)),
          ],
        ]),
      );

  PopupMenuItem<String> _lassoIncludeItem({
    required String value,
    required String label,
    required IconData icon,
    required bool checked,
  }) =>
      PopupMenuItem(
        value: value,
        height: 40,
        child: Row(children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Text(label),
          const Spacer(),
          if (checked) const Icon(Icons.check_rounded, size: 18),
        ]),
      );
}

class _LassoModeSegmentedControl extends StatelessWidget {
  const _LassoModeSegmentedControl(
      {required this.mode, required this.onChanged});
  final LassoMode mode;
  final ValueChanged<LassoMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 26,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _LassoModeSegment(
          label: '자유형',
          selected: mode == LassoMode.freeform,
          onTap: () => onChanged(LassoMode.freeform),
        ),
        _LassoModeSegment(
          label: '사각형',
          selected: mode == LassoMode.rectangle,
          onTap: () => onChanged(LassoMode.rectangle),
        ),
      ]),
    );
  }
}

class _LassoModeSegment extends StatelessWidget {
  const _LassoModeSegment(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 7),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer.withValues(alpha: .72)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                )),
      ),
    );
  }
}

class TextOptionsBar extends StatelessWidget {
  const TextOptionsBar({
    required this.width,
    required this.color,
    required this.onWidthChanged,
    required this.onColorChanged,
    required this.onPaletteRequested,
    this.bold = false,
    this.alignment = 'left',
    this.onBoldChanged,
    this.onAlignmentChanged,
    super.key,
  });
  final double width;
  final Color color;
  final ValueChanged<double> onWidthChanged;
  final ValueChanged<Color> onColorChanged;
  final VoidCallback onPaletteRequested;
  final bool bold;
  final String alignment;
  final ValueChanged<bool>? onBoldChanged;
  final ValueChanged<String>? onAlignmentChanged;

  @override
  Widget build(BuildContext context) => _InkOptionsLayout(
        label: '텍스트',
        icon: Icons.text_fields_rounded,
        width: width,
        min: 12,
        max: 32,
        color: color,
        onWidthChanged: onWidthChanged,
        onColorChanged: onColorChanged,
        onPaletteRequested: onPaletteRequested,
        trailing: _TextFormattingButton(
          bold: bold,
          alignment: alignment,
          onBoldChanged: onBoldChanged,
          onAlignmentChanged: onAlignmentChanged,
        ),
        widthSuffix: 'pt',
      );
}

class _TextFormattingButton extends StatelessWidget {
  const _TextFormattingButton({
    required this.bold,
    required this.alignment,
    required this.onBoldChanged,
    required this.onAlignmentChanged,
  });
  final bool bold;
  final String alignment;
  final ValueChanged<bool>? onBoldChanged;
  final ValueChanged<String>? onAlignmentChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: '텍스트 서식',
        padding: EdgeInsets.zero,
        elevation: 3,
        color: Theme.of(context).colorScheme.surface,
        popUpAnimationStyle: _toolbarPopupAnimation,
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onSelected: (value) {
          if (value == 'bold') {
            onBoldChanged?.call(!bold);
          } else {
            onAlignmentChanged?.call(value);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'bold',
            height: 40,
            child: Row(children: [
              Icon(Icons.format_bold_rounded,
                  size: 18,
                  color: bold
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              const Text('굵게'),
              const Spacer(),
              if (bold)
                Icon(Icons.check_rounded,
                    size: 18, color: Theme.of(context).colorScheme.primary),
            ]),
          ),
          const PopupMenuDivider(),
          for (final entry in const [
            (value: 'left', label: '왼쪽 정렬', icon: Icons.format_align_left),
            (value: 'center', label: '가운데 정렬', icon: Icons.format_align_center),
            (value: 'right', label: '오른쪽 정렬', icon: Icons.format_align_right),
          ])
            PopupMenuItem(
              value: entry.value,
              height: 40,
              child: Row(children: [
                Icon(entry.icon, size: 18),
                const SizedBox(width: 10),
                Text(entry.label),
                const Spacer(),
                if (alignment == entry.value)
                  Icon(Icons.check_rounded,
                      size: 18, color: Theme.of(context).colorScheme.primary),
              ]),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            bold ? Icons.format_bold_rounded : Icons.format_align_left,
            size: 18,
            color: bold
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
}

class _InkOptionsLayout extends StatelessWidget {
  const _InkOptionsLayout({
    required this.label,
    required this.icon,
    required this.width,
    required this.min,
    required this.max,
    required this.color,
    required this.onWidthChanged,
    required this.onColorChanged,
    required this.onPaletteRequested,
    this.trailing,
    this.widthSuffix = 'mm',
  });
  final String label;
  final IconData icon;
  final double width;
  final double min;
  final double max;
  final Color color;
  final ValueChanged<double> onWidthChanged;
  final ValueChanged<Color> onColorChanged;
  final VoidCallback onPaletteRequested;
  final Widget? trailing;
  final String widthSuffix;

  static const recentColors = [
    Colors.black,
    Color(0xff3f6f9f),
    Color(0xffc95656),
    Color(0xff4e8b68),
  ];

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          _WidthPresetGroup(
            value: width,
            values: [min, min + (max - min) * .45, max],
            color: color,
            semanticLabel: '$label 굵기 프리셋',
            onChanged: onWidthChanged,
            onDetailsRequested: () => _showWidthPopover(context),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: SizedBox(
              width: 42,
              child: InkWell(
                onTap: () => _showWidthPopover(context),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 3, vertical: 5),
                  child: Text(
                      widthSuffix == 'mm'
                          ? '${(width / 4).toStringAsFixed(1)} mm'
                          : '${width.round()} pt',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          )),
                ),
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 4), trailing!],
          const SizedBox(width: 6),
          for (final swatch in recentColors.take(3))
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: ColorChip(
                color: swatch,
                selected: swatch == color,
                onTap: () => onColorChanged(swatch),
              ),
            ),
          const SizedBox(width: 4),
          _PaletteButton(color: color, onTap: onPaletteRequested),
        ]),
      );

  Future<void> _showWidthPopover(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('$label 굵기'),
        content: StatefulBuilder(
          builder: (context, setDialogState) => SizedBox(
            width: 270,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                height: 28,
                alignment: Alignment.center,
                child: Container(
                  width: 120,
                  height: width.clamp(1, 12) / 12 * 8 + 1,
                  decoration: BoxDecoration(
                      color: color, borderRadius: BorderRadius.circular(8)),
                ),
              ),
              Slider(
                value: width.clamp(min, max),
                min: min,
                max: max,
                onChanged: (value) {
                  setDialogState(() {});
                  onWidthChanged(value);
                },
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('닫기'))
        ],
      ),
    );
  }
}

class StrokeWidthSlider extends StatelessWidget {
  const StrokeWidthSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.color,
    required this.onChanged,
    required this.semanticLabel,
    super.key,
  });
  final double value;
  final double min;
  final double max;
  final Color color;
  final ValueChanged<double> onChanged;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
        slider: true,
        label: semanticLabel,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: color,
            inactiveTrackColor: color.withValues(alpha: .18),
            thumbColor: color,
            trackHeight: 2,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      );
}

class ColorChip extends StatelessWidget {
  const ColorChip({
    required this.color,
    required this.selected,
    required this.onTap,
    super.key,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: '색상 선택',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: 20,
            height: 20,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: .72)
                    : Theme.of(context)
                        .colorScheme
                        .outlineVariant
                        .withValues(alpha: .7),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ),
      );
}

class _OpacityButton extends StatelessWidget {
  const _OpacityButton({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<double>(
        tooltip: '형광펜 강도',
        padding: EdgeInsets.zero,
        elevation: 3,
        color: Theme.of(context).colorScheme.surface,
        popUpAnimationStyle: _toolbarPopupAnimation,
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onSelected: onChanged,
        itemBuilder: (_) => [
          _opacityItem(context, '연하게', .2),
          _opacityItem(context, '보통', .35),
          _opacityItem(context, '진하게', .5),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainer
                .withValues(alpha: .55),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.opacity_outlined,
                size: 15,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 3),
            Text('${(value * 100).round()}%',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    )),
          ]),
        ),
      );

  PopupMenuItem<double> _opacityItem(
          BuildContext context, String label, double value) =>
      PopupMenuItem(
        value: value,
        height: 40,
        child: Row(children: [
          Icon(Icons.opacity_outlined,
              size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Text('$label ${(value * 100).round()}%'),
          const Spacer(),
          if ((value - this.value).abs() < .01)
            Icon(Icons.check_rounded,
                size: 18, color: Theme.of(context).colorScheme.primary),
        ]),
      );
}

class _ContextActionRow extends StatelessWidget {
  const _ContextActionRow(
      {required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 19),
          label: Text(label),
        ),
      );
}

class _CropPreview extends StatefulWidget {
  const _CropPreview(
      {required this.path, required this.crop, required this.onChanged});
  final String path;
  final Rect crop;
  final ValueChanged<Rect> onChanged;

  @override
  State<_CropPreview> createState() => _CropPreviewState();
}

class _CropPreviewState extends State<_CropPreview> {
  String? edge;

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: 1.55,
        child: LayoutBuilder(builder: (context, constraints) {
          final crop = widget.crop;
          return GestureDetector(
            onPanStart: (details) {
              final p = Offset(details.localPosition.dx / constraints.maxWidth,
                  details.localPosition.dy / constraints.maxHeight);
              final distances = <String, double>{
                'left': (p.dx - crop.left).abs(),
                'right': (p.dx - crop.right).abs(),
                'top': (p.dy - crop.top).abs(),
                'bottom': (p.dy - crop.bottom).abs(),
              };
              edge = distances.entries
                  .reduce((a, b) => a.value < b.value ? a : b)
                  .key;
            },
            onPanUpdate: (details) {
              if (edge == null) return;
              final dx = details.delta.dx / constraints.maxWidth;
              final dy = details.delta.dy / constraints.maxHeight;
              var next = crop;
              switch (edge) {
                case 'left':
                  next = Rect.fromLTRB(
                      (crop.left + dx).clamp(0, crop.right - .05),
                      crop.top,
                      crop.right,
                      crop.bottom);
                case 'right':
                  next = Rect.fromLTRB(crop.left, crop.top,
                      (crop.right + dx).clamp(crop.left + .05, 1), crop.bottom);
                case 'top':
                  next = Rect.fromLTRB(
                      crop.left,
                      (crop.top + dy).clamp(0, crop.bottom - .05),
                      crop.right,
                      crop.bottom);
                case 'bottom':
                  next = Rect.fromLTRB(crop.left, crop.top, crop.right,
                      (crop.bottom + dy).clamp(crop.top + .05, 1));
              }
              widget.onChanged(next);
            },
            onPanEnd: (_) => edge = null,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(fit: StackFit.expand, children: [
                Image.file(File(widget.path), fit: BoxFit.cover),
                CustomPaint(painter: _CropOverlayPainter(crop)),
              ]),
            ),
          );
        }),
      );
}

class _CropOverlayPainter extends CustomPainter {
  const _CropOverlayPainter(this.crop);
  final Rect crop;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(crop.left * size.width, crop.top * size.height,
        crop.right * size.width, crop.bottom * size.height);
    final shade = Paint()..color = Colors.black45;
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), shade);
    canvas.drawRect(
        Rect.fromLTRB(0, rect.bottom, size.width, size.height), shade);
    canvas.drawRect(Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), shade);
    canvas.drawRect(
        Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom), shade);
    canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _CropOverlayPainter oldDelegate) =>
      oldDelegate.crop != crop;
}

class _CropSlider extends StatelessWidget {
  const _CropSlider(
      {required this.label,
      required this.value,
      required this.min,
      required this.max,
      required this.onChanged});
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(children: [
        SizedBox(
            width: 42,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
        Expanded(
            child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged)),
      ]);
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
      DrawingShapeType.triangle => Icons.change_history_outlined,
    };
    final label = switch (type) {
      DrawingShapeType.line => '직선',
      DrawingShapeType.rectangle => '사각형',
      DrawingShapeType.ellipse => '타원',
      DrawingShapeType.arrow => '화살표',
      DrawingShapeType.triangle => '삼각형',
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
          height: 50,
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

class _PaletteButton extends StatelessWidget {
  const _PaletteButton({required this.color, required this.onTap});
  final Color color;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '색상 팔레트 열기',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 34,
            height: 28,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .outlineVariant
                          .withValues(alpha: .7),
                    ),
                  ),
                  child: const SizedBox(width: 11, height: 11),
                ),
                const SizedBox(width: 3),
                Icon(Icons.palette_outlined,
                    size: 17,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      );
}

class _PaletteColorButton extends StatelessWidget {
  const _PaletteColorButton(
      {required this.color,
      required this.selected,
      required this.onTap,
      this.label});
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final String? label;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Semantics(
          button: true,
          selected: selected,
          label: label ?? '색상 선택',
          child: Container(
            width: 48,
            height: 48,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context)
                          .colorScheme
                          .outlineVariant
                          .withValues(alpha: .75),
                  width: selected ? 2 : 1),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
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

class _PerfSample {
  const _PerfSample({
    required this.rawMoveEvents,
    required this.acceptedPoints,
    required this.rejectedNearPoints,
    required this.avgPointDistance,
    required this.minPointDistance,
    required this.maxPointDistance,
    required this.totalStrokeDistance,
    required this.pathBuildCount,
    required this.pathBuildAvgUs,
    required this.pathBuildMaxUs,
    required this.fullPathRebuildCount,
    required this.incrementalSegmentBuildCount,
    required this.incrementalBuildAvgUs,
    required this.incrementalBuildMaxUs,
    required this.activePaintAvgUs,
    required this.activePaintMaxUs,
    required this.overlayPaintAvgUs,
    required this.overlayPaintMaxUs,
    required this.pictureDrawAvgUs,
    required this.pictureDrawMaxUs,
    required this.activePathDrawAvgUs,
    required this.activePathDrawMaxUs,
    required this.buildAvgMs,
    required this.buildP95Ms,
    required this.buildMaxMs,
    required this.rasterAvgMs,
    required this.rasterP95Ms,
    required this.rasterMaxMs,
    required this.editorBuilds,
    required this.staticPainterRepaints,
    required this.activePainterRepaints,
    required this.activeRevisionUpdates,
    required this.staticObjectPaintCount,
    required this.avgFrameMs,
    required this.p95FrameMs,
    required this.maxFrameMs,
    required this.strokeElapsedMs,
  });
  final int rawMoveEvents;
  final int acceptedPoints;
  final int rejectedNearPoints;
  final double avgPointDistance;
  final double minPointDistance;
  final double maxPointDistance;
  final double totalStrokeDistance;
  final int pathBuildCount;
  final int pathBuildAvgUs;
  final int pathBuildMaxUs;
  final int fullPathRebuildCount;
  final int incrementalSegmentBuildCount;
  final int incrementalBuildAvgUs;
  final int incrementalBuildMaxUs;
  final int activePaintAvgUs;
  final int activePaintMaxUs;
  final int overlayPaintAvgUs;
  final int overlayPaintMaxUs;
  final int pictureDrawAvgUs;
  final int pictureDrawMaxUs;
  final int activePathDrawAvgUs;
  final int activePathDrawMaxUs;
  final double buildAvgMs;
  final double buildP95Ms;
  final double buildMaxMs;
  final double rasterAvgMs;
  final double rasterP95Ms;
  final double rasterMaxMs;
  final int editorBuilds;
  final int staticPainterRepaints;
  final int activePainterRepaints;
  final int activeRevisionUpdates;
  final int staticObjectPaintCount;
  final double avgFrameMs;
  final double p95FrameMs;
  final double maxFrameMs;
  final int strokeElapsedMs;
  double get reductionRate =>
      rawMoveEvents == 0 ? 0 : (rejectedNearPoints / rawMoveEvents) * 100;
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
        a.height != b.height) {
      return false;
    }
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
        a.color != b.color ||
        a.bold != b.bold ||
        a.alignment != b.alignment) {
      return false;
    }
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

TextAlign _textAlignValue(String value) => switch (value) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      _ => TextAlign.left,
    };

Rect _textRect(DrawingText text, Size size) => Rect.fromLTWH(
    text.position.x * size.width,
    text.position.y * size.height,
    text.maxWidth * size.width,
    _textRectNormalized(text).height * size.height);

Rect _imageRectNormalized(DrawingImage image) => Rect.fromLTWH(
    image.position.x, image.position.y, image.width, image.height);

Rect _pointsBounds(List<StrokePoint> points) {
  final xs = points.map((point) => point.x);
  final ys = points.map((point) => point.y);
  return Rect.fromLTRB(xs.reduce(math.min), ys.reduce(math.min),
      xs.reduce(math.max), ys.reduce(math.max));
}

bool _imageIsInsideLasso(
    DrawingImage image, List<StrokePoint> polygon, Rect polygonBounds) {
  final rect = _imageRectNormalized(image);
  if (!rect.overlaps(polygonBounds)) return false;
  final points = [
    StrokePoint(rect.left, rect.top, 1),
    StrokePoint(rect.right, rect.top, 1),
    StrokePoint(rect.left, rect.bottom, 1),
    StrokePoint(rect.right, rect.bottom, 1),
    StrokePoint(rect.center.dx, rect.center.dy, 1),
  ];
  return points.where((point) => _pointInPolygon(point, polygon)).length >= 3;
}

bool _textIsInsideLasso(
    DrawingText text, List<StrokePoint> polygon, Rect polygonBounds) {
  final rect = _textRectNormalized(text);
  if (!rect.overlaps(polygonBounds)) return false;
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
        StrokePoint point, Rect bounds, double scaleX, double scaleY,
        {Offset offset = Offset.zero}) =>
    StrokePoint(
      bounds.left + offset.dx + (point.x - bounds.left) * scaleX,
      bounds.top + offset.dy + (point.y - bounds.top) * scaleY,
      point.pressure,
    );

enum _ResizeHandle {
  topLeft(-1, -1),
  topRight(1, -1),
  bottomLeft(-1, 1),
  bottomRight(1, 1);

  const _ResizeHandle(this.horizontal, this.vertical);
  final int horizontal;
  final int vertical;
}

_ResizeHandle? _resizeHandleHit(Rect bounds, StrokePoint point) {
  for (final handle in _ResizeHandle.values) {
    final x = handle.horizontal < 0 ? bounds.left : bounds.right;
    final y = handle.vertical < 0 ? bounds.top : bounds.bottom;
    if ((point.x - x).abs() <= .035 && (point.y - y).abs() <= .035) {
      return handle;
    }
  }
  return null;
}

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

class _WidthPresetGroup extends StatelessWidget {
  const _WidthPresetGroup({
    required this.value,
    required this.values,
    required this.color,
    required this.onChanged,
    required this.semanticLabel,
    this.onDetailsRequested,
  });
  final double value;
  final List<double> values;
  final Color color;
  final ValueChanged<double> onChanged;
  final String semanticLabel;
  final VoidCallback? onDetailsRequested;

  @override
  Widget build(BuildContext context) => Semantics(
        label: semanticLabel,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final preset in values)
            InkWell(
              onTap: () {
                if (preset == _nearestPreset && onDetailsRequested != null) {
                  onDetailsRequested!();
                } else {
                  onChanged(preset);
                }
              },
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 32,
                height: 34,
                child: Center(
                  child: Container(
                    width: 22,
                    height: 1.5 + 5 * (preset / values.last),
                    decoration: BoxDecoration(
                      color: preset == _nearestPreset
                          ? color
                          : color.withValues(alpha: .52),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );

  double get _nearestPreset =>
      values.reduce((a, b) => (value - a).abs() <= (value - b).abs() ? a : b);
}

Future<void> _showWidthValuePopover(
  BuildContext context, {
  required String title,
  required double value,
  required double min,
  required double max,
  required Color color,
  required ValueChanged<double> onChanged,
}) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 270,
        child: StatefulBuilder(
          builder: (context, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 28,
                alignment: Alignment.center,
                child: Container(
                  width: 120,
                  height: 2 + 7 * ((value - min) / (max - min)),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: (next) {
                  setDialogState(() {});
                  onChanged(next);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('닫기'),
        ),
      ],
    ),
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

bool _strokeIsInsideLasso(
    Stroke stroke, List<StrokePoint> polygon, Rect polygonBounds) {
  if (stroke.points.isEmpty) return false;
  if (!_pointsBounds(stroke.points).overlaps(polygonBounds)) return false;
  // Selecting an ink stroke should work when the lasso contains it *or*
  // crosses it. Requiring most points to be inside made long strokes at the
  // edge of a selection unexpectedly unselectable.
  if (stroke.points.any((point) => _pointInPolygon(point, polygon))) {
    return true;
  }
  for (var index = 1; index < stroke.points.length; index++) {
    if (_segmentIntersectsPolygon(
        stroke.points[index - 1], stroke.points[index], polygon)) {
      return true;
    }
  }
  return false;
}

bool _shapeIsInsideLasso(
    DrawingShape shape, List<StrokePoint> polygon, Rect polygonBounds) {
  final points = _shapeSelectionPoints(shape);
  if (!_pointsBounds(points).overlaps(polygonBounds)) return false;
  final start = points.first;
  final end = points[1];
  final center = StrokePoint((start.x + end.x) / 2, (start.y + end.y) / 2, 1);
  if (shape.type == DrawingShapeType.line ||
      shape.type == DrawingShapeType.arrow) {
    return _pointInPolygon(start, polygon) ||
        _pointInPolygon(end, polygon) ||
        _segmentIntersectsPolygon(start, end, polygon);
  }
  final corners = [...points, center];
  if (corners.any((point) => _pointInPolygon(point, polygon))) return true;
  for (var index = 0; index < 4; index++) {
    if (_segmentIntersectsPolygon(
        points[index], points[(index + 1) % 4], polygon)) {
      return true;
    }
  }
  return false;
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

bool _segmentIntersectsPolygon(
    StrokePoint start, StrokePoint end, List<StrokePoint> polygon) {
  for (var index = 0; index < polygon.length; index++) {
    final next = polygon[(index + 1) % polygon.length];
    if (_segmentsIntersect(start, end, polygon[index], next)) return true;
  }
  return false;
}

bool _segmentsIntersect(
    StrokePoint a, StrokePoint b, StrokePoint c, StrokePoint d) {
  final ab = _orientation(a, b, c);
  final ab2 = _orientation(a, b, d);
  final cd = _orientation(c, d, a);
  final cd2 = _orientation(c, d, b);
  const epsilon = 1e-9;
  final crosses = ((ab > epsilon && ab2 < -epsilon) ||
          (ab < -epsilon && ab2 > epsilon)) &&
      ((cd > epsilon && cd2 < -epsilon) || (cd < -epsilon && cd2 > epsilon));
  if (crosses) return true;
  return (ab.abs() <= epsilon && _pointOnSegment(a, b, c)) ||
      (ab2.abs() <= epsilon && _pointOnSegment(a, b, d)) ||
      (cd.abs() <= epsilon && _pointOnSegment(c, d, a)) ||
      (cd2.abs() <= epsilon && _pointOnSegment(c, d, b));
}

double _orientation(StrokePoint a, StrokePoint b, StrokePoint c) =>
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);

bool _pointOnSegment(StrokePoint a, StrokePoint b, StrokePoint point) =>
    point.x >= math.min(a.x, b.x) - 1e-9 &&
    point.x <= math.max(a.x, b.x) + 1e-9 &&
    point.y >= math.min(a.y, b.y) - 1e-9 &&
    point.y <= math.max(a.y, b.y) + 1e-9;

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
      this.repaint,
      this.staticRepaint,
      this.revision = 0,
      this.staticRevision = 0,
      this.useIncrementalActivePath = true,
      this.instrumentationEnabled = true,
      this.onPaint,
      this.onStaticPaint,
      this.onStaticObjectPaint,
      this.onPathBuild,
      this.onIncrementalPathBuild,
      this.onFullPathRebuild,
      this.onActivePaint,
      this.onOverlayPaint,
      this.onPictureDraw,
      this.onActivePathDraw,
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
  final Listenable? repaint;
  final Listenable? staticRepaint;
  final int revision;
  final int staticRevision;
  final bool useIncrementalActivePath;
  final bool instrumentationEnabled;
  final VoidCallback? onPaint;
  final VoidCallback? onStaticPaint;
  final VoidCallback? onStaticObjectPaint;
  final ValueChanged<Duration>? onPathBuild;
  final ValueChanged<Duration>? onIncrementalPathBuild;
  final VoidCallback? onFullPathRebuild;
  final ValueChanged<Duration>? onActivePaint;
  final ValueChanged<Duration>? onOverlayPaint;
  final ValueChanged<Duration>? onPictureDraw;
  final ValueChanged<Duration>? onActivePathDraw;
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
            child: RepaintBoundary(
              child: Stack(children: [
                RepaintBoundary(
                  child: CustomPaint(
                    isComplex: true,
                    willChange: false,
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
                        selectedImageIds,
                        revision,
                        staticRevision,
                        onPaint,
                        onStaticPaint,
                        onStaticObjectPaint,
                        onPathBuild,
                        onIncrementalPathBuild,
                        onFullPathRebuild,
                        onActivePaint,
                        onOverlayPaint,
                        onPictureDraw,
                        onActivePathDraw,
                        useIncrementalActivePath,
                        instrumentationEnabled,
                        staticRepaint,
                        true),
                    child: const SizedBox.expand(),
                  ),
                ),
                RepaintBoundary(
                  child: CustomPaint(
                    isComplex: false,
                    willChange: true,
                    foregroundPainter: StrokePainter.activeLayer(
                      StrokePainter(
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
                          selectedImageIds,
                          revision,
                          staticRevision,
                          onPaint,
                          onStaticPaint,
                          onStaticObjectPaint,
                          onPathBuild,
                          onIncrementalPathBuild,
                          onFullPathRebuild,
                          onActivePaint,
                          onOverlayPaint,
                          onPictureDraw,
                          onActivePathDraw,
                          useIncrementalActivePath,
                          instrumentationEnabled,
                          null,
                          true),
                      repaint,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ]),
            ));
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
      this.selectedImageIds = const {},
      this.revision = 0,
      this.staticRevision = 0,
      this.onPaint,
      this.onStaticPaint,
      this.onStaticObjectPaint,
      this.onPathBuild,
      this.onIncrementalPathBuild,
      this.onFullPathRebuild,
      this.onActivePaint,
      this.onOverlayPaint,
      this.onPictureDraw,
      this.onActivePathDraw,
      this.useIncrementalActivePath = true,
      this.instrumentationEnabled = true,
      Listenable? repaint,
      this.staticOnly = false])
      : super(repaint: repaint);

  StrokePainter.activeLayer(StrokePainter source, Listenable? repaint)
      : this(
            source.strokes,
            source.active,
            source.size,
            source.activeTool,
            source.activeColor,
            source.activeWidth,
            source.activePenType,
            source.lassoPath,
            source.selectedStrokeIds,
            source.shapes,
            source.activeShape,
            source.selectedShapeIds,
            source.texts,
            source.selectedTextIds,
            source.hiddenTextId,
            source.images,
            source.imageCache,
            source.selectedImageIds,
            source.revision,
            source.staticRevision,
            source.onPaint,
            source.onStaticPaint,
            source.onStaticObjectPaint,
            source.onPathBuild,
            source.onIncrementalPathBuild,
            source.onFullPathRebuild,
            source.onActivePaint,
            source.onOverlayPaint,
            source.onPictureDraw,
            source.onActivePathDraw,
            source.useIncrementalActivePath,
            source.instrumentationEnabled,
            repaint,
            false);
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
  final int revision;
  final int staticRevision;
  final VoidCallback? onPaint;
  final VoidCallback? onStaticPaint;
  final VoidCallback? onStaticObjectPaint;
  final ValueChanged<Duration>? onPathBuild;
  final ValueChanged<Duration>? onIncrementalPathBuild;
  final VoidCallback? onFullPathRebuild;
  final ValueChanged<Duration>? onActivePaint;
  final ValueChanged<Duration>? onOverlayPaint;
  final ValueChanged<Duration>? onPictureDraw;
  final ValueChanged<Duration>? onActivePathDraw;
  final bool useIncrementalActivePath;
  final bool instrumentationEnabled;
  final bool staticOnly;
  ui.Picture? _staticPicture;
  Size? _staticSize;
  int _staticRevision = -1;
  Path? _activePath;
  int _activeProcessedPointCount = 0;
  Size? _activePathSize;
  StrokePoint? _activeFirstPoint;
  final Paint _activePaint = Paint();
  static final DateTime _activeCreatedAt =
      DateTime.fromMicrosecondsSinceEpoch(0);
  @override
  void paint(Canvas canvas, Size _) {
    if (!staticOnly) onPaint?.call();
    if (staticOnly) {
      if (_staticPicture == null ||
          _staticRevision != staticRevision ||
          _staticSize != size) {
        final recorder = ui.PictureRecorder();
        final staticCanvas = Canvas(recorder);
        _paintStatic(staticCanvas);
        onStaticPaint?.call();
        _staticPicture = recorder.endRecording();
        _staticRevision = staticRevision;
        _staticSize = size;
      }
      final pictureClock = _drawingPerfEnabled && instrumentationEnabled
          ? (Stopwatch()..start())
          : null;
      canvas.drawPicture(_staticPicture!);
      pictureClock?.stop();
      onPictureDraw?.call(pictureClock?.elapsed ?? Duration.zero);
      return;
    }
    if (activeShape case final shape?) _paintShape(canvas, shape);
    if (active.isNotEmpty) {
      final activeClock = _drawingPerfEnabled && instrumentationEnabled
          ? (Stopwatch()..start())
          : null;
      _paintActiveStroke(canvas);
      activeClock?.stop();
      onActivePaint?.call(activeClock?.elapsed ?? Duration.zero);
    }
    final overlayClock = _drawingPerfEnabled && instrumentationEnabled
        ? (Stopwatch()..start())
        : null;
    _paintLasso(canvas);
    _paintSelectionBounds(canvas);
    overlayClock?.stop();
    onOverlayPaint?.call(overlayClock?.elapsed ?? Duration.zero);
  }

  void _paintStatic(Canvas canvas) {
    for (final image in images) {
      onStaticObjectPaint?.call();
      _paintImage(canvas, image);
    }
    for (final shape in shapes) {
      onStaticObjectPaint?.call();
      _paintShape(canvas, shape);
    }
    for (final text in texts) {
      onStaticObjectPaint?.call();
      if (text.id != hiddenTextId) _paintText(canvas, text);
    }
    for (final stroke in strokes) {
      onStaticObjectPaint?.call();
      _paintStroke(canvas, stroke);
    }
  }

  void _paintStroke(Canvas canvas, Stroke stroke) {
    if (stroke.points.isEmpty) return;
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
        stroke.tool == StrokeTool.shapeArrow ||
        stroke.tool == StrokeTool.shapeTriangle) {
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
        case StrokeTool.shapeTriangle:
          final rect = Rect.fromPoints(start, end);
          final path = Path()
            ..moveTo(rect.center.dx, rect.top)
            ..lineTo(rect.right, rect.bottom)
            ..lineTo(rect.left, rect.bottom)
            ..close();
          canvas.drawPath(path, paint);
        case StrokeTool.pen:
        case StrokeTool.highlighter:
        case StrokeTool.eraser:
        case StrokeTool.lasso:
        case StrokeTool.text:
        case StrokeTool.image:
          break;
      }
      return;
    }
    _paintSmoothStroke(canvas, stroke, paint);
    if (stroke.points.length == 1) {
      final point = stroke.points.first;
      canvas.drawCircle(
          restorePoint(point, size), _widthFor(stroke, point) / 2, paint);
    }
  }

  void _paintActiveStroke(Canvas canvas) {
    final stroke = Stroke(
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
        createdAt: _activeCreatedAt);
    if (active.length < 3) {
      _activePath = null;
      _activeProcessedPointCount = 0;
      _activeFirstPoint = null;
      _paintStroke(canvas, stroke);
      return;
    }
    if (_hasPressureVariation(stroke)) {
      // Variable-width pressure strokes need per-segment paints; retain the
      // incremental path for the common constant-pressure case.
      _paintStroke(canvas, stroke);
      return;
    }
    if (!useIncrementalActivePath) {
      _paintStroke(canvas, stroke);
      return;
    }
    final paint = _activePaint
      ..color = stroke.color.withValues(alpha: _opacityFor(stroke))
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = (_widthFor(stroke, active[active.length - 2]) +
              _widthFor(stroke, active.last)) /
          2;
    final path = _incrementalActivePath();
    final pathClock = _drawingPerfEnabled && instrumentationEnabled
        ? (Stopwatch()..start())
        : null;
    canvas.drawPath(path, paint);
    pathClock?.stop();
    onActivePathDraw?.call(pathClock?.elapsed ?? Duration.zero);
  }

  Path _incrementalActivePath() {
    final points = active;
    final needsReset = _activePath == null ||
        _activePathSize != size ||
        _activeProcessedPointCount > points.length ||
        _activeFirstPoint?.x != points.first.x ||
        _activeFirstPoint?.y != points.first.y;
    if (needsReset) {
      _activePath = Path()
        ..moveTo(restorePoint(points.first, size).dx,
            restorePoint(points.first, size).dy);
      _activeProcessedPointCount = 1;
      _activePathSize = size;
      _activeFirstPoint = points.first;
      onFullPathRebuild?.call();
    }
    final path = _activePath!;
    // The previous path ends at the prior final point. Appending the new
    // midpoint segment preserves the existing quadratic composition without
    // walking already processed points again.
    final firstNewControl = math.max(1, _activeProcessedPointCount - 1);
    for (var index = firstNewControl; index < points.length - 1; index++) {
      final clock = _drawingPerfEnabled && instrumentationEnabled
          ? (Stopwatch()..start())
          : null;
      final control = restorePoint(points[index], size);
      final next = restorePoint(points[index + 1], size);
      final midpoint =
          Offset((control.dx + next.dx) / 2, (control.dy + next.dy) / 2);
      path.quadraticBezierTo(control.dx, control.dy, midpoint.dx, midpoint.dy);
      path.quadraticBezierTo(next.dx, next.dy, next.dx, next.dy);
      clock?.stop();
      onIncrementalPathBuild?.call(clock?.elapsed ?? Duration.zero);
    }
    _activeProcessedPointCount = points.length;
    return path;
  }

  /// Draws a stroke as a compact quadratic path. Pointer samples are often
  /// uneven on Android, so joining every sample with a hard line can look
  /// visibly jagged at normal writing speed. Midpoints keep the original
  /// normalized coordinates while making the rendered path feel continuous.
  void _paintSmoothStroke(Canvas canvas, Stroke stroke, Paint paint) {
    final pathClock = _drawingPerfEnabled && instrumentationEnabled
        ? (Stopwatch()..start())
        : null;
    final points = stroke.points;
    if (points.length < 2) return;
    if (_hasPressureVariation(stroke)) {
      pathClock?.stop();
      onPathBuild?.call(pathClock?.elapsed ?? Duration.zero);
      _paintVariablePressureStroke(canvas, stroke, paint);
      return;
    }
    if (points.length == 2) {
      final start = points.first;
      final end = points.last;
      paint.strokeWidth =
          (_widthFor(stroke, start) + _widthFor(stroke, end)) / 2;
      canvas.drawLine(
          restorePoint(start, size), restorePoint(end, size), paint);
      return;
    }

    final first = restorePoint(points.first, size);
    final path = Path()..moveTo(first.dx, first.dy);
    for (var index = 1; index < points.length - 1; index++) {
      final control = restorePoint(points[index], size);
      final next = restorePoint(points[index + 1], size);
      final nextMid = Offset(
        (control.dx + next.dx) / 2,
        (control.dy + next.dy) / 2,
      );
      path.quadraticBezierTo(
        control.dx,
        control.dy,
        nextMid.dx,
        nextMid.dy,
      );
      paint.strokeWidth = (_widthFor(stroke, points[index]) +
              _widthFor(stroke, points[index + 1])) /
          2;
    }
    final last = restorePoint(points.last, size);
    path.quadraticBezierTo(last.dx, last.dy, last.dx, last.dy);
    canvas.drawPath(path, paint);
    pathClock?.stop();
    onPathBuild?.call(pathClock?.elapsed ?? Duration.zero);
  }

  bool _hasPressureVariation(Stroke stroke) {
    if (stroke.tool != StrokeTool.pen || stroke.points.length < 3) return false;
    var minPressure = stroke.points.first.pressure;
    var maxPressure = minPressure;
    for (final point in stroke.points.skip(1)) {
      minPressure = math.min(minPressure, point.pressure);
      maxPressure = math.max(maxPressure, point.pressure);
    }
    return maxPressure - minPressure >= .05;
  }

  void _paintVariablePressureStroke(Canvas canvas, Stroke stroke, Paint paint) {
    final points = stroke.points;
    final first = restorePoint(points.first, size);
    canvas.drawCircle(first, _widthFor(stroke, points.first) / 2, paint);
    Path? segmentPath;
    double? bucketWidth;
    void flush() {
      final path = segmentPath;
      if (path != null) canvas.drawPath(path, paint);
      segmentPath = null;
    }

    for (var index = 1; index < points.length - 1; index++) {
      final previous = restorePoint(points[index - 1], size);
      final control = restorePoint(points[index], size);
      final next = restorePoint(points[index + 1], size);
      final start = Offset(
        (previous.dx + control.dx) / 2,
        (previous.dy + control.dy) / 2,
      );
      final end = Offset(
        (control.dx + next.dx) / 2,
        (control.dy + next.dy) / 2,
      );
      final width = (_widthFor(stroke, points[index - 1]) +
              _widthFor(stroke, points[index]) +
              _widthFor(stroke, points[index + 1])) /
          3;
      // Quantizing widths into small buckets lets adjacent segments share a
      // Path/draw call while retaining the visible pressure variation.
      final nextBucket = (width * 2).round() / 2;
      if (bucketWidth != nextBucket) {
        flush();
        bucketWidth = nextBucket;
        paint.strokeWidth = nextBucket;
      }
      (segmentPath ??= Path())
        ..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);
    }
    flush();
    final last = points.last;
    canvas.drawCircle(
        restorePoint(last, size), _widthFor(stroke, last) / 2, paint);
  }

  void _paintText(Canvas canvas, DrawingText text) {
    final painter = TextPainter(
      text: TextSpan(
          text: text.text,
          style: TextStyle(
              color: text.color,
              fontSize: text.fontSize,
              fontWeight: text.bold ? FontWeight.w700 : FontWeight.w400)),
      textDirection: TextDirection.ltr,
      maxLines: null,
      textAlign: _textAlignValue(text.alignment),
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
    final center = destination.center;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(image.rotationRadians);
    canvas.translate(-center.dx, -center.dy);
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
      canvas.restore();
      return;
    }
    canvas.drawImageRect(
        decoded,
        Rect.fromLTWH(
            decoded.width * image.cropLeft,
            decoded.height * image.cropTop,
            decoded.width * (image.cropRight - image.cropLeft),
            decoded.height * (image.cropBottom - image.cropTop)),
        destination,
        Paint()..filterQuality = FilterQuality.medium);
    canvas.restore();
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
      case DrawingShapeType.triangle:
        final rect = Rect.fromPoints(start, end);
        final path = Path()
          ..moveTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.bottom)
          ..lineTo(rect.left, rect.bottom)
          ..close();
        canvas.drawPath(path, paint);
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
        selectedImageIds.isEmpty) {
      return;
    }
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
      _paintResizeHandles(canvas, rect);
    } else if (selectedStrokeIds.isEmpty &&
        selectedTextIds.isEmpty &&
        selectedShapeIds.isEmpty &&
        selectedImageIds.length == 1) {
      _paintResizeHandles(canvas, rect);
    }
  }

  void _paintSelectionHandle(Canvas canvas, Offset center) {
    canvas.drawCircle(center, 5, Paint()..color = const Color(0xff5c86aa));
    canvas.drawCircle(center, 2, Paint()..color = const Color(0xfff9fbfd));
  }

  void _paintResizeHandles(Canvas canvas, Rect rect) {
    for (final point in [
      Offset(rect.left * size.width, rect.top * size.height),
      Offset(rect.right * size.width, rect.top * size.height),
      Offset(rect.left * size.width, rect.bottom * size.height),
      Offset(rect.right * size.width, rect.bottom * size.height),
    ]) {
      _paintSelectionHandle(canvas, point);
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
  bool shouldRepaint(covariant StrokePainter old) =>
      old.revision != revision ||
      old.staticRevision != staticRevision ||
      old.activeTool != activeTool ||
      old.activeColor != activeColor ||
      old.activeWidth != activeWidth ||
      old.activePenType != activePenType ||
      old.hiddenTextId != hiddenTextId;
}
