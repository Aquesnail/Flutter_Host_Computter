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

  ScopeTool _tool = ScopeTool.pan;

  Offset? _rectStart;
  Offset? _rectEnd;

  double _chartWidth = 0;
  double _chartHeight = 0;
  double _centerY = 0;

  @override
  void didUpdateWidget(InteractiveScope oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

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
    if (_tool == ScopeTool.zoomRect && _rectStart != null) {
      setState(() {
        _rectStart = null;
        _rectEnd = null;
        _tool = ScopeTool.pan;
      });
    }
  }

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
                  child: _ScopeToolbar(
                    tool: _tool,
                    onToolChanged: (t) => setState(() => _tool = t),
                    onAutoFitY: _autoFitY,
                    onAutoFitX: _autoFitX,
                    onResetView: _resetView,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─── 工具栏：独立 StatelessWidget，稳定子树 ───

class _ScopeToolbar extends StatelessWidget {
  final ScopeTool tool;
  final ValueChanged<ScopeTool> onToolChanged;
  final VoidCallback onAutoFitY;
  final VoidCallback onAutoFitX;
  final VoidCallback onResetView;

  const _ScopeToolbar({
    required this.tool,
    required this.onToolChanged,
    required this.onAutoFitY,
    required this.onAutoFitX,
    required this.onResetView,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToolBtn(
            icon: Icons.open_with,
            active: tool == ScopeTool.pan,
            tooltip: '平移模式',
            onTap: () => onToolChanged(ScopeTool.pan),
          ),
          _ToolBtn(
            icon: Icons.crop_free,
            active: tool == ScopeTool.zoomRect,
            tooltip: '框选缩放',
            onTap: () => onToolChanged(ScopeTool.zoomRect),
          ),
          const SizedBox(
            height: 18,
            child: VerticalDivider(width: 1, color: Colors.white24),
          ),
          _ActionBtn(icon: Icons.swap_vert, tooltip: '自动适配 Y', onTap: onAutoFitY),
          _ActionBtn(icon: Icons.swap_horiz, tooltip: '自动适配 X', onTap: onAutoFitX),
          _ActionBtn(icon: Icons.zoom_out_map, tooltip: '重置视图', onTap: onResetView),
        ],
      ),
    );
  }
}

class _ToolBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  const _ToolBtn({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: active ? Colors.blueAccent.withValues(alpha: 0.4) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(icon, size: 18, color: active ? Colors.lightBlueAccent : Colors.white70),
        ),
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ActionBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
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
}
