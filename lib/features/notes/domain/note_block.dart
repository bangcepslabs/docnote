enum NoteBlockType { text, checklist, divider, image }

class NoteBlock {
  NoteBlock({
    required this.id,
    required this.type,
    this.text = '',
    this.checked = false,
    this.imagePath,
  });

  final String id;
  final NoteBlockType type;
  String text;
  bool checked;
  String? imagePath;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'text': text,
        'checked': checked,
        'imagePath': imagePath,
      };

  factory NoteBlock.fromJson(Map<String, dynamic> json) => NoteBlock(
        id: json['id'] as String,
        type: NoteBlockType.values.byName(json['type'] as String),
        text: json['text'] as String? ?? '',
        checked: json['checked'] as bool? ?? false,
        imagePath: json['imagePath'] as String?,
      );
}
