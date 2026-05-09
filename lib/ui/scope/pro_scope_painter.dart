import 'dart:math';
import 'package:flutter/material.dart';
import '../../ring_buffer.dart';

class ProScopePainter extends CustomPainter {
  final Map<int, RingBuffer> allPoints;
  final List<int> ids;
  final List<Color> colors;

  final double scaleX;
  final double scaleY;
  final double offsetX;
  final double offsetY;

  final double? cursorX;

  final double yAxisWidth;
  final double xAxisHeight;
  final double deltaTime;

  // 矩形框选
  final Offset? rectStart;
  final Offset? rectEnd;

  ProScopePainter({
    required this.allPoints,
    required this.ids,
    required this.colors,
    required this.scaleX,
    required this.scaleY,
    required this.offsetX,
    required this.offsetY,
    this.cursorX,
    required this.yAxisWidth,
    required this.xAxisHeight,
    required this.deltaTime,
    this.rectStart,
    this.rectEnd,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final chartRect = Rect.fromLTWH(
      yAxisWidth, 0, size.width - yAxisWidth, size.height - xAxisHeight,
    );

    _drawGrid(canvas, size, chartRect);

    canvas.save();
    canvas.clipRect(chartRect);

    // 绘制波形
    for (int i = 0; i < ids.length; i++) {
      final id = ids[i];
      final points = allPoints[id];
      if (points == null || points.length == 0) continue;

      final paint = Paint()
        ..color = colors[i % colors.length]
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      final path = Path();
      bool isFirst = true;

      int startIndex = ((chartRect.left - offsetX) / scaleX).floor();
      int endIndex = ((chartRect.right - offsetX) / scaleX).ceil();

      if (startIndex < 0) startIndex = 0;
      if (endIndex > points.length - 1) endIndex = points.length - 1;

      for (int j = startIndex; j <= endIndex; j++) {
        double x = (j * scaleX) + offsetX;
        double y = (size.height / 2) - (points[j] * scaleY * 20) + offsetY;

        if (isFirst) {
          path.moveTo(x, y);
          isFirst = false;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }

    // 绘制矩形选区（在波形之上、游标之下）
    _drawSelectionRect(canvas, chartRect);

    // 绘制游标
    _drawCursor(canvas, size, chartRect);

    canvas.restore();

    // 坐标轴背景
    final bgPaint = Paint()..color = const Color(0xFF2D2D2D);
    canvas.drawRect(Rect.fromLTWH(0, 0, yAxisWidth, size.height), bgPaint);
    canvas.drawRect(Rect.fromLTWH(0, size.height - xAxisHeight, size.width, xAxisHeight), bgPaint);

    _drawYAxis(canvas, size);
    _drawXAxis(canvas, size);
  }

  // ─── 矩形选区绘制 ──────────────────────────────────────
  void _drawSelectionRect(Canvas canvas, Rect chartRect) {
    if (rectStart == null || rectEnd == null) return;

    double left = min(rectStart!.dx, rectEnd!.dx);
    double right = max(rectStart!.dx, rectEnd!.dx);
    double top = min(rectStart!.dy, rectEnd!.dy);
    double bottom = max(rectStart!.dy, rectEnd!.dy);

    // 裁剪到绘图区
    left = max(left, chartRect.left);
    right = min(right, chartRect.right);
    top = max(top, chartRect.top);
    bottom = min(bottom, chartRect.bottom);

    final rect = Rect.fromLTRB(left, top, right, bottom);

    // 半透明蓝底
    final fillPaint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    canvas.drawRect(rect, fillPaint);

    // 白色虚线边框
    final borderPaint = Paint()
      ..color = Colors.white54
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect, borderPaint);
  }

  // ─── 游标 ──────────────────────────────────────────────
  void _drawCursor(Canvas canvas, Size size, Rect chartRect) {
    if (cursorX == null) return;

    double screenCursorX = (cursorX! * scaleX) + offsetX;
    if (screenCursorX < chartRect.left || screenCursorX > chartRect.right) return;

    final cursorLinePaint = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(screenCursorX, chartRect.top),
      Offset(screenCursorX, chartRect.bottom),
      cursorLinePaint,
    );

    double cursorTime = cursorX! * deltaTime;
    final timeTp = TextPainter(
      text: TextSpan(
        text: " T: ${cursorTime.toStringAsFixed(1)}ms ",
        style: const TextStyle(color: Colors.black, fontSize: 10, backgroundColor: Colors.white),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    timeTp.paint(canvas, Offset(screenCursorX + 4, 10));

    int dataIndex = cursorX!.round();
    for (int i = 0; i < ids.length; i++) {
      final id = ids[i];
      final points = allPoints[id];
      final color = colors[i % colors.length];

      if (points != null && dataIndex >= 0 && dataIndex < points.length) {
        double value = points[dataIndex];
        double screenY = (size.height / 2) - (value * scaleY * 20) + offsetY;

        if (screenY >= chartRect.top && screenY <= chartRect.bottom) {
          canvas.drawCircle(Offset(screenCursorX, screenY), 4, Paint()..color = color);
          canvas.drawCircle(Offset(screenCursorX, screenY), 2, Paint()..color = Colors.black);

          final valTp = TextPainter(
            text: TextSpan(
              text: value.toStringAsFixed(2),
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                backgroundColor: Colors.black.withValues(alpha: 0.7),
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          valTp.paint(canvas, Offset(screenCursorX + 8, screenY - 6));
        }
      }
    }
  }

  void _drawGrid(Canvas canvas, Size size, Rect rect) {
    final paint = Paint()..color = Colors.white10..strokeWidth = 1;
    const stepX = 100.0;
    const stepY = 50.0;

    for (double x = rect.left; x < rect.right; x += stepX) {
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), paint);
    }
    for (double y = rect.top; y < rect.bottom; y += stepY) {
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
    }
  }

  void _drawYAxis(Canvas canvas, Size size) {
    final tp = TextPainter(textDirection: TextDirection.ltr);
    final linePaint = Paint()..color = Colors.white30;

    const stepPixels = 50.0;
    for (double y = 0; y < size.height - xAxisHeight; y += stepPixels) {
      double center = size.height / 2;
      double val = (center + offsetY - y) / (scaleY * 20);

      tp.text = TextSpan(text: val.toStringAsFixed(1), style: const TextStyle(color: Colors.white60, fontSize: 10));
      tp.layout();
      tp.paint(canvas, Offset(5, y - 6));
      canvas.drawLine(Offset(yAxisWidth - 5, y), Offset(yAxisWidth, y), linePaint);
    }
  }

  void _drawXAxis(Canvas canvas, Size size) {
    final tp = TextPainter(textDirection: TextDirection.ltr);
    final linePaint = Paint()..color = Colors.white30;

    double stepPixels = 100 * scaleX;
    if (stepPixels < 80) stepPixels = 100;

    for (double x = yAxisWidth; x < size.width; x += stepPixels) {
      double indexVal = (x - offsetX) / scaleX;
      double timeMs = indexVal * deltaTime;

      String label;
      if (timeMs.abs() >= 1000) {
        label = "${(timeMs / 1000).toStringAsFixed(1)}s";
      } else {
        label = "${timeMs.toStringAsFixed(0)}ms";
      }

      tp.text = TextSpan(text: label, style: const TextStyle(color: Colors.white60, fontSize: 10));
      tp.layout();
      tp.paint(canvas, Offset(x - 10, size.height - xAxisHeight + 5));
      canvas.drawLine(Offset(x, size.height - xAxisHeight), Offset(x, size.height - xAxisHeight + 5), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant ProScopePainter old) => true;
}
