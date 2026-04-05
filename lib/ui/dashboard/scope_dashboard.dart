import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/device_controller.dart';
import '../../core/models/registered_var.dart';
import '../../ring_buffer.dart';
import '../scope/channel_value_tile.dart';
import '../scope/interactive_scope.dart';

class ScopeDashboard extends StatefulWidget {
  const ScopeDashboard({super.key});

  @override
  State<ScopeDashboard> createState() => _ScopeDashboardState();
}

class _ScopeDashboardState extends State<ScopeDashboard> {
  // 存储高频数据点：ID -> List
  Map<int, RingBuffer> multiChannelBuffers = {};
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
      if (!multiChannelBuffers.containsKey(data.key)) {
        // 这里会直接使用当前最新的 _bufferSize 创建新 RingBuffer
        multiChannelBuffers[data.key] = RingBuffer(_bufferSize);
      }
      multiChannelBuffers[data.key]!.add(data.value);
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
      // 1. 解析新大小
      int? newBuf = int.tryParse(_bufferCtrl.text);

      // 2. 如果大小变了，执行 Resizing
      if (newBuf != null && newBuf > 10 && newBuf != _bufferSize) {
        _bufferSize = newBuf;

        // --- 核心修改：遍历所有已有的通道进行 Resize ---
        for (var buffer in multiChannelBuffers.values) {
          buffer.resize(_bufferSize);
        }
      }

      // 3. 解析 Delta Time
      double? newDt = double.tryParse(_dtCtrl.text);
      if (newDt != null && newDt > 0) _deltaTime = newDt;
    });

    FocusScope.of(context).unfocus();
  }

  //清空缓冲区逻辑
  void _clearBuffer() {
    setState(() {
      // 1. 清空所有通道的数据
      multiChannelBuffers.clear();

      // 2. 更新 Key，强制 InteractiveScope 重建
      // 这样可以将 缩放(Scale) 和 偏移(Offset) 重置回初始值
      _scopeViewKey++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // final controller = context.watch<DeviceController>(); //
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

                  dataPoints: multiChannelBuffers,
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
