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

  // ─── 复用的 Paint 对象（懒初始化，避免每帧 new）──────────
  Paint? _gridPaint;
  Paint? _bgPaint;
  Paint? _axisLinePaint;
  Paint? _cursorLinePaint;
  Paint? _selFillPaint;
  Paint? _selBorderPaint;

  Paint get gridPaint => _gridPaint ??= (Paint()..color = Colors.white10..strokeWidth = 1);
  Paint get bgPaint => _bgPaint ??= (Paint()..color = const Color(0xFF2D2D2D));
  Paint get axisLinePaint => _axisLinePaint ??= (Paint()..color = Colors.white30);
  Paint get cursorLinePaint => _cursorLinePaint ??= (Paint()..color = Colors.white70..strokeWidth = 1);
  Paint get selFillPaint => _selFillPaint ??= (Paint()..color = Colors.blueAccent.withValues(alpha: 0.15)..style = PaintingStyle.fill);
  Paint get selBorderPaint => _selBorderPaint ??= (Paint()..color = Colors.white54..strokeWidth = 1..style = PaintingStyle.stroke);

  // 每通道复用的 Paint + Path
  final List<Paint> _channelPaints = [];
  final List<Path> _channelPaths = [];

  Paint _channelPaint(int i) {
    while (_channelPaints.length <= i) {
      _channelPaints.add(Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }
    final p = _channelPaints[i];
    p.color = colors[i % colors.length];
    return p;
  }

  Path _channelPath(int i) {
    while (_channelPaths.length <= i) {
      _channelPaths.add(Path());
    }
    return _channelPaths[i]..reset();
  }

  // ─── 网格缓存 ──────────────────────────────────────────
  Size? _cachedGridSize;
  Rect? _cachedGridRect;
  Path? _cachedGridPath;

  Path _gridPath(Size size, Rect rect) {
    if (_cachedGridPath != null &&
        _cachedGridSize == size &&
        _cachedGridRect == rect) {
      return _cachedGridPath!;
    }

    final path = Path();
    const stepX = 100.0;
    const stepY = 50.0;

    for (double x = rect.left; x < rect.right; x += stepX) {
      path.moveTo(x, rect.top);
      path.lineTo(x, rect.bottom);
    }
    for (double y = rect.top; y < rect.bottom; y += stepY) {
      path.moveTo(rect.left, y);
      path.lineTo(rect.right, y);
    }

    _cachedGridSize = size;
    _cachedGridRect = rect;
    _cachedGridPath = path;
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final chartRect = Rect.fromLTWH(
      yAxisWidth, 0, size.width - yAxisWidth, size.height - xAxisHeight,
    );

    // 网格（缓存路径，仅 stroke 一次）
    canvas.drawPath(_gridPath(size, chartRect), gridPaint);

    canvas.save();
    canvas.clipRect(chartRect);

    // 波形
    for (int i = 0; i < ids.length; i++) {
      final id = ids[i];
      final points = allPoints[id];
      if (points == null || points.length == 0) continue;

      int startIndex = ((chartRect.left - offsetX) / scaleX).floor();
      int endIndex = ((chartRect.right - offsetX) / scaleX).ceil();

      if (startIndex < 0) startIndex = 0;
      if (endIndex > points.length - 1) endIndex = points.length - 1;
      if (startIndex > endIndex) continue;

      final path = _channelPath(i);
      double x = (startIndex * scaleX) + offsetX;
      double y = (size.height / 2) - (points[startIndex] * scaleY * 20) + offsetY;
      path.moveTo(x, y);

      for (int j = startIndex + 1; j <= endIndex; j++) {
        x = (j * scaleX) + offsetX;
        y = (size.height / 2) - (points[j] * scaleY * 20) + offsetY;
        path.lineTo(x, y);
      }

      canvas.drawPath(path, _channelPaint(i));
    }

    _drawSelectionRect(canvas, chartRect);
    _drawCursor(canvas, size, chartRect);

    canvas.restore();

    // 坐标轴背景
    canvas.drawRect(Rect.fromLTWH(0, 0, yAxisWidth, size.height), bgPaint);
    canvas.drawRect(Rect.fromLTWH(0, size.height - xAxisHeight, size.width, xAxisHeight), bgPaint);

    _drawYAxis(canvas, size);
    _drawXAxis(canvas, size);
  }

  void _drawSelectionRect(Canvas canvas, Rect chartRect) {
    if (rectStart == null || rectEnd == null) return;

    double left = min(rectStart!.dx, rectEnd!.dx);
    double right = max(rectStart!.dx, rectEnd!.dx);
    double top = min(rectStart!.dy, rectEnd!.dy);
    double bottom = max(rectStart!.dy, rectEnd!.dy);

    left = max(left, chartRect.left);
    right = min(right, chartRect.right);
    top = max(top, chartRect.top);
    bottom = min(bottom, chartRect.bottom);

    final rect = Rect.fromLTRB(left, top, right, bottom);
    canvas.drawRect(rect, selFillPaint);
    canvas.drawRect(rect, selBorderPaint);
  }

  void _drawCursor(Canvas canvas, Size size, Rect chartRect) {
    if (cursorX == null) return;

    double screenCursorX = (cursorX! * scaleX) + offsetX;
    if (screenCursorX < chartRect.left || screenCursorX > chartRect.right) return;

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

  void _drawYAxis(Canvas canvas, Size size) {
    final tp = TextPainter(textDirection: TextDirection.ltr);

    const stepPixels = 50.0;
    for (double y = 0; y < size.height - xAxisHeight; y += stepPixels) {
      double center = size.height / 2;
      double val = (center + offsetY - y) / (scaleY * 20);

      tp.text = TextSpan(text: val.toStringAsFixed(1), style: const TextStyle(color: Colors.white60, fontSize: 10));
      tp.layout();
      tp.paint(canvas, Offset(5, y - 6));
      canvas.drawLine(Offset(yAxisWidth - 5, y), Offset(yAxisWidth, y), axisLinePaint);
    }
  }

  void _drawXAxis(Canvas canvas, Size size) {
    final tp = TextPainter(textDirection: TextDirection.ltr);

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
      canvas.drawLine(Offset(x, size.height - xAxisHeight), Offset(x, size.height - xAxisHeight + 5), axisLinePaint);
    }
  }

  @override
  bool shouldRepaint(covariant ProScopePainter old) {
    if (scaleX != old.scaleX ||
        scaleY != old.scaleY ||
        offsetX != old.offsetX ||
        offsetY != old.offsetY ||
        cursorX != old.cursorX ||
        rectStart != old.rectStart ||
        rectEnd != old.rectEnd ||
        deltaTime != old.deltaTime) {
      return true;
    }
    // 检查是否有新数据到达（通过 buffer 长度变化）
    for (final id in ids) {
      if (allPoints[id]?.length != old.allPoints[id]?.length) return true;
    }
    return false;
  }
}
