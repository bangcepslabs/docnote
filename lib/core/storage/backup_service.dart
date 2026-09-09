import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/document_model.dart';

/// Portable, local-first backup format. It deliberately contains no absolute
/// paths so an archive can be restored on another device.
class BackupService {
  const BackupService();
  static const _manifestName = 'manifest.json';
  static const _formatVersion = 1;
  static const maxRetainedBackups = 5;

  Future<File> createBackup(List<DocumentItem> documents) async {
    final root = await getApplicationDocumentsDirectory();
    final fileHashes = <String, String>{};
    final prefs = await SharedPreferences.getInstance();
    final rotations = <String, int>{};
    for (final document in documents) {
      for (var page = 1; page <= document.pageCount; page++) {
        final key = 'docnote.pageRotation.${document.id}.page_$page';
        final value = prefs.getInt(key);
        if (value != null && value != 0) {
          rotations['${document.id}/page_$page'] = value;
        }
      }
    }
    final documentsRoot = Directory('${root.path}/documents');
    if (await documentsRoot.exists()) {
      await for (final entity in documentsRoot.list(recursive: true)) {
        if (entity is! File) continue;
        final relative = _relativePath(documentsRoot.path, entity.path);
        fileHashes[relative] = await _hashFile(entity);
      }
    }
    final manifest = jsonEncode({
      'format': 'docnote-backup',
      'version': _formatVersion,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'documents': documents
          .map((document) => _portableDocumentJson(document, root.path))
          .toList(),
      'files': fileHashes,
      'pageRotations': rotations,
    });
    final backupDir = Directory('${root.path}/backups');
    await backupDir.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final file = File('${backupDir.path}/DocNote-$stamp.docnote');
    final encoder = ZipFileEncoder();
    encoder.create(file.path);
    encoder.addArchiveFile(ArchiveFile.string(_manifestName, manifest));
    if (await documentsRoot.exists()) {
      await for (final entity in documentsRoot.list(recursive: true)) {
        if (entity is! File) continue;
        final relative = _relativePath(documentsRoot.path, entity.path);
        await encoder.addFile(entity, 'files/$relative');
      }
    }
    await encoder.close();
    await _pruneBackups(backupDir);
    return file;
  }

  Future<void> _pruneBackups(Directory backupDir) async {
    final backups = (await backupDir
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.docnote'))
        .cast<File>()
        .toList())
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final oldBackup in backups.skip(maxRetainedBackups)) {
      await oldBackup.delete();
    }
  }

  Future<String> _hashFile(File file) async {
    final digestCompleter = Completer<Digest>();
    final sink = sha256.startChunkedConversion(_DigestSink(digestCompleter));
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    return (await digestCompleter.future).toString();
  }

  Future<List<DocumentItem>> restoreBackup(File backup,
      {bool writeFiles = true, Set<String>? documentIds}) async {
    // Decode from a file stream instead of readAsBytes(). Large backups can
    // contain several PDFs/attachments and holding the complete archive (and
    // its decoded copy) in memory causes an avoidable OOM on mobile devices.
    final input = InputFileStream(backup.path);
    final archive = ZipDecoder().decodeStream(input);
    Directory? staging;
    var committed = false;
    try {
      final manifestFile = archive.findFile(_manifestName);
      if (manifestFile == null) {
        throw const FormatException('DocNote 백업 manifest가 없습니다.');
      }
      final manifest =
          jsonDecode(utf8.decode(manifestFile.content as List<int>));
      if (manifest is! Map || manifest['format'] != 'docnote-backup') {
        throw const FormatException('DocNote 백업 형식이 올바르지 않습니다.');
      }
      final version = (manifest['version'] as num?)?.toInt();
      if (version != _formatVersion) {
        throw FormatException('지원하지 않는 백업 버전입니다: $version');
      }
      final root = await getApplicationDocumentsDirectory();
      staging = writeFiles
          ? Directory(
              '${root.path}/.restore_${DateTime.now().microsecondsSinceEpoch}')
          : null;
      if (staging != null) await staging.create(recursive: true);
      final expectedHashes = (manifest['files'] as Map?)?.map(
              (key, value) => MapEntry(key.toString(), value.toString())) ??
          const <String, String>{};
      for (final entry in archive) {
        if (!entry.isFile || !entry.name.startsWith('files/')) continue;
        final relative = entry.name.substring('files/'.length);
        if (!_isSafeRelativePath(relative)) continue;
        if (documentIds != null &&
            (relative.split('/').isEmpty ||
                !documentIds.contains(relative.split('/').first))) {
          continue;
        }
        final content = entry.content as List<int>;
        final expected = expectedHashes[relative];
        if (expected != null &&
            sha256.convert(content).toString() != expected) {
          throw const FormatException('백업 파일 무결성 검증에 실패했습니다.');
        }
        if (!writeFiles) continue;
        final target = File('${staging!.path}/$relative');
        await target.parent.create(recursive: true);
        await target.writeAsBytes(content, flush: true);
      }
      final rawDocuments = manifest['documents'];
      if (rawDocuments is! List) {
        throw const FormatException('백업 문서 목록이 없습니다.');
      }
      if (writeFiles) {
        // All entries and hashes have been validated in the staging folder.
        // Commit only after the manifest has also been validated, so a failed
        // restore never leaves a partially written document tree behind.
        final destination = Directory('${root.path}/documents');
        await destination.create(recursive: true);
        await for (final entity in staging!.list(recursive: true)) {
          if (entity is! File) continue;
          final relative = _relativePath(staging.path, entity.path);
          final target = File('${destination.path}/$relative');
          if (await target.exists()) await target.delete();
          await target.parent.create(recursive: true);
          await entity.rename(target.path);
        }
        await staging.delete(recursive: true);
        staging = null;
        committed = true;
        final rotations = (manifest['pageRotations'] as Map?)?.map(
                (key, value) =>
                    MapEntry(key.toString(), (value as num).toInt())) ??
            const <String, int>{};
        final prefs = await SharedPreferences.getInstance();
        for (final entry in rotations.entries) {
          final parts = entry.key.split('/');
          if (parts.length != 2 ||
              (documentIds != null && !documentIds.contains(parts.first))) {
            continue;
          }
          await prefs.setInt(
              'docnote.pageRotation.${parts.first}.${parts.last}', entry.value);
        }
      }
      return rawDocuments
          .whereType<Map>()
          .map((json) => _restoreDocument(
              DocumentItem.fromJson(Map<String, dynamic>.from(json)),
              root.path))
          .where((document) =>
              documentIds == null || documentIds.contains(document.id))
          .toList();
    } finally {
      await input.close();
      final pending = staging;
      if (pending != null && !committed && await pending.exists()) {
        await pending.delete(recursive: true);
      }
    }
  }

  Map<String, dynamic> _portableDocumentJson(
      DocumentItem document, String root) {
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
    final normalizedRoot =
        root.replaceAll('\\', '/').replaceFirst(RegExp(r'/*$'), '');
    final normalized = value.replaceAll('\\', '/');
    if (normalized == normalizedRoot ||
        normalized.startsWith('$normalizedRoot/')) {
      return normalized.substring(normalizedRoot.length + 1);
    }
    // A stale path from an older install is not portable. Keep only its
    // basename so restore can still point to the archived document copy.
    return normalized.split('/').last;
  }

  String _relativePath(String root, String path) {
    final normalizedRoot =
        root.replaceAll('\\', '/').replaceFirst(RegExp(r'/*$'), '');
    return path.replaceAll('\\', '/').replaceFirst('$normalizedRoot/', '');
  }

  bool _isSafeRelativePath(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.isNotEmpty &&
        !normalized.startsWith('/') &&
        !normalized.split('/').contains('..');
  }
}

class _DigestSink implements Sink<Digest> {
  _DigestSink(this.completer);
  final Completer<Digest> completer;

  @override
  void add(Digest value) {
    if (!completer.isCompleted) completer.complete(value);
  }

  @override
  void close() {}
}
