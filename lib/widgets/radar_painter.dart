import 'dart:math' as math;
import 'package:flutter/material.dart';

// ===================== RADAR PAINTER (MINIMAL) =====================
// As requested:
// - No static rings
// - No crosshair
// - No outer circle
// - Pulse ring stays
// - Sweep stays VERY faint (alpha 0.05)

class FullScreenRadarPainter extends CustomPainter {
  final double sweepT; // 0..1
  final double pulseT; // 0..1

  FullScreenRadarPainter({required this.sweepT, required this.pulseT});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width * 0.5, size.height * 0.42);
    final r = math.min(size.width, size.height) * 0.62;

    const base = Color(0xFF35D0FF);

    // subtle fog
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: 0.05),
    );

    // pulse ring (moving circle)
    final p = (pulseT % 1.0);
    final pulseRadius = r * (0.15 + 0.95 * p);
    final pulseOpacity = (1.0 - p) * 0.18;

    final pulsePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = base.withValues(alpha: pulseOpacity);

    canvas.drawCircle(c, pulseRadius, pulsePaint);

    // sweep sector (very faint)
    final startAngle = (sweepT * 2 * math.pi) - math.pi / 2;
    const sweepAngle = math.pi / 3.4;

    final rect = Rect.fromCircle(center: c, radius: r);

    final sweepPaint = Paint()
      ..shader = SweepGradient(
        startAngle: startAngle,
        endAngle: startAngle + sweepAngle,
        colors: [
          base.withValues(alpha: 0.00),
          base.withValues(alpha: 0.05),
          base.withValues(alpha: 0.00),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(rect)
      ..style = PaintingStyle.fill;

    canvas.drawArc(rect, startAngle, sweepAngle, true, sweepPaint);

    // center dot
    final dotPaint = Paint()..color = base.withValues(alpha: 0.22);
    canvas.drawCircle(c, 3.0, dotPaint);
  }

  @override
  bool shouldRepaint(covariant FullScreenRadarPainter oldDelegate) {
    return oldDelegate.sweepT != sweepT || oldDelegate.pulseT != pulseT;
  }
}
