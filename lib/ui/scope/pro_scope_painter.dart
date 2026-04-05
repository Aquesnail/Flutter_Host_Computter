import 'package:flutter/material.dart';
import '../../ring_buffer.dart';

class ProScopePainter extends CustomPainter {
  final Map<int, RingBuffer> allPoints;
  final List<int> ids;
  final List<Color> colors;

  // 视图变换参数
  final double scaleX;
  final double scaleY;
  final double offsetX;
  final double offsetY;

  // 游标
  final double? cursorX;

  // 布局参数
  final double yAxisWidth;
  final double xAxisHeight;
  //数据点间隔时间
  final double deltaTime;

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
  });

  @override
  void paint(Canvas canvas, Size size) {
    final chartRect = Rect.fromLTWH(
      yAxisWidth,
      0,
      size.width - yAxisWidth,
      size.height - xAxisHeight
    );

    // 1. 绘制网格
    _drawGrid(canvas, size, chartRect);

    // 2. 绘制波形 (使用 clipRect 确保不画到轴上)
    canvas.save();
    canvas.clipRect(chartRect);

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

      // 优化：只绘制屏幕可见范围内的数据点
      // index = (screenX - offsetX) / scaleX
      int startIndex = ((chartRect.left - offsetX) / scaleX).floor();
      int endIndex = ((chartRect.right - offsetX) / scaleX).ceil();

      // 边界检查
      if (startIndex < 0) startIndex = 0;
      if (endIndex > points.length - 1) endIndex = points.length - 1;

      // 如果数据过密，可以添加降采样逻辑 (这里暂略)

      for (int j = startIndex; j <= endIndex; j++) {
        // 坐标变换公式
        // X: index * scaleX + offsetX
        // Y: centerY - (value * scaleY) + offsetY
        // 注意：offsetY 这里作为用户拖拽的垂直偏移

        double x = (j * scaleX) + offsetX;
        // 默认基准是高度的一半，减去数值(向上)，加上用户偏移
        double y = (size.height / 2) - (points[j] * scaleY * 20) + offsetY; // *20 是个基础系数，让原本很小的值显眼一点

        if (isFirst) {
          path.moveTo(x, y);
          isFirst = false;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore(); // 结束 Clip

    // 3. 绘制游标
    if (cursorX != null) {
      double screenCursorX = (cursorX! * scaleX) + offsetX;

      // 只有游标在显示区域内才绘制
      if (screenCursorX >= chartRect.left && screenCursorX <= chartRect.right) {

        // A. 绘制垂直白线
        final cursorLinePaint = Paint()..color = Colors.white70..strokeWidth = 1;
        canvas.drawLine(
          Offset(screenCursorX, chartRect.top),
          Offset(screenCursorX, chartRect.bottom),
          cursorLinePaint
        );
        double cursorTime = cursorX! * deltaTime;
        // B. 绘制顶部的时间标签
        final timeTp = TextPainter(
          text: TextSpan(
            // 这里显示正确的时间
            text: " T: ${cursorTime.toStringAsFixed(1)}ms ",
            style: const TextStyle(color: Colors.black, fontSize: 10, backgroundColor: Colors.white)
          ),
          textDirection: TextDirection.ltr
        )..layout();
        timeTp.paint(canvas, Offset(screenCursorX + 4, 10));

        // C. 遍历所有通道，计算交点并绘制数值
        // 我们取 cursorX 对应的整数索引
        int dataIndex = cursorX!.round();

        for (int i = 0; i < ids.length; i++) {
          final id = ids[i];
          final points = allPoints[id];
          final color = colors[i % colors.length];

          // 检查索引是否有效
          if (points != null && dataIndex >= 0 && dataIndex < points.length) {
            double value = points[dataIndex];

            // 计算数据点在屏幕上的 Y 坐标 (必须与绘制波形的公式完全一致)
            double screenY = (size.height / 2) - (value * scaleY * 20) + offsetY;

            // 只有点在可视范围内才画
            if (screenY >= chartRect.top && screenY <= chartRect.bottom) {

              // C1. 画一个小圆点
              canvas.drawCircle(Offset(screenCursorX, screenY), 4, Paint()..color = color);
              canvas.drawCircle(Offset(screenCursorX, screenY), 2, Paint()..color = Colors.black);

              // C2. 画数值标签 (带背景色，防止重叠看不清)
              final valTp = TextPainter(
                text: TextSpan(
                  text: value.toStringAsFixed(2),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    backgroundColor: Colors.black.withOpacity(0.7) // 半透明黑底
                  )
                ),
                textDirection: TextDirection.ltr
              )..layout();

              // 错位显示，防止文字盖住点
              valTp.paint(canvas, Offset(screenCursorX + 8, screenY - 6));
            }
          }
        }
      }
    }

    // 4. 绘制坐标轴覆盖层 (背景)
    Paint bgPaint = Paint()..color = const Color(0xFF2D2D2D);
    // Y轴背景
    canvas.drawRect(Rect.fromLTWH(0, 0, yAxisWidth, size.height), bgPaint);
    // X轴背景
    canvas.drawRect(Rect.fromLTWH(0, size.height - xAxisHeight, size.width, xAxisHeight), bgPaint);

    // 5. 绘制轴刻度
    _drawYAxis(canvas, size);
    _drawXAxis(canvas, size);
  }

  void _drawGrid(Canvas canvas, Size size, Rect rect) {
    final paint = Paint()..color = Colors.white10..strokeWidth = 1;
    // 简单的十字网格
    double stepX = 100.0;
    double stepY = 50.0;

    // 实际上应该根据 scaleX/scaleY 动态计算网格密度，这里简化为固定像素间隔
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

    // 动态生成 Y 轴刻度
    // 我们可以根据屏幕像素反推数值
    double stepPixels = 50;
    for (double y = 0; y < size.height - xAxisHeight; y += stepPixels) {
      // 数值反算: val = (centerY + offsetY - screenY) / (scaleY * 20)
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

    // 动态计算步长：尽量保证屏幕上每隔 80-120 像素显示一个刻度
    double stepPixels = 100 * scaleX;
    if (stepPixels < 80) stepPixels = 100; // 简单的防过密处理

    // 遍历屏幕上的像素位置
    for (double x = yAxisWidth; x < size.width; x += stepPixels) {
       // 1. 反算数据索引 Index
       // ScreenX = Index * ScaleX + OffsetX
       // Index = (ScreenX - OffsetX) / ScaleX
       double indexVal = (x - offsetX) / scaleX;

       // 2. 将索引转换为时间 (Time = Index * DeltaT)
       double timeMs = indexVal * deltaTime;

       // 3. 格式化文本
       String label;
       if (timeMs.abs() >= 1000) {
         label = "${(timeMs / 1000).toStringAsFixed(1)}s";
       } else {
         label = "${timeMs.toStringAsFixed(0)}ms";
       }

       tp.text = TextSpan(
         text: label,
         style: const TextStyle(color: Colors.white60, fontSize: 10)
       );
       tp.layout();
       tp.paint(canvas, Offset(x - 10, size.height - xAxisHeight + 5));
       canvas.drawLine(Offset(x, size.height - xAxisHeight), Offset(x, size.height - xAxisHeight + 5), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant ProScopePainter old) => true; // 总是重绘以响应高频数据
}
