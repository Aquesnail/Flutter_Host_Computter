import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'dart:async';
import 'device_control.dart'; // 确保路径对应你的实际文件结构
import 'debug_protocol.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import "lowfreq_window.dart";

void main() {
  runApp(
    // 关键步骤：在这里注入你的控制器
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DeviceController()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: MainWindow(), // 现在 MainWindow 就能通过 context 找到控制器了
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color.fromARGB(255, 63, 124, 255)),
          useMaterial3: true,
        ),
      ),
    ),
  );
}

class MainWindow extends StatelessWidget { //完全依赖provider的局部刷新
  const MainWindow({super.key});

  @override
  Widget build(BuildContext context) {
    // 整个 MainWindow 不再监听任何东西
    // 只有内部的 Selector 和 context.select 会触发局部刷新
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: colorScheme.primary,
            child: Row(
              children: [
                // 1. 刷新按钮：只在 [isConnected] 改变时重绘
                Builder(builder: (context) {
                  final isConnected = context.select<DeviceController, bool>((c) => c.isConnected);
                  //这里我们用了StatelessWidget，完全将局部刷新的任务交给了provider
                  //这里的意思是我们只监听DeviceController中isConnected这一个变量的值，
                  return IconButton(
                    tooltip: "刷新端口",
                    icon: const Icon(Icons.refresh, size: 20, color: Colors.white),
                    onPressed: isConnected ? null : () => context.read<DeviceController>().refreshPorts(),//
                  );
                }),

                const SizedBox(width: 10),

                // 2. 串口下拉框：只在 [availablePorts] 或 [selectedPort] 改变时重绘
                Selector<DeviceController, (List<String>, String?)>(
                  selector: (_, c) => (c.availablePorts, c.selectedPort),
                  builder: (context, data, _) {
                    return DropdownButton<String>(
                      value: data.$2,
                      hint: const Text("选择串口", style: TextStyle(color: Colors.white70)),
                      items: data.$1.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                      onChanged: (v) => context.read<DeviceController>().selectedPort = v,
                    );
                  },
                ),

                const SizedBox(width: 10),
                const Text("波特率:", style: TextStyle(color: Colors.white)),

                // 3. 波特率下拉框
                Selector<DeviceController, int>(
                  selector: (_, c) => c.selectedBaudRate,
                  builder: (context, rate, _) {
                    final isConnected = context.select<DeviceController, bool>((c) => c.isConnected);
                    return DropdownButton<int>(
                      value: rate,
                      items: [9600, 19200, 38400, 57600, 115200, 256000]
                          .map((b) => DropdownMenuItem(value: b, child: Text(b.toString())))
                          .toList(),
                      onChanged: isConnected ? null : (v) => context.read<DeviceController>().selectedBaudRate = v!,
                    );
                  },
                ),

                const SizedBox(width: 15),

                // 4. 连接按钮
                Builder(builder: (context) {
                  final isConnected = context.select<DeviceController, bool>((c) => c.isConnected);
                  return ElevatedButton.icon(
                    onPressed: () {
                      final ctrl = context.read<DeviceController>();
                      isConnected ? ctrl.disconnect() : ctrl.connectWithInternal();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isConnected ? Colors.redAccent : Colors.green,
                      foregroundColor: Colors.white,
                    ),
                    icon: Icon(isConnected ? Icons.link_off : Icons.link, size: 18),
                    label: Text(isConnected ? "关闭" : "打开"),
                  );
                }),

                const SizedBox(width: 8),

                // 5. 握手按钮
                _HandshakeButton(),

                const Spacer(),

                // 6. 状态标签：精准监听
                _ConnectionStatusChips(),
              ],
            ),
          ),
          // 7. 核心优化：LayoutDashboard 现在被 const 保护，或者完全不受上方 UI 波动影响
          const Expanded(child: LayoutDashboard())
        ],
      ),
    );
  }
}

// 进一步拆分小组件，实现绝对的局部重绘
class _HandshakeButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isConnected = context.select<DeviceController, bool>((c) => c.isConnected);
    return ElevatedButton.icon(
      icon: const Icon(Icons.back_hand, size: 18),
      label: const Text("握手"),
      onPressed: isConnected ? () async {
        // ... 现有的握手逻辑 ...
        bool success = await context.read<DeviceController>().shakeWithMCU();
        // SnackBar 逻辑保持不变
      } : null,
    );
  }
}

class _ConnectionStatusChips extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // 只有当这两个值确实变化时，这两小块 Chip 才会重绘
    final isConnected = context.select<DeviceController, bool>((c) => c.isConnected);
    final isHandshaked = context.select<DeviceController, bool>((c) => c.shakeHandSuccessful);

    return Row(
      children: [
        if (isConnected) const _StatusChip(label: "已连接", color: Colors.green),
        if (isHandshaked) const _StatusChip(label: "握手成功", color: Colors.blue),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Chip(
        label: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
        backgroundColor: color,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
class LayoutDashboard extends StatefulWidget {
  const LayoutDashboard({super.key});

  @override
  State<LayoutDashboard> createState() => _LayoutDashboardState();
}
class _LayoutDashboardState extends State<LayoutDashboard> {
  late MultiSplitViewController _rootController;
  late MultiSplitViewController _topController;
  late MultiSplitViewController _bottomController;

@override
  void initState() {
    super.initState();

    // 1. 顶部控制器：左侧自适应，右侧固定初始大小
    _topController = MultiSplitViewController(
      areas: [
        // 左侧：主显示区，不设 size，让它用 flex 占满剩余空间
        Area(data: 'top_left', flex: 1), 
        
        // 右侧：控制面板
        Area(
          data: 'top_right', 
          size: 250,    // 【关键】给一个明确的初始像素宽度，而不是 flex 比例
          min: 150,     // 【限位】限制最小宽度 150px，防止内容被压扁
          max: 500      // 【限位】(可选) 限制最大宽度，防止拉太宽
        )
      ]
    );
    
    // 2. 底部控制器：同理，左侧自适应，右侧固定
    _bottomController = MultiSplitViewController(
      areas: [
        Area(data: 'bottom_left', flex: 1), 
        Area(
          data: 'bottom_right', 
          size: 250,    // 初始宽度
          min: 150,      // 最小宽度保护
          max: 600
        )
      ]
    );

    // 3. 根控制器（垂直）：上方自适应，下方固定
    _rootController = MultiSplitViewController(
      areas: [
        // 上方：主要区域
        Area(data: 'TOP_ROW', flex: 1),
        
        // 下方：次要波形区域
        Area(
          data: 'BOTTOM_ROW',
          size: 200,    // 初始高度 200px
          min: 150,     // 最小高度 100px
          max: 400
        ),
      ]
    );
  }

  @override
  Widget build(BuildContext context) {
    // 2. 在 build 方法里获取颜色是安全的，因为此时 Widget 树已经构建好了
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: MultiSplitViewTheme(
        data: MultiSplitViewThemeData(
          dividerThickness: 10.0,
          dividerPainter: DividerPainters.grooved1(
            backgroundColor: colorScheme.surfaceContainerHighest,
            highlightedColor: colorScheme.primary
          )
        ),
        child: MultiSplitView(
          axis: Axis.vertical,
          controller: _rootController,
          builder: (BuildContext context, Area area) {
            if (area.data == 'TOP_ROW') {
              return MultiSplitView(
                axis: Axis.horizontal,
                controller: _topController,
                // 上面两格用主色容器（浅蓝）
                builder: (context, area) {
                  if(area.data == 'top_left'){
                    return const ScopeDashboard();
                  }
                  return _buildContent(colorScheme.primaryContainer, "Primary");
                }
              );
            } else {
              return MultiSplitView(
                axis: Axis.horizontal,
                controller: _bottomController,
                // 下面两格用次级色容器（通常是浅紫色或配套色），看出层次感
                builder: (context, area) {
                  if(area.data == "bottom_left"){
                    return const LowFreqWindow();
                  }
                  return _buildContent(colorScheme.surface, "right_bottom");
                }
              );
            }
          }
        )
      )
    );
  }

  Widget _buildContent(Color color, String label) {
    return Container(
      color: color,
      child: Center(
        child: Text(
          label,
          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
  
}

class ScopeDashboard extends StatefulWidget {
  const ScopeDashboard({super.key});

  @override
  State<ScopeDashboard> createState() => _ScopeDashboardState();
}

class _ScopeDashboardState extends State<ScopeDashboard> {
  // 存储高频数据点：ID -> List
  Map<int, List<double>> multiChannelPoints = {};
  
  StreamSubscription? _subscription;
  Timer? _refreshTimer; // UI 刷新定时器

  // 增加缓存点数，因为现在支持拖拽回看，数据多一点体验更好
  final int maxPoints = 2000; 
  
  // --- 新增配置状态 ---
  int _bufferSize = 2000; // 默认缓冲区大小
  double _deltaTime = 20.0; // 默认采样间隔 (ms)
  
  // 输入控制器
  late TextEditingController _bufferCtrl;
  late TextEditingController _dtCtrl;
  // 颜色表 (用于区分不同曲线)
  final List<Color> colors = [
    Colors.greenAccent, 
    Colors.yellowAccent, 
    Colors.cyanAccent,
    Colors.orangeAccent,
    Colors.purpleAccent
  ];
  //用于强制重置示波器视图状态的 Key
  int _scopeViewKey = 0;
 @override
  void initState() {
    super.initState();
    _bufferCtrl = TextEditingController(text: _bufferSize.toString());
    _dtCtrl = TextEditingController(text: _deltaTime.toString());

    final controller = context.read<DeviceController>();
    
    // --- 核心优化 A: 接收数据不再 setState ---
    _subscription = controller.highFreqStream.listen((data) {
      // 仅在内存中操作数据，不通知 Flutter 重新 build
      multiChannelPoints.putIfAbsent(data.key, () => []);
      final points = multiChannelPoints[data.key]!;
      points.add(data.value);
      
      if (points.length > _bufferSize) {
        points.removeRange(0, points.length - _bufferSize); 
      }
    });

    // --- 核心优化 B: 统一 UI 刷新频率 (60FPS) ---
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (mounted) {
        // 这里触发真正的 UI 重绘，将 16ms 内累积的所有新数据一次性画出来
        setState(() {}); 
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _refreshTimer?.cancel(); //销毁定时器
    _bufferCtrl.dispose();
    _dtCtrl.dispose();
    super.dispose();
  }

  // 更新配置的方法
  void _updateConfig() {
    setState(() {
      int? newBuf = int.tryParse(_bufferCtrl.text);
      if (newBuf != null && newBuf > 10) _bufferSize = newBuf;
      
      double? newDt = double.tryParse(_dtCtrl.text);
      if (newDt != null && newDt > 0) _deltaTime = newDt;
    });
    // 收起键盘
    FocusScope.of(context).unfocus();
  }
  //清空缓冲区逻辑
  void _clearBuffer() {
    setState(() {
      // 1. 清空所有通道的数据
      multiChannelPoints.clear();
      
      // 2. 更新 Key，强制 InteractiveScope 重建
      // 这样可以将 缩放(Scale) 和 偏移(Offset) 重置回初始值
      _scopeViewKey++; 
    });
  }
  @override
  Widget build(BuildContext context) {
    // 获取控制器状态以读取变量列表
    // final controller = context.watch<DeviceController>();
    final colorScheme = Theme.of(context).colorScheme;
    
    // 获取所有标记为高频的变量
    //final highFreqVars = controller.registry.values.where((v) => v.isHighFreq).toList();

    // 使用 select 仅仅监听高频变量列表的【结构】变化（比如新注册了一个变量）
    // 这样高频的数据波动不会通过 Provider 触发这里的 build
    final highFreqVars = context.select<DeviceController, List<RegisteredVar>>(
      (c) => c.registry.values.where((v) => v.isHighFreq).toList()
    );

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              _buildSidebar(highFreqVars),
              // -----------------------------------------------------------
              // 2. 右侧绘图区 (集成 InteractiveScope)
              // -----------------------------------------------------------
              Expanded(
                child: InteractiveScope(
                  dataPoints: multiChannelPoints,
                  varIds: highFreqVars.map((e) => e.id).toList(),
                  colors: colors,
                  deltaTime: _deltaTime, // <--- 传入这个关键参数
                ),
              ),
            ],
          )
        ),
        // -----------------------------------------------------------
        // 3. 底部设置栏 (新增)
        // -----------------------------------------------------------
        Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          color: const Color(0xFF333333),
          child: Row(
            children: [
              const Icon(Icons.settings, color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              const Text("配置:", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              const SizedBox(width: 20),
              
              // 缓冲区设置
              _buildInput("缓冲区大小(点)", _bufferCtrl),
              const SizedBox(width: 20),
              
              // Delta T 设置
              _buildInput("采样间隔 Δt (ms)", _dtCtrl),
              
              const SizedBox(width: 20),
              ElevatedButton(
                onPressed: _updateConfig,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
                child: const Text("应用设置"),
              ),
              const SizedBox(width: 20),
              OutlinedButton.icon(
                onPressed: _clearBuffer,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text("清空显示"),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent, // 红色文字警告这是删除操作
                  side: const BorderSide(color: Colors.redAccent),
                  padding: const EdgeInsets.symmetric(horizontal: 16)
                ),
              ),
              const Spacer(),
              // 显示当前状态
              Text(
                "Total: $_bufferSize pts | Rate: ${_deltaTime}ms/pt",
                style: const TextStyle(color: Colors.white38, fontSize: 12)
              ),
              
            ],
          ),
        )
        
        
      ],
    );
  }
  // 辅助构建输入框的小组件
  Widget _buildInput(String label, TextEditingController ctrl) {
    return Row(
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(width: 8),
        SizedBox(
          width: 60,
          height: 30,
          child: TextField(
            controller: ctrl,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              filled: true,
              fillColor: Colors.black26,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              border: OutlineInputBorder(borderSide: BorderSide.none),
            ),
            onSubmitted: (_) => _updateConfig(),
          ),
        ),
      ],
    );
  }

 // 构建侧边栏，每一行都是一个独立的低频刷新组件
  Widget _buildSidebar(List<RegisteredVar> highFreqVars) {
    return Container(
      width: 160,
      decoration: BoxDecoration(
        color: const Color(0xFF252526),
        border: Border(right: BorderSide(color: Colors.white.withOpacity(0.1)))
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(12.0),
            child: Text("通道列表", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
          ),
          const Divider(height: 1, color: Colors.white24),
          Expanded(
            child: ListView.builder(
              itemCount: highFreqVars.length,
              itemBuilder: (ctx, i) {
                final v = highFreqVars[i];
                // 使用刚才定义的低频刷新 Tile
                return ChannelValueTile(
                  key: ValueKey(v.id),
                  varId: v.id,
                  name: v.name,
                  color: colors[i % colors.length],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
class InteractiveScope extends StatefulWidget {
  final Map<int, List<double>> dataPoints;
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
  // // 封装一个对齐到最右侧的辅助函数
  // void _alignToRightest() {
  //   int maxLen = 0;
  //   for (var p in widget.dataPoints.values) {
  //     if (p.length > maxLen) maxLen = p.length;
  //   }
    
  //   if (maxLen > 0) {
  //     // 获取当前控件宽度 (如果 context 还没 layout 好，给个默认值)
  //     final drawWidth = context.size?.width ?? 400;   //报错点
  //     final chartWidth = drawWidth - _yAxisWidth;
      
  //     // 目标 Offset = 控件宽 - (数据总长 * 缩放) - 右边距
  //     // 这样就能保证最后一个点刚好在屏幕右边缘
  //     setState(() {
  //        // 留 10px 边距美观一点
  //       _offsetX = chartWidth + _yAxisWidth - (maxLen * _scaleX) - 10;
  //     });
  //   }
  // } 
  //现在我们在didUpdateWidget中直接调用了含有context.size的_alignToRightest，而这个didUpdate是在构建阶段调用的，此时Layout多大还没有计算出来
  // //由于控件宽度只能在build后获得，所以我们把这部分逻辑直接封在了build函数中
  
  // void _handleWheel(PointerScrollEvent event, BoxConstraints constraints) {
  //   setState(() {
  //     final double zoomFactor = 0.1;
  //     final bool isZoomIn = event.scrollDelta.dy < 0;
  //     final double scaleMultiplier = isZoomIn ? (1 + zoomFactor) : (1 - zoomFactor);

  //     // 判断鼠标位置
  //     final localPos = event.localPosition;
  //     final bool inYAxisArea = localPos.dx < _yAxisWidth;
      
  //     _autoLock = false; // 用户介入，取消自动跟随
  //     // 如果在左侧 Y轴区域，缩放 Y
  //     if (inYAxisArea) {
  //       final double focalPointY = localPos.dy;
  //       // 缩放公式：保持鼠标指向的数值在屏幕位置不变
  //       // newOffset = mouse - (mouse - oldOffset) * scaleRatio
  //       _offsetY = focalPointY - (focalPointY - _offsetY) * scaleMultiplier;
  //       _scaleY *= scaleMultiplier;
  //     } 
  //     // 否则缩放 X (以鼠标当前X为中心)
  //     else {
  //       final double focalPointX = localPos.dx;
  //       // 如果当前是锁定状态，缩放时应该以“最右侧”为锚点，而不是鼠标位置
  //       // 这样符合直觉：放大时查看最新细节，缩小时查看更多历史
  //       if (_autoLock) {
  //          _scaleX *= scaleMultiplier;
  //          // 缩放完立刻重新对齐最右边
  //          _alignToRightest();
  //       } else {
  //          // 非锁定状态，以鼠标为中心缩放
  //          _offsetX = focalPointX - (focalPointX - _offsetX) * scaleMultiplier;
  //          _scaleX *= scaleMultiplier;
  //       }
  //     }
  //   });
  // }
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

class ProScopePainter extends CustomPainter {
  final Map<int, List<double>> allPoints;
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
      if (points == null || points.isEmpty) continue;

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

class ChannelValueTile extends StatefulWidget {
  final int varId;
  final String name;
  final Color color;

  const ChannelValueTile({
    super.key, 
    required this.varId, 
    required this.name, 
    required this.color
  });

  @override
  State<ChannelValueTile> createState() => _ChannelValueTileState();
}

class _ChannelValueTileState extends State<ChannelValueTile> {
  Timer? _lowFreqTimer;
  double _displayValue = 0.0;

  @override
  void initState() {
    super.initState();
    // 启动低频心跳：每 100ms 刷新一次数值显示
    _lowFreqTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) return;

      // 从 Provider 中直接读取当前值，不订阅监听
      final controller = context.read<DeviceController>();
      final newValue = controller.registry[widget.varId]?.value?.toDouble() ?? 0.0;

      // 如果数值变了，才触发局部渲染
      if (newValue != _displayValue) {
        setState(() {
          _displayValue = newValue;
        });
      }
    });
  }

  @override
  void dispose() {
    _lowFreqTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 这个 build 每一行每秒最多运行 10 次，性能开销极低
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Container(width: 4, height: 20, color: widget.color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.name, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                Text(
                  _displayValue.toStringAsFixed(2),
                  style: TextStyle(
                    color: widget.color, 
                    fontWeight: FontWeight.bold, 
                    fontFamily: 'monospace'
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}