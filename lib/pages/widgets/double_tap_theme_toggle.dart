import 'package:flutter/material.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_manager.dart';

class DoubleTapThemeToggle extends StatefulWidget {
  final Widget child;
  const DoubleTapThemeToggle({super.key, required this.child});

  @override
  State<DoubleTapThemeToggle> createState() => _DoubleTapThemeToggleState();
}

class _DoubleTapThemeToggleState extends State<DoubleTapThemeToggle> {
  final _themeManager = getIt<ThemeManager>();
  DateTime? _lastTapTime;

  void _onPointerDown(PointerDownEvent event) {
    final now = DateTime.now();
    if (_lastTapTime != null &&
        now.difference(_lastTapTime!) < const Duration(milliseconds: 350)) {
      _themeManager.toggleTheme();
      _lastTapTime = null;
    } else {
      _lastTapTime = now;
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointerDown,
        child: widget.child,
      );
}
