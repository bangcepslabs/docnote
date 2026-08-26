import 'dart:ui';

import 'stroke.dart';
import 'drawing_text.dart';
import 'drawing_image.dart';

enum DrawingShapeType { line, rectangle, ellipse, arrow }

/// A page-bound, editable outline object. Points use the same normalized page
/// coordinate system as [Stroke], so existing canvas scaling remains intact.
class DrawingShape {
  const DrawingShape({
    required this.id,
    required this.documentId,
    required this.pageId,
    required this.type,
    required this.startPoint,
    required this.endPoint,
    required this.color,
    required this.strokeWidth,
    this.rotationRadians = 0,
    required this.order,
    required this.createdAt,
  });

  final String id;
  final String documentId;
  final String pageId;
  final DrawingShapeType type;
  final StrokePoint startPoint;
  final StrokePoint endPoint;
  final Color color;
  final double strokeWidth;
  final double rotationRadians;
  final int order;
  final DateTime createdAt;

  DrawingShape copyWith({
    StrokePoint? startPoint,
    StrokePoint? endPoint,
    Color? color,
    double? strokeWidth,
    double? rotationRadians,
  }) =>
      DrawingShape(
        id: id,
        documentId: documentId,
        pageId: pageId,
        type: type,
        startPoint: startPoint ?? this.startPoint,
        endPoint: endPoint ?? this.endPoint,
        color: color ?? this.color,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        rotationRadians: rotationRadians ?? this.rotationRadians,
        order: order,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'documentId': documentId,
        'pageId': pageId,
        'type': type.name,
        'startPoint': startPoint.toJson(),
        'endPoint': endPoint.toJson(),
        'color': color.toARGB32(),
        'strokeWidth': strokeWidth,
        'rotationRadians': rotationRadians,
        'order': order,
        'createdAt': createdAt.toIso8601String(),
      };

  factory DrawingShape.fromJson(Map<String, dynamic> json) => DrawingShape(
        id: json['id'] as String,
        documentId: json['documentId'] as String,
        pageId: json['pageId'] as String,
        type: DrawingShapeType.values.byName(json['type'] as String),
        startPoint:
            StrokePoint.fromJson(json['startPoint'] as Map<String, dynamic>),
        endPoint:
            StrokePoint.fromJson(json['endPoint'] as Map<String, dynamic>),
        color: Color((json['color'] as num).toInt()),
        strokeWidth: (json['strokeWidth'] as num).toDouble(),
        rotationRadians: (json['rotationRadians'] as num?)?.toDouble() ?? 0,
        order: (json['order'] as num).toInt(),
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}

class DrawingPageData {
  const DrawingPageData(
      {this.strokes = const [],
      this.shapes = const [],
      this.texts = const [],
      this.images = const []});

  final List<Stroke> strokes;
  final List<DrawingShape> shapes;
  final List<DrawingText> texts;
  final List<DrawingImage> images;
}
