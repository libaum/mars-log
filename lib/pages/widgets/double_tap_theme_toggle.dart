import 'package:flutter/material.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_manager.dart';

/// Double-tap anywhere to switch the theme (Mars pattern).
///
/// Listens on raw pointers so the gesture works on top of anything below,
/// but only counts a pointer as a *tap*: one finger, released quickly and
/// without travelling. Otherwise two flicks of a list scroll in quick
/// succession read as a double tap and flip the theme mid-scroll.
class DoubleTapThemeToggle extends StatefulWidget {
  final Widget child;
  const DoubleTapThemeToggle({super.key, required this.child});

  @override
  State<DoubleTapThemeToggle> createState() => _DoubleTapThemeToggleState();
}

class _DoubleTapThemeToggleState extends State<DoubleTapThemeToggle> {
  static const _tapSlop = 12.0;
  static const _tapDuration = Duration(milliseconds: 300);
  static const _doubleTapGap = Duration(milliseconds: 350);
  static const _doubleTapDistance = 60.0;

  final _themeManager = getIt<ThemeManager>();

  int? _pointer;
  Offset? _downPosition;
  DateTime? _downTime;
  bool _moved = false;

  DateTime? _lastTapTime;
  Offset? _lastTapPosition;

  void _onPointerDown(PointerDownEvent event) {
    if (_pointer != null) {
      // A second finger — not a tap; drop the whole sequence.
      _pointer = null;
      _lastTapTime = null;
      return;
    }
    _pointer = event.pointer;
    _downPosition = event.position;
    _downTime = DateTime.now();
    _moved = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _moved) return;
    if ((event.position - _downPosition!).distance > _tapSlop) _moved = true;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final down = _downTime;
    _pointer = null;
    if (_moved || down == null) {
      _lastTapTime = null;
      return;
    }
    final now = DateTime.now();
    if (now.difference(down) > _tapDuration) {
      _lastTapTime = null;
      return;
    }

    final last = _lastTapTime;
    if (last != null &&
        now.difference(last) < _doubleTapGap &&
        (event.position - _lastTapPosition!).distance < _doubleTapDistance) {
      _themeManager.toggleTheme();
      _lastTapTime = null;
      return;
    }
    _lastTapTime = now;
    _lastTapPosition = event.position;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _lastTapTime = null;
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: widget.child,
      );
}
