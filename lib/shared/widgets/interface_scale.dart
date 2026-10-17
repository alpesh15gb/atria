import 'package:flutter/material.dart';

/// Zooms the entire interface while giving responsive layouts the matching
/// logical viewport. OS text scaling remains independent and is never capped.
class InterfaceScale extends StatelessWidget {
  const InterfaceScale({super.key, required this.scale, required this.child});
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.of(context);
        final viewport = Size(
          constraints.maxWidth / scale,
          constraints.maxHeight / scale,
        );
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: viewport,
              child: MediaQuery(
                data: media.copyWith(
                  size: viewport,
                  padding: media.padding / scale,
                  viewPadding: media.viewPadding / scale,
                  viewInsets: media.viewInsets / scale,
                  systemGestureInsets: media.systemGestureInsets / scale,
                ),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}
