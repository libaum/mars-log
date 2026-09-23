import 'package:flutter/material.dart';

/// A bare trend line — no axes, no grid, no labels. Scaled to its own
/// min/max so the *shape* of the change is readable even when the absolute
/// range is narrow; the number beside it carries the magnitude.
class SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;

  SparklinePainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    var min = values.first;
    var max = values.first;
    for (final value in values) {
      if (value < min) min = value;
      if (value > max) max = value;
    }
    // A flat series would divide by zero — draw it down the middle instead.
    final span = max - min;
    final stepX = size.width / (values.length - 1);

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final normalized = span == 0 ? 0.5 : (values[i] - min) / span;
      final point = Offset(i * stepX, size.height - normalized * size.height);
      i == 0 ? path.moveTo(point.dx, point.dy) : path.lineTo(point.dx, point.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(SparklinePainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}
