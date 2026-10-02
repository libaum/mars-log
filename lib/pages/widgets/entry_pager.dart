import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Builds a page; its vertical list must use [list] as controller.
typedef EntryPageBuilder = Widget Function(BuildContext context, int index, ScrollController list);

/// A horizontal pager over entries whose pages scroll vertically, tuned so
/// the two never fight:
///
/// - **Axis lock:** the first few pixels of a touch decide. Unless the drag
///   is clearly horizontal (|dx| ≥ 2·|dy|), the pager is off for it, so a
///   slightly diagonal scroll never wobbles sideways.
/// - **A touch during the snap:** after a swipe a PageView snaps with a
///   ballistic activity, and while that runs its Scrollable lays an
///   IgnorePointer over the pages — a finger put down right away reaches
///   only the pager's drag, which stops the snap and wobbles sideways, and
///   the page's list never sees the touch. So the snap is driven here
///   instead (jumpTo frames, see [_onScroll]), and a touch during it lands
///   the page at once and is handed to the new page: a vertical drag scrolls
///   its list, a horizontal one swipes on — through the positions' own
///   drag(), so both feel exactly like a normal drag, fling included.
class EntryPager extends StatefulWidget {
  final PageController controller;
  final int itemCount;
  final ValueChanged<int> onPageChanged;
  final EntryPageBuilder itemBuilder;

  /// Identifies page [index] across changes to the list — its list's
  /// scroll position is kept by it.
  final Object Function(int index) pageKey;
  final ChildIndexGetter? findChildIndexCallback;

  const EntryPager({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.onPageChanged,
    required this.itemBuilder,
    required this.pageKey,
    this.findChildIndexCallback,
  });

  @override
  State<EntryPager> createState() => _EntryPagerState();
}

class _EntryPagerState extends State<EntryPager> with SingleTickerProviderStateMixin {
  // Axis lock for the current touch: vertical drags disable the pager.
  final _locked = ValueNotifier<bool>(false);
  Offset _touchDelta = Offset.zero;

  final _lists = <Object, ScrollController>{};
  ScrollController _listOf(int index) =>
      _lists.putIfAbsent(widget.pageKey(index), ScrollController.new);

  late final _snap = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  double _snapFrom = 0;
  double _snapTo = 0;

  /// The page the running snap goes to; null when none runs. While set, the
  /// pages take no touches — [_onPointerDown] hands them over instead.
  int? _snapPage;

  // A finger just left after moving the pager; its snap is about to start.
  bool _released = false;

  // A touch that came during a snap, now driving the new page's list or
  // the pager.
  late final _vertical = VerticalDragGestureRecognizer(debugOwner: this)
    ..onStart = _startDrag(() => _listOf(_page).position)
    ..onUpdate = _updateDrag
    ..onEnd = _endDrag
    ..onCancel = _cancelDrag;
  late final _horizontal = HorizontalDragGestureRecognizer(debugOwner: this)
    ..onStart = _startDrag(() => widget.controller.position)
    ..onUpdate = _updateDrag
    ..onEnd = _endDrag
    ..onCancel = _cancelDrag;
  Drag? _drag;

  int get _page => widget.controller.page?.round() ?? widget.controller.initialPage;

  @override
  void initState() {
    super.initState();
    _snap.addListener(() {
      final controller = widget.controller;
      if (!controller.hasClients) return;
      final t = Curves.easeOutCubic.transform(_snap.value);
      controller.jumpTo(_snapFrom + (_snapTo - _snapFrom) * t);
    });
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    _snap.dispose();
    _locked.dispose();
    for (final c in _lists.values) {
      c.dispose();
    }
    super.dispose();
  }

  GestureDragStartCallback _startDrag(ScrollPosition Function() position) => (details) {
        final p = position();
        _drag = p.drag(details, () => _drag = null);
      };

  void _updateDrag(DragUpdateDetails d) => _drag?.update(d);
  void _endDrag(DragEndDetails d) => _drag?.end(d);
  void _cancelDrag() => _drag?.cancel();

  void _onPointerDown(PointerDownEvent event) {
    _touchDelta = Offset.zero;
    _locked.value = false;
    _released = false;
    final page = _snapPage;
    if (page == null) return;
    // Mid-snap: the pages didn't get this touch (see [_HitGate]); land the
    // page and let the touch drive it.
    _snap.stop();
    _snapPage = null;
    widget.controller.jumpToPage(page);
    _vertical.addPointer(event);
    _horizontal.addPointer(event);
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_locked.value) return;
    _touchDelta += e.delta;
    if (_touchDelta.distance > 6 && _touchDelta.dx.abs() < _touchDelta.dy.abs() * 2) {
      _locked.value = true;
    }
  }

  /// At the pager's first ballistic step after the finger left, its
  /// direction tells the target page; [_snap] takes it there with jumpTo —
  /// an idle activity, which keeps the pages out of IgnorePointer.
  bool _onScroll(ScrollNotification n) {
    // Only the pager's own notifications; the pages' lists bubble up too.
    if (n.depth != 0 || n.metrics.axis != Axis.horizontal) return false;
    if (!_released || _snapPage != null) return false;
    if (n is! ScrollUpdateNotification || n.dragDetails != null) return false;
    final delta = n.scrollDelta ?? 0;
    final controller = widget.controller;
    if (delta == 0 || !controller.hasClients) return false;
    _released = false;
    final position = controller.position;
    final width = position.viewportDimension;
    if (width <= 0) return false;
    final page = position.pixels / width;
    final target = (delta > 0 ? page.ceil() : page.floor())
        .clamp(0, (position.maxScrollExtent / width).round());
    _snapPage = target;
    _snapTo = target * width;
    // Not inside the notification: the position is mid-update.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _snapPage != target) return;
      if (!controller.hasClients) {
        _snapPage = null;
        return;
      }
      _snapFrom = controller.position.pixels;
      _snap.forward(from: 0).whenCompleteOrCancel(() {
        if (_snapPage == target) _snapPage = null;
      });
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (_) => _released = true,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: _HitGate(
          closed: () => _snapPage != null,
          child: ValueListenableBuilder<bool>(
            valueListenable: _locked,
            builder: (context, locked, _) => PageView.builder(
              physics: locked ? const NeverScrollableScrollPhysics() : null,
              controller: widget.controller,
              itemCount: widget.itemCount,
              onPageChanged: widget.onPageChanged,
              findChildIndexCallback: widget.findChildIndexCallback,
              itemBuilder: (context, i) => widget.itemBuilder(context, i, _listOf(i)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Like AbsorbPointer, but asks at every hit test — a snap can start and
/// end between frames, and a touch must see its state as it is right then.
class _HitGate extends SingleChildRenderObjectWidget {
  final bool Function() closed;
  const _HitGate({required this.closed, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHitGate(closed);

  @override
  void updateRenderObject(BuildContext context, _RenderHitGate renderObject) =>
      renderObject.closed = closed;
}

class _RenderHitGate extends RenderProxyBox {
  bool Function() closed;
  _RenderHitGate(this.closed);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      closed() ? size.contains(position) : super.hitTest(result, position: position);
}
