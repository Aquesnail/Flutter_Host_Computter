import 'dart:math';
import 'package:flutter/material.dart';
import '../../ring_buffer.dart';
import 'value_display_format.dart';

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

  final Map<int, ValueDisplayFormat> displayFormats;
  final Map<int, IntDisplayFormat> intDisplayFormats;
  final Map<int, double> channelScales;

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
    this.displayFormats = const {},
    this.intDisplayFormats = const {},
    this.channelScales = const {},
  });

  // ─── 复用的 Paint 对象（懒初始化，避免每帧 new）──────────
  Paint? _gridPaint;
  Paint? _minorGridPaint;
  Paint? _bgPaint;
  Paint? _axisLinePaint;
  Paint? _cursorLinePaint;
  Paint? _selFillPaint;
  Paint? _selBorderPaint;

  Paint get gridPaint => _gridPaint ??= (Paint()..color = Colors.white10..strokeWidth = 1);
  Paint get minorGridPaint => _minorGridPaint ??= (Paint()..color = Colors.white.withValues(alpha: 0.04)..strokeWidth = 0.5);
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

  // ─── 自适应网格 ──────────────────────────────────────────

  double _niceTimeStep(double rawMs) {
    if (rawMs <= 0) return 1.0;
    final exponent = (log(rawMs) / ln10).floor();
    final power = pow(10.0, exponent).toDouble();
    final mantissa = rawMs / power;

    if (mantissa <= 1.5) return power;
    if (mantissa <= 3.5) return 2 * power;
    if (mantissa <= 7.5) return 5 * power;
    return 10 * power;
  }

  String _formatTime(double ms) {
    final absMs = ms.abs();
    if (absMs >= 1000) {
      return '${(ms / 1000).toStringAsFixed(1)}s';
    } else if (absMs < 1) {
      return '${ms.toStringAsFixed(1)}ms';
    } else {
      return '${ms.toStringAsFixed(0)}ms';
    }
  }

  void _drawGrid(Canvas canvas, Rect chartRect) {
    final msPerPixel = deltaTime / scaleX;
    final stepMs = _niceTimeStep(msPerPixel * 100);
    final stepPx = stepMs / msPerPixel;

    final leftMs = (chartRect.left - offsetX) / scaleX * deltaTime;
    final startMs = (leftMs / stepMs).ceil() * stepMs;

    // 次网格线（1/5 步长，仅在间距足够时）
    final minorStepMs = stepMs / 5.0;
    final minorStepPx = minorStepMs / msPerPixel;
    final showMinor = minorStepPx >= 15;

    // X 轴网格线
    double curMs = startMs;
    for (double x = chartRect.left + (startMs - leftMs) / msPerPixel;
        x < chartRect.right;
        x += stepPx, curMs += stepMs) {
      canvas.drawLine(Offset(x, chartRect.top), Offset(x, chartRect.bottom), gridPaint);
      if (showMinor) {
        for (int i = 1; i <= 4; i++) {
          final mx = x + i * minorStepPx;
          if (mx < chartRect.right) {
            canvas.drawLine(Offset(mx, chartRect.top), Offset(mx, chartRect.bottom), minorGridPaint);
          }
        }
      }
    }

    // Y 轴网格线（固定 50px）
    for (double y = chartRect.top; y < chartRect.bottom; y += 50) {
      canvas.drawLine(Offset(chartRect.left, y), Offset(chartRect.right, y), gridPaint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final chartRect = Rect.fromLTWH(
      yAxisWidth, 0, size.width - yAxisWidth, size.height - xAxisHeight,
    );

    // 网格
    _drawGrid(canvas, chartRect);

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

      final chScale = channelScales[id] ?? 1.0;
      final path = _channelPath(i);
      double x = (startIndex * scaleX) + offsetX;
      double y = (size.height / 2) - (points[startIndex] * chScale * scaleY * 20) + offsetY;
      path.moveTo(x, y);

      for (int j = startIndex + 1; j <= endIndex; j++) {
        x = (j * scaleX) + offsetX;
        y = (size.height / 2) - (points[j] * chScale * scaleY * 20) + offsetY;
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
        text: " T: ${_formatTime(cursorTime)} ",
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
        final chScale = channelScales[id] ?? 1.0;
        double rawValue = points[dataIndex];
        double scaledValue = rawValue * chScale;
        double screenY = (size.height / 2) - (scaledValue * scaleY * 20) + offsetY;

        if (screenY >= chartRect.top && screenY <= chartRect.bottom) {
          canvas.drawCircle(Offset(screenCursorX, screenY), 4, Paint()..color = color);
          canvas.drawCircle(Offset(screenCursorX, screenY), 2, Paint()..color = Colors.black);

          final intFmt = intDisplayFormats[id];
          final displayText = intFmt != null
              ? formatIntValue(scaledValue, intFmt)
              : formatValue(scaledValue, displayFormats[id] ?? ValueDisplayFormat.normal);

          final valTp = TextPainter(
            text: TextSpan(
              text: displayText,
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

    final msPerPixel = deltaTime / scaleX;
    final stepMs = _niceTimeStep(msPerPixel * 100);
    final stepPx = stepMs / msPerPixel;

    final leftMs = (yAxisWidth - offsetX) / scaleX * deltaTime;
    final startMs = (leftMs / stepMs).ceil() * stepMs;

    // 次刻度（1/5 步长，仅在间距足够时显示）
    final minorStepMs = stepMs / 5.0;
    final minorStepPx = minorStepMs / msPerPixel;
    final showMinor = minorStepPx >= 15;

    double curMs = startMs;
    for (double x = yAxisWidth + (startMs - leftMs) / msPerPixel;
        x < size.width;
        x += stepPx, curMs += stepMs) {
      // 标签
      final label = _formatTime(curMs);
      tp.text = TextSpan(text: label, style: const TextStyle(color: Colors.white60, fontSize: 10));
      tp.layout();
      tp.paint(canvas, Offset(x - tp.width / 2, size.height - xAxisHeight + 5));

      // 主刻度
      canvas.drawLine(
        Offset(x, size.height - xAxisHeight),
        Offset(x, size.height - xAxisHeight + 8),
        axisLinePaint,
      );

      // 次刻度
      if (showMinor) {
        for (int i = 1; i <= 4; i++) {
          final mx = x + i * minorStepPx;
          if (mx < size.width) {
            canvas.drawLine(
              Offset(mx, size.height - xAxisHeight),
              Offset(mx, size.height - xAxisHeight + 4),
              axisLinePaint,
            );
          }
        }
      }
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
        deltaTime != old.deltaTime ||
        displayFormats != old.displayFormats ||
        intDisplayFormats != old.intDisplayFormats ||
        channelScales != old.channelScales) {
      return true;
    }
    for (final id in ids) {
      if (allPoints[id]?.length != old.allPoints[id]?.length) return true;
    }
    return false;
  }
}
