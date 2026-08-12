import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum DocumentType { textNote, drawingNote, pdf, hwp, hwpx }

bool _readBool(dynamic value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value.toLowerCase() == 'true' || value == '1';
  return fallback;
}

class DocumentItem {
  DocumentItem(
      {required this.id,
      required this.title,
      required this.type,
      this.body = '',
      this.favorite = false,
      this.sourcePath,
      this.internalPath,
      this.thumbnailPath,
      this.thumbnailVersion = 0,
      this.coverId,
      this.templateId = 'blank',
      List<String>? attachments,
      this.pageCount = 1,
      this.trashed = false,
      this.folderId,
      DateTime? created,
      DateTime? modified,
      this.lastOpened})
      : created = created ?? DateTime.now(),
        modified = modified ?? DateTime.now(),
        attachments = attachments ?? [];
  final String id;
  String title;
  final DocumentType type;
  String body;
  bool favorite;
  String? sourcePath;
  String? internalPath;
  String? thumbnailPath;
  int thumbnailVersion;
  String? coverId;
  String? templateId;
  List<String> attachments;
  int pageCount;
  bool trashed;
  String? folderId;
  DateTime created;
  DateTime modified;
  DateTime? lastOpened;
  /// App-created notebooks keep their editable page data in DocNote. Imported
  /// files deliberately remain a separate kind of library item.
  bool get isNotebook =>
      type == DocumentType.textNote || type == DocumentType.drawingNote;
  bool get isImportedDocument => !isNotebook;
  String get pageStyle =>
      (templateId == null || templateId!.trim().isEmpty) ? 'blank' : templateId!;
  bool get isEmpty =>
      title.trim().isEmpty &&
      body.trim().isEmpty &&
      attachments.isEmpty &&
      coverId == null;
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'type': type.name,
        'body': body,
        'favorite': favorite,
        'sourcePath': sourcePath,
        'internalPath': internalPath,
        'thumbnailPath': thumbnailPath,
        'thumbnailVersion': thumbnailVersion,
        'coverId': coverId,
        'templateId': templateId,
        'attachments': attachments,
        'pageCount': pageCount,
        'trashed': trashed,
        'folderId': folderId,
        'created': created.toIso8601String(),
        'modified': modified.toIso8601String(),
        'lastOpened': lastOpened?.toIso8601String()
      };
  factory DocumentItem.fromJson(Map<String, dynamic> json) => DocumentItem(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      type: DocumentType.values.byName(json['type'] as String),
      body: json['body'] as String? ?? '',
      favorite: _readBool(json['favorite']),
      sourcePath: json['sourcePath'] as String?,
      internalPath: json['internalPath'] as String?,
      thumbnailPath: json['thumbnailPath'] as String?,
      thumbnailVersion: (json['thumbnailVersion'] as num?)?.toInt() ?? 0,
      coverId: json['coverId'] as String?,
      templateId: json['templateId'] as String? ?? 'blank',
      attachments: (json['attachments'] as List?)?.whereType<String>().toList(),
      pageCount: (json['pageCount'] as num?)?.toInt() ?? 1,
      trashed: _readBool(json['trashed']),
      folderId: json['folderId'] as String?,
      created: DateTime.tryParse(json['created'] as String? ?? ''),
      modified: DateTime.tryParse(json['modified'] as String? ?? ''),
      lastOpened: DateTime.tryParse(json['lastOpened'] as String? ?? ''));
}

class DocumentRepository {
  static const key = 'docnote.documents';
  Future<List<DocumentItem>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((item) => DocumentItem.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.modified.compareTo(a.modified));
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<DocumentItem> documents) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        key, jsonEncode(documents.map((item) => item.toJson()).toList()));
  }
}
