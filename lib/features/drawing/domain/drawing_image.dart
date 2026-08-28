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
      this.rotationRadians = 0,
      this.cropLeft = 0,
      this.cropTop = 0,
      this.cropRight = 1,
      this.cropBottom = 1,
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
  final double rotationRadians;
  final double cropLeft;
  final double cropTop;
  final double cropRight;
  final double cropBottom;
  final int order;
  final DateTime createdAt;

  DrawingImage copyWith({StrokePoint? position, double? width, double? height, double? rotationRadians, double? cropLeft, double? cropTop, double? cropRight, double? cropBottom}) =>
      DrawingImage(
        id: id,
        documentId: documentId,
        pageId: pageId,
        imagePath: imagePath,
        position: position ?? this.position,
        width: width ?? this.width,
        height: height ?? this.height,
        rotationRadians: rotationRadians ?? this.rotationRadians,
        cropLeft: cropLeft ?? this.cropLeft,
        cropTop: cropTop ?? this.cropTop,
        cropRight: cropRight ?? this.cropRight,
        cropBottom: cropBottom ?? this.cropBottom,
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
        'rotationRadians': rotationRadians,
        'cropLeft': cropLeft,
        'cropTop': cropTop,
        'cropRight': cropRight,
        'cropBottom': cropBottom,
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
        rotationRadians: (json['rotationRadians'] as num?)?.toDouble() ?? 0,
        cropLeft: (json['cropLeft'] as num?)?.toDouble() ?? 0,
        cropTop: (json['cropTop'] as num?)?.toDouble() ?? 0,
        cropRight: (json['cropRight'] as num?)?.toDouble() ?? 1,
        cropBottom: (json['cropBottom'] as num?)?.toDouble() ?? 1,
        order: (json['order'] as num).toInt(),
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}
