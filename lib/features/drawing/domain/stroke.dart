import 'dart:ui';

enum StrokeTool {
  pen,
  highlighter,
  eraser,
  shapeLine,
  shapeRectangle,
  shapeEllipse,
  shapeArrow,
  text,
  image,
  lasso,
}

enum PenType { ballpoint, fountain, pencil, marker }

class StrokePoint {
  const StrokePoint(this.x, this.y, this.pressure);
  final double x;
  final double y;
  final double pressure;
  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'pressure': pressure};
  factory StrokePoint.fromJson(Map<String, dynamic> json) => StrokePoint(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
        (json['pressure'] as num?)?.toDouble() ?? 1,
      );
}

class Stroke {
  const Stroke({
    required this.id,
    required this.documentId,
    required this.pageId,
    required this.tool,
    this.penType = PenType.ballpoint,
    required this.points,
    required this.color,
    required this.width,
    required this.opacity,
    required this.order,
    required this.createdAt,
  });
  final String id;
  final String documentId;
  final String pageId;
  final StrokeTool tool;
  final PenType penType;
  final List<StrokePoint> points;
  final Color color;
  final double width;
  final double opacity;
  final int order;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'documentId': documentId,
        'pageId': pageId,
        'tool': tool.name,
        'penType': penType.name,
        'points': points.map((point) => point.toJson()).toList(),
        'color': color.toARGB32(),
        'width': width,
        'opacity': opacity,
        'order': order,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Stroke.fromJson(Map<String, dynamic> json) => Stroke(
        id: json['id'] as String,
        documentId: json['documentId'] as String,
        pageId: json['pageId'] as String,
        tool: StrokeTool.values.byName(json['tool'] as String),
        penType:
            PenType.values.byName(json['penType'] as String? ?? 'ballpoint'),
        points: (json['points'] as List)
            .map((point) => StrokePoint.fromJson(point as Map<String, dynamic>))
            .toList(),
        color: Color((json['color'] as num).toInt()),
        width: (json['width'] as num).toDouble(),
        opacity: (json['opacity'] as num).toDouble(),
        order: (json['order'] as num).toInt(),
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}

StrokePoint normalizePoint(Offset point, Size pageSize,
        {double pressure = 1}) =>
    StrokePoint(
      (point.dx / pageSize.width).clamp(0.0, 1.0),
      (point.dy / pageSize.height).clamp(0.0, 1.0),
      pressure.clamp(0.0, 1.0),
    );

Offset restorePoint(StrokePoint point, Size pageSize) =>
    Offset(point.x * pageSize.width, point.y * pageSize.height);
