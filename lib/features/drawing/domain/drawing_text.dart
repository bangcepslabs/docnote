import 'dart:ui';

import 'stroke.dart';

class DrawingText {
  const DrawingText({
    required this.id,
    required this.documentId,
    required this.pageId,
    required this.text,
    required this.position,
    required this.fontSize,
    required this.color,
    required this.maxWidth,
    required this.order,
    required this.createdAt,
    this.bold = false,
    this.alignment = 'left',
  });

  final String id;
  final String documentId;
  final String pageId;
  final String text;
  final StrokePoint position;
  final double fontSize;
  final Color color;
  final double maxWidth;
  final int order;
  final DateTime createdAt;
  final bool bold;
  final String alignment;

  DrawingText copyWith({
    String? text,
    StrokePoint? position,
    double? fontSize,
    Color? color,
    double? maxWidth,
    bool? bold,
    String? alignment,
  }) =>
      DrawingText(
        id: id,
        documentId: documentId,
        pageId: pageId,
        text: text ?? this.text,
        position: position ?? this.position,
        fontSize: fontSize ?? this.fontSize,
        color: color ?? this.color,
        maxWidth: maxWidth ?? this.maxWidth,
        order: order,
        createdAt: createdAt,
        bold: bold ?? this.bold,
        alignment: alignment ?? this.alignment,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'documentId': documentId,
        'pageId': pageId,
        'text': text,
        'position': position.toJson(),
        'fontSize': fontSize,
        'color': color.toARGB32(),
        'maxWidth': maxWidth,
        'order': order,
        'createdAt': createdAt.toIso8601String(),
        'bold': bold,
        'alignment': alignment,
      };

  factory DrawingText.fromJson(Map<String, dynamic> json) => DrawingText(
        id: json['id'] as String,
        documentId: json['documentId'] as String,
        pageId: json['pageId'] as String,
        text: json['text'] as String,
        position:
            StrokePoint.fromJson(json['position'] as Map<String, dynamic>),
        fontSize: (json['fontSize'] as num).toDouble(),
        color: Color((json['color'] as num).toInt()),
        maxWidth: (json['maxWidth'] as num).toDouble(),
        order: (json['order'] as num).toInt(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        bold: json['bold'] as bool? ?? false,
        alignment: json['alignment'] as String? ?? 'left',
      );
}
