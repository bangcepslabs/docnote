import 'package:flutter/material.dart';

/// The active document tab on wide editor layouts.
class EditorDocumentTab extends StatelessWidget {
  const EditorDocumentTab({
    required this.title,
    required this.onClose,
    this.onTitleTap,
    super.key,
  });

  final String title;
  final VoidCallback onClose;
  final VoidCallback? onTitleTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 246,
      height: 40,
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: .52),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
        border: Border(
          bottom: BorderSide(
              color: scheme.primary.withValues(alpha: .65), width: 2),
        ),
      ),
      child: Row(children: [
        const SizedBox(width: 10),
        Icon(Icons.description_outlined, size: 17, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: InkWell(
            onTap: onTitleTap,
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    )),
          ),
        ),
        IconButton(
          onPressed: onClose,
          tooltip: '문서 탭 닫기',
          icon: const Icon(Icons.close_rounded, size: 17),
          color: scheme.onSurfaceVariant,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        ),
      ]),
    );
  }
}
