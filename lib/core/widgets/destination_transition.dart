import 'package:flutter/material.dart';

/// A quiet entrance for retained navigation pages, without moving the canvas
/// or mounting a second copy of either destination.
class DestinationTransition extends StatefulWidget {
  const DestinationTransition({
    required this.selectedIndex,
    required this.child,
    super.key,
  });

  final int selectedIndex;
  final Widget child;

  @override
  State<DestinationTransition> createState() => _DestinationTransitionState();
}

class _DestinationTransitionState extends State<DestinationTransition>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
    value: 1,
  );
  late final _opacity = _controller
      .drive(
        CurveTween(curve: Curves.easeOutCubic),
      )
      .drive(Tween<double>(begin: .88, end: 1));
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _controller.value = 1;
  }

  @override
  void didUpdateWidget(covariant DestinationTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex == widget.selectedIndex) return;
    if (_reduceMotion) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _opacity,
        child: widget.child,
      );
}
