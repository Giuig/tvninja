import 'package:flutter/material.dart';

/// Tracks modal route depth so the web video iframe can be hidden
/// whenever a dialog or bottom sheet is on screen.
class OverlayObserver extends NavigatorObserver {
  final void Function(bool hasOverlay) onOverlayChanged;

  int _modalDepth = 0;

  OverlayObserver({required this.onOverlayChanged});

  void _update(int delta) {
    _modalDepth += delta;
    onOverlayChanged(_modalDepth > 0);
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    if (route is PopupRoute) _update(1);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    if (route is PopupRoute) _update(-1);
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    if (route is PopupRoute) _update(-1);
  }
}
