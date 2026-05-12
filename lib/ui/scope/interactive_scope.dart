import 'dart:math';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../../ring_buffer.dart';
import 'pro_scope_painter.dart';

enum ScopeTool { pan, zoomRect }

class InteractiveScope extends StatefulWidget {
  final Map<int, RingBuffer> dataPoints;
  final List<int> varIds;
  final List<Color> colors;
  final double deltaTime;

  const InteractiveScope({
    super.key,
    required this.dataPoints,
    required this.varIds,
    required this.colors,
    this.deltaTime = 1.0,
  });

  @override
  State<InteractiveScope> createState() => _InteractiveScopeState();
}

class _InteractiveScopeState extends State<InteractiveScope> {
  double _scaleX = 1.0;
  double _scaleY = 1.0;
  double _offsetX = 0.0;
  double _offsetY = 0.0;
  final double _snapThreshold = 50.0;
  bool _autoLock = true;

  double? _cursorX;

  final double _yAxisWidth = 50.0;
  final double _xAxisHeight = 30.0;

  // 工具模式
  ScopeTool _tool = ScopeTool.pan;

  // 矩形框选
  Offset? _rectStart;
  Offset? _rectEnd;

  // 布局尺寸（从 LayoutBuilder 获取，非状态变量避免频繁重建）
  double _chartWidth = 0;
  double _chartHeight = 0;
  double _centerY = 0;

  @override
  void didUpdateWidget(InteractiveScope oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  // ─── 自动适配 Y ────────────────────────────────────────
  void _autoFitY() {
    double minVal = double.infinity;
    double maxVal = double.negativeInfinity;
    bool hasData = false;

    for (final id in widget.varIds) {
      final points = widget.dataPoints[id];
      if (points == null || points.length == 0) continue;
      for (int i = 0; i < points.length; i++) {
        final v = points[i];
        if (v < minVal) minVal = v;
        if (v > maxVal) maxVal = v;
        hasData = true;
      }
    }

    if (!hasData || minVal == maxVal || _chartHeight <= 0) return;

    setState(() {
      final margin = _chartHeight * 0.1;
      final dataRange = maxVal - minVal;
      _scaleY = (_chartHeight - 2 * margin) / (dataRange * 20);
      _offsetY = margin - _centerY + maxVal * _scaleY * 20;
    });
  }

  // ─── 自动适配 X ────────────────────────────────────────
  void _autoFitX() {
    int maxLen = 0;
    for (final p in widget.dataPoints.values) {
      if (p.length > maxLen) maxLen = p.length;
    }
    if (maxLen == 0 || _chartWidth <= 0) return;

    setState(() {
      final margin = _chartWidth * 0.05;
      _scaleX = (_chartWidth - 2 * margin) / maxLen;
      _offsetX = _yAxisWidth + margin;
      _autoLock = false;
    });
  }

  // ─── 重置视图 ──────────────────────────────────────────
  void _resetView() {
    setState(() {
      _scaleX = 1.0;
      _scaleY = 1.0;
      _offsetX = 0.0;
      _offsetY = 0.0;
      _autoLock = true;
      _cursorX = null;
    });
  }

  // ─── 矩形框选应用 ──────────────────────────────────────
  void _applyRectZoom() {
    if (_rectStart == null || _rectEnd == null) return;

    final oldScaleX = _scaleX;
    final oldScaleY = _scaleY;
    final oldOffsetX = _offsetX;
    final oldOffsetY = _offsetY;

    double rectLeft = min(_rectStart!.dx, _rectEnd!.dx);
    double rectRight = max(_rectStart!.dx, _rectEnd!.dx);
    double rectTop = min(_rectStart!.dy, _rectEnd!.dy);
    double rectBottom = max(_rectStart!.dy, _rectEnd!.dy);

    // 裁剪到绘图区
    rectLeft = max(rectLeft, _yAxisWidth);
    rectRight = min(rectRight, _yAxisWidth + _chartWidth);
    rectTop = max(rectTop, 0.0);
    rectBottom = min(rectBottom, _chartHeight);

    final rectWidth = rectRight - rectLeft;
    final rectHeight = rectBottom - rectTop;

    if (rectWidth < 5 || rectHeight < 5) {
      setState(() {
        _rectStart = null;
        _rectEnd = null;
      });
      return;
    }

    final newScaleX = oldScaleX * (_chartWidth / rectWidth);
    final newScaleY = oldScaleY * (_chartHeight / rectHeight);

    final dataLeft = (rectLeft - oldOffsetX) / oldScaleX;
    final dataTop = (_centerY - rectTop + oldOffsetY) / (oldScaleY * 20);

    final newOffsetX = _yAxisWidth - dataLeft * newScaleX;
    final newOffsetY = 0 - _centerY + dataTop * newScaleY * 20;

    setState(() {
      _scaleX = newScaleX;
      _scaleY = newScaleY;
      _offsetX = newOffsetX;
      _offsetY = newOffsetY;
      _autoLock = false;
      _rectStart = null;
      _rectEnd = null;
    });
  }

  // ─── 滚轮缩放 ──────────────────────────────────────────
  void _handleWheel(PointerScrollEvent event) {
    setState(() {
      final zoomFactor = 0.1;
      final isZoomIn = event.scrollDelta.dy < 0;
      final scaleMultiplier = isZoomIn ? (1 + zoomFactor) : (1 - zoomFactor);

      if (event.localPosition.dx >= _yAxisWidth) {
        if (_autoLock) {
          _scaleX *= scaleMultiplier;
        } else {
          final chartFocalX = event.localPosition.dx;
          _offsetX = chartFocalX - (chartFocalX - _offsetX) * scaleMultiplier;
          _scaleX *= scaleMultiplier;
        }
      } else {
        final focalPointY = event.localPosition.dy;
        _offsetY = focalPointY - (focalPointY - _offsetY) * scaleMultiplier;
        _scaleY *= scaleMultiplier;
      }
    });
  }

  // ─── 手势处理 ──────────────────────────────────────────
  void _handlePanStart(DragStartDetails details) {
    if (_tool == ScopeTool.zoomRect) {
      setState(() {
        _rectStart = details.localPosition;
        _rectEnd = details.localPosition;
      });
    }
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (_tool == ScopeTool.zoomRect) {
      setState(() {
        _rectEnd = details.localPosition;
      });
      return;
    }

    // 平移模式
    setState(() {
      if (details.localPosition.dx < _yAxisWidth) {
        _offsetY += details.delta.dy;
        return;
      }
      _offsetX += details.delta.dx;
      _autoLock = false;
    });
  }

  void _handlePanEnd(DragEndDetails details) {
    if (_tool == ScopeTool.zoomRect) {
      _applyRectZoom();
      return;
    }

    // 平移模式松手：检查是否需要吸附回右侧
    int maxLen = 0;
    for (final p in widget.dataPoints.values) {
      if (p.length > maxLen) maxLen = p.length;
    }
    final viewportRightIndex = (_chartWidth - _offsetX) / _scaleX;
    if (viewportRightIndex >= maxLen - (_snapThreshold / _scaleX)) {
      setState(() {
        _autoLock = true;
      });
    }
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    if (details.localPosition.dx > _yAxisWidth) {
      setState(() {
        _cursorX = (details.localPosition.dx - _offsetX) / _scaleX;
      });
    }
  }

  void _handleSecondaryTap(TapUpDetails details) {
    // 右键取消框选
    if (_tool == ScopeTool.zoomRect && _rectStart != null) {
      setState(() {
        _rectStart = null;
        _rectEnd = null;
        _tool = ScopeTool.pan;
      });
    }
  }

  // ─── 工具栏 ────────────────────────────────────────────
  Widget _buildToolbar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _toolBtn(Icons.open_with, ScopeTool.pan, '平移模式'),
          _toolBtn(Icons.crop_free, ScopeTool.zoomRect, '框选缩放'),
          _divider(),
          _actionBtn(Icons.swap_vert, '自动适配 Y', _autoFitY),
          _actionBtn(Icons.swap_horiz, '自动适配 X', _autoFitX),
          _actionBtn(Icons.zoom_out_map, '重置视图', _resetView),
        ],
      ),
    );
  }

  Widget _divider() {
    return const SizedBox(
      height: 18,
      child: VerticalDivider(width: 1, color: Colors.white24),
    );
  }

  Widget _toolBtn(IconData icon, ScopeTool tool, String tooltip) {
    final isActive = _tool == tool;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: () => setState(() => _tool = tool),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isActive ? Colors.blueAccent.withValues(alpha: 0.4) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(icon, size: 18, color: isActive ? Colors.lightBlueAccent : Colors.white70),
        ),
      ),
    );
  }

  Widget _actionBtn(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(icon, size: 18, color: Colors.white70),
        ),
      ),
    );
  }

  // ─── Build ─────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final totalHeight = constraints.maxHeight;
        _chartWidth = totalWidth - _yAxisWidth;
        _chartHeight = totalHeight - _xAxisHeight;
        _centerY = totalHeight / 2;

        int maxLen = 0;
        if (widget.dataPoints.isNotEmpty) {
          for (final p in widget.dataPoints.values) {
            if (p.length > maxLen) maxLen = p.length;
          }
        }

        if (_autoLock && maxLen > 0) {
          _offsetX = _chartWidth - (maxLen * _scaleX) - 10;
        }

        return Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              _handleWheel(event);
            }
          },
          child: GestureDetector(
            onPanStart: _handlePanStart,
            onPanUpdate: _handlePanUpdate,
            onPanEnd: _handlePanEnd,
            onDoubleTapDown: _handleDoubleTapDown,
            onSecondaryTapUp: _handleSecondaryTap,
            child: Stack(
              children: [
                Container(
                  color: const Color(0xFF1E1E1E),
                  child: ClipRect(
                    child: CustomPaint(
                      painter: ProScopePainter(
                        allPoints: widget.dataPoints,
                        ids: widget.varIds,
                        colors: widget.colors,
                        scaleX: _scaleX,
                        scaleY: _scaleY,
                        offsetX: _offsetX,
                        offsetY: _offsetY,
                        cursorX: _cursorX,
                        yAxisWidth: _yAxisWidth,
                        xAxisHeight: _xAxisHeight,
                        deltaTime: widget.deltaTime,
                        rectStart: _rectStart,
                        rectEnd: _rectEnd,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: _buildToolbar(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
