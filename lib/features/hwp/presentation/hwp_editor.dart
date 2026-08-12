import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_rhwp/flutter_rhwp.dart';

class HwpEditorPage extends StatefulWidget {
  const HwpEditorPage({
    required this.documentId,
    required this.title,
    required this.path,
    super.key,
  });
  final String documentId;
  final String title;
  final String path;

  @override
  State<HwpEditorPage> createState() => _HwpEditorPageState();
}

class _HwpEditorPageState extends State<HwpEditorPage> {
  dynamic document;
  Object? error;
  bool loading = true;
  bool saving = false;
  bool dirty = false;
  String? detectedFormat;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final engineVersion = await Rhwp.version();
      developer.log('rhwp engine version=$engineVersion', name: 'docnote.hwp');
      final file = File(widget.path);
      if (!await file.exists()) {
        throw StateError('HWP 파일을 찾을 수 없습니다.');
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw const FormatException('파일이 비어 있습니다.');
      }
      final isHwp = bytes.length >= 8 &&
          bytes[0] == 0xD0 &&
          bytes[1] == 0xCF &&
          bytes[2] == 0x11 &&
          bytes[3] == 0xE0;
      final isHwpx = bytes.length >= 4 &&
          bytes[0] == 0x50 &&
          bytes[1] == 0x4B &&
          bytes[2] == 0x03 &&
          bytes[3] == 0x04;
      if (!isHwp && !isHwpx) {
        throw const FormatException('HWP/HWPX 파일 헤더가 아닙니다.');
      }
      final originalName = file.uri.pathSegments.last;
      final baseName = originalName.replaceFirst(RegExp(r'\.[^.]+$'), '');
      final parserName = '$baseName.${isHwpx ? 'hwpx' : 'hwp'}';
      detectedFormat = isHwpx ? 'HWPX' : 'HWP';
      developer.log(
          'HWP bytes loaded id=${widget.documentId} size=${bytes.length} format=${isHwpx ? 'HWPX' : 'HWP'}',
          name: 'docnote.hwp');
      document = await Rhwp.open(bytes, fileName: parserName);
    } catch (e, stack) {
      developer.log('HWP open failed id=${widget.documentId}: $e',
          name: 'docnote.hwp', error: e, stackTrace: stack);
      error = e;
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _save() async {
    if (document == null || saving) return;
    setState(() => saving = true);
    try {
      final exported = await document.exportDocument(RhwpExportFormat.hwp,
          sourceFileName: widget.title);
      final bytes = exported.bytes;
      if (bytes is Uint8List) {
        await File(widget.path).writeAsBytes(bytes, flush: true);
      } else if (bytes is List<int>) {
        await File(widget.path).writeAsBytes(bytes, flush: true);
      } else {
        throw StateError('HWP 저장 결과가 올바르지 않습니다.');
      }
      dirty = false;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('HWP 문서를 저장했습니다.')));
      }
    } catch (e, stack) {
      developer.log('HWP save failed id=${widget.documentId}: $e',
          name: 'docnote.hwp', error: e, stackTrace: stack);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('HWP 문서 저장에 실패했습니다.')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    document?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (error != null || document == null) {
      return Scaffold(
          appBar: AppBar(title: Text(widget.title)),
          body: Center(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_friendlyError(error),
                      textAlign: TextAlign.center))));
    }
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (dirty)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Center(child: Icon(Icons.circle, size: 8)),
            ),
          IconButton(
              onPressed: saving ? null : _save,
              tooltip: 'HWP 저장',
              icon: saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_outlined)),
          PopupMenuButton<String>(
            tooltip: '더보기',
            icon: const Icon(Icons.more_horiz),
            onSelected: (value) {
              if (value == 'info') {
                showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('문서 정보'),
                    content: Text(
                      '형식: ${detectedFormat ?? 'HWP'}\n경로: ${widget.path}',
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('확인'),
                      ),
                    ],
                  ),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'info', child: Text('문서 정보')),
            ],
          ),
          const SizedBox(width: 2),
        ],
      ),
      body: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: RhwpNativeEditor(
          document: document,
          convertToEditableOnLoad: true,
          onDirtyChanged: (value) {
            if (mounted) setState(() => dirty = value);
          },
        ),
      ),
    );
  }

  String _friendlyError(Object? value) {
    final message = value?.toString().toLowerCase() ?? '';
    if (message.contains('dynamiclibrary') ||
        message.contains('dlopen') ||
        message.contains('ffi') ||
        message.contains('native library') ||
        message.contains('symbol')) {
      return 'HWP 엔진을 초기화하지 못했습니다.\n'
          'Android 네이티브 라이브러리 또는 ABI 설정을 확인해 주세요.';
    }
    if (message.contains('password') ||
        message.contains('encrypted') ||
        message.contains('암호')) {
      return '암호화된 HWP 문서는 열 수 없습니다.\n암호를 해제한 뒤 다시 가져와 주세요.';
    }
    if (message.contains('empty') || message.contains('비어')) {
      return '빈 HWP 파일은 열 수 없습니다.';
    }
    if (message.contains('unsupported') || message.contains('지원')) {
      return '지원되지 않는 HWP 형식입니다.\nHWP 5.0 또는 HWPX 파일을 사용해 주세요.';
    }
    if (detectedFormat != null) {
      return '$detectedFormat 파일 헤더는 확인했지만 문서 내용을 읽지 못했습니다.\n'
          '현재 rhwp가 지원하지 않는 내부 구조이거나 암호화된 문서일 수 있습니다.';
    }
    return 'HWP 문서를 열 수 없습니다.\n파일이 손상되었거나 지원되지 않는 형식일 수 있습니다.';
  }
}
