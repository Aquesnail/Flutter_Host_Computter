import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../../ring_buffer.dart';
import 'pro_scope_painter.dart';

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
    this.deltaTime = 1.0
  });

  @override
  State<InteractiveScope> createState() => _InteractiveScopeState();
}

class _InteractiveScopeState extends State<InteractiveScope> {
  // 视图变换状态
  double _scaleX = 1.0;
  double _scaleY = 1.0;
  double _offsetX = 0.0; // X轴偏移 (像素)
  double _offsetY = 0.0; // Y轴偏移 (像素)
  final double _snapThreshold = 50.0;
//是否锁定横坐标至最右侧的标志位
  bool _autoLock = true;
  // 游标系统
  double? _cursorX; // 游标位置 (对应数据的 index 或时间)

  // 布局常量
  final double _yAxisWidth = 50.0; // 左侧 Y 轴区域宽度
  final double _xAxisHeight = 30.0; // 底部 X 轴区域高度

  @override
  void didUpdateWidget(InteractiveScope oldWidget) {
    super.didUpdateWidget(oldWidget);

  }

void _handleWheel(PointerScrollEvent event, BoxConstraints constraints) {
     setState(() {
        // ... 原有逻辑 ...
        final double zoomFactor = 0.1;
        final bool isZoomIn = event.scrollDelta.dy < 0;
        final double scaleMultiplier = isZoomIn ? (1 + zoomFactor) : (1 - zoomFactor);

        if (event.localPosition.dx >= _yAxisWidth) {
           // X轴缩放
           if (_autoLock) {
              _scaleX *= scaleMultiplier;
              // 锁定状态下，缩放不需要手动算 _offsetX，
              // 因为 setState 触发 build，build 里的 LayoutBuilder 会自动用新的 scaleX
              // 重新计算出靠右对齐的 _offsetX。
           } else {
              // 非锁定状态，以鼠标为中心
              final double focalPointX = event.localPosition.dx;
              // 修正 focalPointX 对应的是绘图区的坐标
              final double chartFocalX = focalPointX;
              // newOffset = mouse - (mouse - oldOffset) * scale
              _offsetX = chartFocalX - (chartFocalX - _offsetX) * scaleMultiplier;
              _scaleX *= scaleMultiplier;
           }
        } else {
           // Y轴缩放 (保持不变)
           final double focalPointY = event.localPosition.dy;
           _offsetY = focalPointY - (focalPointY - _offsetY) * scaleMultiplier;
           _scaleY *= scaleMultiplier;
        }
     });
  }

void _handlePan(DragUpdateDetails details) {
    setState(() {
      if (details.localPosition.dx < _yAxisWidth) {
         _offsetY += details.delta.dy;
         return;
      }

      // 一旦用户开始拖拽 X 轴，先应用当前的 delta
      _offsetX += details.delta.dx;

      // 这里的逻辑依然需要 context.size 吗？
      // 在回调里访问 context.size 是安全的，但既然我们有了 LayoutBuilder，
      // 我们可以把 maxLen 的判断逻辑放在这里，或者简单点，
      // 只判断是否“试图往左拖离了最右边”。

      // 为了简单和安全，我们在 build 里处理“自动吸附”，
      // 在这里只处理“解除锁定”。

      // 只要用户有水平拖动，暂时先解除锁定，
      // 下一帧 build 时会根据位置再次判断是否吸附
      _autoLock = false;
    });
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    // 双击添加/移动游标
    if (details.localPosition.dx > _yAxisWidth) {
      setState(() {
        // 将屏幕坐标反算回数据坐标 (Index)
        // ScreenX = DataX * ScaleX + OffsetX
        // DataX = (ScreenX - OffsetX) / ScaleX
        _cursorX = (details.localPosition.dx - _offsetX) / _scaleX;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 【修改点 3】使用 LayoutBuilder 获取实时尺寸
    return LayoutBuilder(
      builder: (context, constraints) {
        // 1. 获取当前绘图区的实际宽度
        // constraints.maxWidth 是整个控件的宽度
        final double totalWidth = constraints.maxWidth;
        final double chartWidth = totalWidth - _yAxisWidth;

        // 2. 计算数据最大长度
        int maxLen = 0;
        if (widget.dataPoints.isNotEmpty) {
           for (var p in widget.dataPoints.values) {
             if (p.length > maxLen) maxLen = p.length;
           }
        }

        // 3. 核心逻辑：如果是自动锁定模式，强制覆盖 _offsetX
        // 这实现了“数据更新时自动跟手”的效果
        if (_autoLock && maxLen > 0) {
           // 强制让视图对齐到最右边
           // 注意：我们直接修改用于绘制的变量，但不调用 setState（因为已经在 build 中）
           // 这里不能直接改 _offsetX 成员变量，否则会报错 "setState during build"
           // 技巧：我们定义一个 renderOffsetX 传给 Painter
           _offsetX = chartWidth - (maxLen * _scaleX) - 10;
        } else {
           // 如果是非锁定模式，我们检查一下是否需要“吸附”回去
           // 计算当前视口右侧对应的 Index
           double viewportRightIndex = (chartWidth - _offsetX) / _scaleX;

           // 如果非常接近最右侧 (吸附阈值)
           if (viewportRightIndex >= maxLen - (_snapThreshold / _scaleX)) {
             // 自动吸附回去
             // 注意：这里需要小心死循环。通常我们在 build 里只做计算。
             // 如果需要改变状态(_autoLock)，最好推迟到下一帧，或者由用户交互触发。
             // 简单起见：这里只做“如果不锁定，就用用户拖出来的 _offsetX”
           }
        }

        return Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
               // 传入 constraints 以便缩放逻辑也能拿到尺寸
               _handleWheel(event, constraints);
            }
          },
          child: GestureDetector(
            onPanUpdate: _handlePan,
            onPanEnd: (details) {
               // 拖拽松手时，检查是否需要重新开启锁定
               int maxLen = 0;
               for (var p in widget.dataPoints.values) {
                 if (p.length > maxLen) maxLen = p.length;
               }
               // 重新计算边界
               double viewportRightIndex = (chartWidth - _offsetX) / _scaleX;
               if (viewportRightIndex >= maxLen - (_snapThreshold / _scaleX)) {
                 setState(() {
                   _autoLock = true;
                 });
               }
            },
            onDoubleTapDown: _handleDoubleTapDown,
            child: Container(
              color: const Color(0xFF1E1E1E),
              child: ClipRect(
                child: CustomPaint(
                  painter: ProScopePainter(
                    allPoints: widget.dataPoints,
                    ids: widget.varIds,
                    colors: widget.colors,
                    scaleX: _scaleX,
                    scaleY: _scaleY,
                    // 【关键】直接把上面计算好的(或缓存的) _offsetX 传进去
                    offsetX: _offsetX,
                    offsetY: _offsetY,
                    cursorX: _cursorX,
                    yAxisWidth: _yAxisWidth,
                    xAxisHeight: _xAxisHeight,
                    deltaTime: widget.deltaTime,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
