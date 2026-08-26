import 'stroke.dart';

/// A persisted image object on a drawing page. Its bounds are normalized to
/// the paper, exactly like strokes, shapes, and text positions.
class DrawingImage {
  const DrawingImage({
    required this.id,
    required this.documentId,
    required this.pageId,
    required this.imagePath,
    required this.position,
    required this.width,
    required this.height,
    required this.order,
    required this.createdAt,
  });

  final String id;
  final String documentId;
  final String pageId;
  final String imagePath;
  final StrokePoint position;
  final double width;
  final double height;
  final int order;
  final DateTime createdAt;

  DrawingImage copyWith({StrokePoint? position, double? width, double? height}) =>
      DrawingImage(
        id: id,
        documentId: documentId,
        pageId: pageId,
        imagePath: imagePath,
        position: position ?? this.position,
        width: width ?? this.width,
        height: height ?? this.height,
        order: order,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'documentId': documentId,
        'pageId': pageId,
        'imagePath': imagePath,
        'position': position.toJson(),
        'width': width,
        'height': height,
        'order': order,
        'createdAt': createdAt.toIso8601String(),
      };

  factory DrawingImage.fromJson(Map<String, dynamic> json) => DrawingImage(
        id: json['id'] as String,
        documentId: json['documentId'] as String,
        pageId: json['pageId'] as String,
        imagePath: json['imagePath'] as String,
        position:
            StrokePoint.fromJson(json['position'] as Map<String, dynamic>),
        width: (json['width'] as num).toDouble(),
        height: (json['height'] as num).toDouble(),
        order: (json['order'] as num).toInt(),
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}
