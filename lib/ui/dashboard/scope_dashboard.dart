import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/device_controller.dart';
import '../../core/models/registered_var.dart';
import '../../ring_buffer.dart';
import '../scope/channel_value_tile.dart';
import '../scope/interactive_scope.dart';

// ─── 波形区独立组件：自行管理数据流 & 60Hz 刷新，不拖累整棵 ScopeDashboard 树 ───

class _ScopeChart extends StatefulWidget {
  final List<int> varIds;
  final List<Color> colors;
  final double deltaTime;
  final int bufferSize;

  const _ScopeChart({
    super.key,
    required this.varIds,
    required this.colors,
    required this.deltaTime,
    required this.bufferSize,
  });

  @override
  State<_ScopeChart> createState() => _ScopeChartState();
}

class _ScopeChartState extends State<_ScopeChart> {
  final Map<int, RingBuffer> multiChannelBuffers = {};
  StreamSubscription? _subscription;
  Timer? _refreshTimer;
  int _scopeViewKey = 0;
  final int maxPoints = 2000;

  @override
  void initState() {
    super.initState();
    final controller = context.read<DeviceController>();

    _subscription = controller.highFreqStream.listen((data) {
      if (!multiChannelBuffers.containsKey(data.key)) {
        multiChannelBuffers[data.key] = RingBuffer(widget.bufferSize);
      }
      multiChannelBuffers[data.key]!.add(data.value);
    });

    _refreshTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (mounted) setState(() {});
    });
  }

  void resizeBuffers(int newSize) {
    for (final buffer in multiChannelBuffers.values) {
      buffer.resize(newSize);
    }
  }

  void clear() {
    setState(() {
      multiChannelBuffers.clear();
      _scopeViewKey++;
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveScope(
      key: ValueKey(_scopeViewKey),
      dataPoints: multiChannelBuffers,
      varIds: widget.varIds,
      colors: widget.colors,
      deltaTime: widget.deltaTime,
    );
  }
}

// ─── ScopeDashboard：仅负责布局 + 配置栏 + 侧边栏，不再被 60Hz setState 拖累 ───

class ScopeDashboard extends StatefulWidget {
  const ScopeDashboard({super.key});

  @override
  State<ScopeDashboard> createState() => _ScopeDashboardState();
}

class _ScopeDashboardState extends State<ScopeDashboard> {
  final GlobalKey<_ScopeChartState> _chartKey = GlobalKey<_ScopeChartState>();

  int _bufferSize = 2000;
  double _deltaTime = 20.0;

  late TextEditingController _bufferCtrl;
  late TextEditingController _dtCtrl;

  final List<Color> colors = [
    Colors.greenAccent,
    Colors.yellowAccent,
    Colors.cyanAccent,
    Colors.orangeAccent,
    Colors.purpleAccent
  ];

  @override
  void initState() {
    super.initState();
    _bufferCtrl = TextEditingController(text: _bufferSize.toString());
    _dtCtrl = TextEditingController(text: _deltaTime.toString());
  }

  @override
  void dispose() {
    _bufferCtrl.dispose();
    _dtCtrl.dispose();
    super.dispose();
  }

  void _updateConfig() {
    int? newBuf = int.tryParse(_bufferCtrl.text);
    if (newBuf != null && newBuf > 10 && newBuf != _bufferSize) {
      _bufferSize = newBuf;
      _chartKey.currentState?.resizeBuffers(_bufferSize);
    }
    double? newDt = double.tryParse(_dtCtrl.text);
    if (newDt != null && newDt > 0) _deltaTime = newDt;

    setState(() {});
    FocusScope.of(context).unfocus();
  }

  void _clearBuffer() {
    _chartKey.currentState?.clear();
  }

  @override
  Widget build(BuildContext context) {
    // 用稳定的指纹做 selector，避免每次 notifyListeners 都因 new list instance 触发重建
    final highFreqVars = _selectHighFreqVars(context);

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              _Sidebar(highFreqVars: highFreqVars, colors: colors),
              Expanded(
                child: _ScopeChart(
                  key: _chartKey,
                  varIds: highFreqVars.map((e) => e.id).toList(),
                  colors: colors,
                  deltaTime: _deltaTime,
                  bufferSize: _bufferSize,
                ),
              ),
            ],
          ),
        ),
        _buildSettingsBar(),
      ],
    );
  }

  // 用 ID 列表的字符串指纹做比较，只有变量增删时才算变化
  List<RegisteredVar> _selectHighFreqVars(BuildContext context) {
    // 用 select 订阅变量变化（只看 ID 指纹，只有增删才算变化）
    context.select<DeviceController, String>(
      (c) => c.registry.values
          .where((v) => v.isHighFreq)
          .map((v) => '${v.id}')
          .join(','),
    );
    final registry = context.read<DeviceController>().registry;
    return registry.values.where((v) => v.isHighFreq).toList();
  }

  Widget _buildSettingsBar() {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: const Color(0xFF333333),
      child: Row(
        children: [
          const Icon(Icons.settings, color: Colors.white70, size: 18),
          const SizedBox(width: 8),
          const Text("配置:", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          const SizedBox(width: 20),
          _buildInput("缓冲区大小(点)", _bufferCtrl),
          const SizedBox(width: 20),
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
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
          const Spacer(),
          Text(
            "Total: $_bufferSize pts | Rate: ${_deltaTime}ms/pt",
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

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
}

// ─── 侧边栏独立 StatelessWidget：被 const 保护，仅在变量列表变化时重建 ───

class _Sidebar extends StatelessWidget {
  final List<RegisteredVar> highFreqVars;
  final List<Color> colors;

  const _Sidebar({required this.highFreqVars, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      decoration: BoxDecoration(
        color: const Color(0xFF252526),
        border: Border(right: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
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
