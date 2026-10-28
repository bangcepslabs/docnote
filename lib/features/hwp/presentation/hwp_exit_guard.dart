import 'package:flutter/material.dart';

/// Used on both a normal editor route and a workspace's nested root route.
class HwpExitGuard extends StatefulWidget {
  const HwpExitGuard(
      {required this.dirty,
      required this.saving,
      required this.onSave,
      required this.child,
      super.key});
  final bool dirty;
  final bool saving;
  final Future<bool> Function() onSave;
  final Widget child;

  @override
  State<HwpExitGuard> createState() => _HwpExitGuardState();
}

class _HwpExitGuardState extends State<HwpExitGuard> {
  bool _closing = false;

  Future<void> _requestClose() async {
    if (_closing || widget.saving) return;
    _closing = true;
    try {
      if (widget.dirty) {
        final route = DialogRoute<String>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            scrollable: true,
            title: const Text('변경 내용을 저장할까요?'),
            content: const Text('저장하지 않고 닫으면 마지막 저장 이후의 편집 내용이 사라집니다.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, 'cancel'),
                  child: const Text('계속 편집')),
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, 'discard'),
                  child: const Text('저장하지 않고 닫기')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, 'save'),
                  child: const Text('저장 후 닫기')),
            ],
          ),
        );
        final choice =
            await Navigator.of(context, rootNavigator: true).push(route);
        await route.completed;
        if (!mounted || choice == null || choice == 'cancel') return;
        if (choice == 'save' && !await widget.onSave()) return;
      }
      if (mounted) Navigator.of(context).pop();
    } finally {
      _closing = false;
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        // Also intercept maybePop on the first route of a nested tab navigator.
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _requestClose();
        },
        child: widget.child,
      );
}
