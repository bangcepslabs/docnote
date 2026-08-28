import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/database/document_model.dart';

class UnifiedNoteEditor extends StatefulWidget {
  const UnifiedNoteEditor(
      {required this.document,
      required this.onSave,
      required this.onDelete,
      super.key});
  final DocumentItem document;
  final Future<void> Function(DocumentItem) onSave;
  final Future<void> Function(String) onDelete;
  @override
  State<UnifiedNoteEditor> createState() => _UnifiedNoteEditorState();
}

class _UnifiedNoteEditorState extends State<UnifiedNoteEditor>
    with WidgetsBindingObserver {
  late final TextEditingController titleController;
  late final TextEditingController bodyController;
  final bodyFocus = FocusNode();
  Timer? timer;
  String status = '저장됨';
  bool removed = false;
  bool closing = false;
  bool toolbarVisible = true;
  late final List<String> attachments;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    titleController = TextEditingController(text: widget.document.title);
    bodyController = TextEditingController(text: widget.document.body);
    attachments = widget.document.attachments;
    titleController.addListener(_changed);
    bodyController.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) bodyFocus.requestFocus();
    });
  }

  void _changed() {
    if (mounted) setState(() => status = '저장 중');
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    if (removed) return;
    widget.document.title = titleController.text.trim();
    widget.document.body = bodyController.text;
    if (widget.document.isEmpty) {
      removed = true;
      await widget.onDelete(widget.document.id);
      return;
    }
    widget.document.modified = DateTime.now();
    try {
      await widget.onSave(widget.document);
      if (mounted) setState(() => status = '저장됨');
    } catch (_) {
      if (mounted) setState(() => status = '저장 실패');
    }
  }

  Future<void> _saveNow() async {
    timer?.cancel();
    await _save();
    if (mounted && status == '저장됨') {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('메모를 저장했습니다.')));
    }
  }

  Future<void> _close() async {
    if (closing) return;
    closing = true;
    timer?.cancel();
    await _save();
    if (mounted) Navigator.pop(context);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _save();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    _save();
    WidgetsBinding.instance.removeObserver(this);
    titleController.dispose();
    bodyController.dispose();
    bodyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (_, __) {
        _close();
      },
      child: Scaffold(
          appBar: AppBar(
              leading: IconButton(
                  onPressed: _close, icon: const Icon(Icons.arrow_back)),
              title: TextField(
                controller: titleController,
                maxLines: 1,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  hintText: '제목',
                  border: InputBorder.none,
                  isDense: true,
                  hintStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              actions: [
                IconButton(
                    onPressed: _saveNow,
                    tooltip: '저장',
                    icon: const Icon(Icons.save_outlined)),
                IconButton(
                    onPressed: () =>
                        setState(() => toolbarVisible = !toolbarVisible),
                    tooltip: toolbarVisible ? '편집 도구 숨기기' : '편집 도구 열기',
                    icon: Icon(toolbarVisible
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down)),
                IconButton(
                    onPressed: () {
                      widget.document.favorite = !widget.document.favorite;
                      _save();
                      setState(() {});
                    },
                    icon: Icon(widget.document.favorite
                        ? Icons.star
                        : Icons.star_border)),
                IconButton(
                    onPressed: () => SharePlus.instance.share(ShareParams(
                        text:
                            '${titleController.text}\n${bodyController.text}')),
                    icon: const Icon(Icons.share)),
                PopupMenuButton<String>(
                    onSelected: (value) async {
                      if (value == 'delete') {
                        final navigator = Navigator.of(context);
                        await widget.onDelete(widget.document.id);
                        if (mounted) navigator.pop();
                      }
                    },
                    itemBuilder: (_) => [
                          const PopupMenuItem(
                              value: 'delete', child: Text('Delete'))
                        ])
              ]),
          body: Column(children: [
            if (toolbarVisible) _editorToolbar(),
            Expanded(child: _pageBody()),
          ])));
  Widget _textBody() {
    return Column(children: [
      if (attachments.isNotEmpty)
        SizedBox(
            height: 72,
            child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                itemCount: attachments.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, index) => ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(File(attachments[index]),
                        width: 72, height: 72, fit: BoxFit.cover)))),
      Expanded(
          child: TextField(
              controller: bodyController,
              focusNode: bodyFocus,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                  hintText: 'Write a note',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(20)))),
    ]);
  }

  Widget _pageBody() => Center(
      child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: DecoratedBox(
              decoration: const BoxDecoration(
                  color: Colors.white,
                  boxShadow: [BoxShadow(blurRadius: 8, color: Colors.black12)]),
              child: _textBody())));

  Widget _editorToolbar() {
    final items = <Widget>[
      IconButton(
          onPressed: () {
            bodyController.text +=
                '${bodyController.text.isEmpty ? '' : '\n'}\u2610 ';
            bodyController.selection =
                TextSelection.collapsed(offset: bodyController.text.length);
            _changed();
          },
          tooltip: '체크리스트 항목 추가',
          icon: const Icon(Icons.check_box_outlined)),
      IconButton(
          onPressed: _attachImage,
          tooltip: '이미지 첨부',
          icon: const Icon(Icons.image_outlined)),
      IconButton(
          onPressed: () => bodyFocus.unfocus(),
          tooltip: '키보드 닫기',
          icon: const Icon(Icons.keyboard_hide)),
    ];
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outlineVariant))),
        child: SizedBox(
          height: 54,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(children: [
              for (var index = 0; index < items.length; index++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Semantics(
                    button: true,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(11)),
                      child: items[index],
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _attachImage() async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        withData: true);
    if (result == null) return;
    final picked = result.files.single;
    final root = await getApplicationDocumentsDirectory();
    final directory =
        Directory('${root.path}/documents/${widget.document.id}/attachments');
    await directory.create(recursive: true);
    final extension = picked.extension ?? 'png';
    final target = File(
        '${directory.path}/${DateTime.now().microsecondsSinceEpoch}.$extension');
    if (picked.path != null) {
      await File(picked.path!).copy(target.path);
    } else if (picked.bytes != null) {
      await target.writeAsBytes(picked.bytes!, flush: true);
    } else {
      return;
    }
    attachments.add(target.path);
    _changed();
    if (mounted) setState(() {});
  }
}
