import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import '../database/document_model.dart';

/// Portable, local-first backup format. It deliberately contains no absolute
/// paths so an archive can be restored on another device.
class BackupService {
  const BackupService();
  static const _manifestName = 'manifest.json';
  static const _formatVersion = 1;

  Future<File> createBackup(List<DocumentItem> documents) async {
    final root = await getApplicationDocumentsDirectory();
    final archive = Archive();
    archive.addFile(ArchiveFile.string(
      _manifestName,
      jsonEncode({
        'format': 'docnote-backup',
        'version': _formatVersion,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'documents': documents
            .map((document) => _portableDocumentJson(document, root.path))
            .toList(),
      }),
    ));
    final documentsRoot = Directory('${root.path}/documents');
    if (await documentsRoot.exists()) {
      await for (final entity in documentsRoot.list(recursive: true)) {
        if (entity is! File) continue;
        final relative = _relativePath(documentsRoot.path, entity.path);
        archive.addFile(ArchiveFile(
          'files/$relative',
          await entity.length(),
          await entity.readAsBytes(),
        ));
      }
    }
    final bytes = ZipEncoder().encode(archive);
    final backupDir = Directory('${root.path}/backups');
    await backupDir.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final file = File('${backupDir.path}/DocNote-$stamp.docnote');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<List<DocumentItem>> restoreBackup(File backup,
      {bool writeFiles = true, Set<String>? documentIds}) async {
    final bytes = await backup.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final manifestFile = archive.findFile(_manifestName);
    if (manifestFile == null) throw const FormatException('DocNote 백업 manifest가 없습니다.');
    final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>));
    if (manifest is! Map || manifest['format'] != 'docnote-backup') {
      throw const FormatException('DocNote 백업 형식이 올바르지 않습니다.');
    }
    final version = (manifest['version'] as num?)?.toInt();
    if (version != _formatVersion) {
      throw FormatException('지원하지 않는 백업 버전입니다: $version');
    }
    final root = await getApplicationDocumentsDirectory();
    if (writeFiles) {
      for (final entry in archive) {
        if (!entry.isFile || !entry.name.startsWith('files/')) continue;
        final relative = entry.name.substring('files/'.length);
        if (!_isSafeRelativePath(relative)) continue;
        if (documentIds != null &&
            (relative.split('/').isEmpty ||
                !documentIds.contains(relative.split('/').first))) {
          continue;
        }
        final target = File('${root.path}/documents/$relative');
        await target.parent.create(recursive: true);
        await target.writeAsBytes(entry.content as List<int>, flush: true);
      }
    }
    final rawDocuments = manifest['documents'];
    if (rawDocuments is! List) {
      throw const FormatException('백업 문서 목록이 없습니다.');
    }
    return rawDocuments
        .whereType<Map>()
        .map((json) => _restoreDocument(
            DocumentItem.fromJson(Map<String, dynamic>.from(json)), root.path))
        .where((document) =>
            documentIds == null || documentIds.contains(document.id))
        .toList();
  }

  Map<String, dynamic> _portableDocumentJson(DocumentItem document, String root) {
    final json = document.toJson();
    for (final key in ['sourcePath', 'internalPath', 'thumbnailPath']) {
      final value = json[key];
      if (value is String) json[key] = _toPortablePath(value, root);
    }
    final attachments = json['attachments'];
    if (attachments is List) {
      json['attachments'] = attachments
          .whereType<String>()
          .map((path) => _toPortablePath(path, root))
          .toList();
    }
    return json;
  }

  DocumentItem _restoreDocument(DocumentItem document, String root) {
    document.sourcePath = _fromPortablePath(document.sourcePath, root);
    document.internalPath = _fromPortablePath(document.internalPath, root);
    document.thumbnailPath = _fromPortablePath(document.thumbnailPath, root);
    document.attachments = document.attachments
        .map((path) => _fromPortablePath(path, root) ?? path)
        .toList();
    return document;
  }

  String? _fromPortablePath(String? value, String root) {
    if (value == null || value.isEmpty) return value;
    final normalized = value.replaceAll('\\', '/');
    if (!_isSafeRelativePath(normalized)) return null;
    return '$root/$normalized'.replaceAll('/', Platform.pathSeparator);
  }

  String _toPortablePath(String value, String root) {
    final normalizedRoot = root.replaceAll('\\', '/').replaceFirst(RegExp(r'/*$'), '');
    final normalized = value.replaceAll('\\', '/');
    if (normalized == normalizedRoot || normalized.startsWith('$normalizedRoot/')) {
      return normalized.substring(normalizedRoot.length + 1);
    }
    // A stale path from an older install is not portable. Keep only its
    // basename so restore can still point to the archived document copy.
    return normalized.split('/').last;
  }

  String _relativePath(String root, String path) {
    final normalizedRoot = root.replaceAll('\\', '/').replaceFirst(RegExp(r'/*$'), '');
    return path.replaceAll('\\', '/').replaceFirst('$normalizedRoot/', '');
  }

  bool _isSafeRelativePath(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.isNotEmpty &&
        !normalized.startsWith('/') &&
        !normalized.split('/').contains('..');
  }
}
