import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// Swipe a row left to delete it. Same gesture/design as mars_thoughts'
/// ThoughtRow swipe: reveals an inverted red tile behind the row, arms once
/// pulled all the way to the stop (ticking a haptic), and only then does
/// releasing it act — a half-hearted swipe is always a no-op.
class SwipeToDelete extends StatefulWidget {
  final Widget child;
  final VoidCallback onDelete;

  const SwipeToDelete({super.key, required this.child, required this.onDelete});

  @override
  State<SwipeToDelete> createState() => _SwipeToDeleteState();
}

class _SwipeToDeleteState extends State<SwipeToDelete> {
  static const _maxRevealFraction = 1 / 3;
  static const _iconSize = 20.0;

  double _maxReveal = 0;
  double _drag = 0;
  bool _armed = false;

  void _onUpdate(DragUpdateDetails d) {
    final drag = (_drag + d.delta.dx).clamp(-_maxReveal, 0.0);
    final armed = _maxReveal > 0 && drag.abs() >= _maxReveal - 0.5;
    if (armed && !_armed) HapticFeedback.mediumImpact();
    setState(() {
      _drag = drag;
      _armed = armed;
    });
  }

  void _onEnd(DragEndDetails d) {
    final delete = _armed;
    setState(() {
      _drag = 0;
      _armed = false;
    });
    if (delete) widget.onDelete();
  }

  @override
  Widget build(BuildContext context) {
    final tile = Theme.of(context).scaffoldBackgroundColor;

    return LayoutBuilder(
      builder: (context, constraints) {
        _maxReveal = constraints.maxWidth * _maxRevealFraction;
        return RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: <Type, GestureRecognizerFactory>{
            _RowSwipeDragRecognizer:
                GestureRecognizerFactoryWithHandlers<_RowSwipeDragRecognizer>(
                  () => _RowSwipeDragRecognizer(),
                  (instance) => instance
                    ..onUpdate = _onUpdate
                    ..onEnd = _onEnd,
                ),
          },
          child: Stack(
            children: [
              if (_drag != 0)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: _drag.abs(),
                  child: ClipRect(
                    child: ColoredBox(
                      color: COLOR_DELETE,
                      child: OverflowBox(
                        minWidth: 0,
                        maxWidth: double.infinity,
                        child: Icon(
                          Icons.delete_outline,
                          size: _iconSize,
                          color: tile,
                        ),
                      ),
                    ),
                  ),
                ),
              Transform.translate(
                offset: Offset(_drag, 0),
                child: ColoredBox(color: tile, child: widget.child),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A horizontal-drag recognizer that only commits the row swipe once the
/// finger has moved clearly and mostly sideways. A plain [GestureDetector]'s
/// horizontal-drag handlers react to the smallest sideways wobble during an
/// otherwise vertical list scroll, which reads as jitter; this mirrors
/// mars_thoughts' `_RowSwipeDragRecognizer` instead.
class _RowSwipeDragRecognizer extends HorizontalDragGestureRecognizer {
  static const _slop = 20.0;

  Offset? _origin;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origin = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && _origin != null) {
      final delta = event.position - _origin!;
      if (delta.dx.abs() > _slop || delta.dy.abs() > _slop) {
        if (delta.dx.abs() > delta.dy.abs() * 1.5) {
          resolve(GestureDisposition.accepted);
        } else {
          resolve(GestureDisposition.rejected);
          stopTrackingPointer(event.pointer);
          return;
        }
      }
    }
    super.handleEvent(event);
  }
}
