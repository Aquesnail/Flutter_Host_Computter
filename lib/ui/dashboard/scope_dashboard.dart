import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/device_controller.dart';
import '../../core/models/registered_var.dart';
import '../../ring_buffer.dart';
import '../scope/channel_value_tile.dart';
import '../scope/interactive_scope.dart';
import '../scope/value_display_format.dart';

// ─── 波形区独立组件：自行管理数据流 & 60Hz 刷新，不拖累整棵 ScopeDashboard 树 ───

class _ScopeChart extends StatefulWidget {
  final List<int> varIds;
  final List<Color> colors;
  final double deltaTime;
  final int bufferSize;
  final Map<int, ValueDisplayFormat> displayFormats;
  final Map<int, IntDisplayFormat> intDisplayFormats;

  const _ScopeChart({
    super.key,
    required this.varIds,
    required this.colors,
    required this.deltaTime,
    required this.bufferSize,
    this.displayFormats = const {},
    this.intDisplayFormats = const {},
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
      displayFormats: widget.displayFormats,
      intDisplayFormats: widget.intDisplayFormats,
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

  final Set<int> _hiddenChannelIds = {};
  Map<int, ValueDisplayFormat> _channelDisplayFormats = {};
  Map<int, IntDisplayFormat> _channelIntDisplayFormats = {};

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

  void _toggleChannel(int varId) {
    setState(() {
      if (_hiddenChannelIds.contains(varId)) {
        _hiddenChannelIds.remove(varId);
      } else {
        _hiddenChannelIds.add(varId);
      }
    });
  }

  void _toggleFormat(int varId) {
    setState(() {
      final newFormats = Map<int, ValueDisplayFormat>.of(_channelDisplayFormats);
      final current = newFormats[varId] ?? ValueDisplayFormat.normal;
      newFormats[varId] = current == ValueDisplayFormat.normal
          ? ValueDisplayFormat.scientific
          : ValueDisplayFormat.normal;
      _channelDisplayFormats = newFormats;
    });
  }

  void _toggleIntFormat(int varId) {
    setState(() {
      final newFormats = Map<int, IntDisplayFormat>.of(_channelIntDisplayFormats);
      final current = newFormats[varId] ?? IntDisplayFormat.decimal;
      IntDisplayFormat next;
      switch (current) {
        case IntDisplayFormat.decimal:
          next = IntDisplayFormat.hex;
        case IntDisplayFormat.hex:
          next = IntDisplayFormat.binary;
        case IntDisplayFormat.binary:
          next = IntDisplayFormat.decimal;
      }
      newFormats[varId] = next;
      _channelIntDisplayFormats = newFormats;
    });
  }

  @override
  Widget build(BuildContext context) {
    final highFreqVars = _selectHighFreqVars(context);

    final visibleVars = highFreqVars.where((v) => !_hiddenChannelIds.contains(v.id)).toList();
    final visibleColors = <Color>[];
    for (final v in visibleVars) {
      final originalIndex = highFreqVars.indexWhere((hv) => hv.id == v.id);
      visibleColors.add(colors[originalIndex % colors.length]);
    }

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              _Sidebar(
                highFreqVars: highFreqVars,
                colors: colors,
                hiddenChannelIds: _hiddenChannelIds,
                channelDisplayFormats: _channelDisplayFormats,
                channelIntDisplayFormats: _channelIntDisplayFormats,
                onToggleChannel: _toggleChannel,
                onToggleFormat: _toggleFormat,
                onToggleIntFormat: _toggleIntFormat,
              ),
              Expanded(
                child: _ScopeChart(
                  key: _chartKey,
                  varIds: visibleVars.map((e) => e.id).toList(),
                  colors: visibleColors,
                  deltaTime: _deltaTime,
                  bufferSize: _bufferSize,
                  displayFormats: _channelDisplayFormats,
                  intDisplayFormats: _channelIntDisplayFormats,
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

// ─── 侧边栏：显示所有高频通道，支持开关和格式切换 ───

class _Sidebar extends StatelessWidget {
  final List<RegisteredVar> highFreqVars;
  final List<Color> colors;
  final Set<int> hiddenChannelIds;
  final Map<int, ValueDisplayFormat> channelDisplayFormats;
  final Map<int, IntDisplayFormat> channelIntDisplayFormats;
  final void Function(int) onToggleChannel;
  final void Function(int) onToggleFormat;
  final void Function(int) onToggleIntFormat;

  const _Sidebar({
    required this.highFreqVars,
    required this.colors,
    required this.hiddenChannelIds,
    required this.channelDisplayFormats,
    required this.channelIntDisplayFormats,
    required this.onToggleChannel,
    required this.onToggleFormat,
    required this.onToggleIntFormat,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 170,
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
                final isFloat = v.type == 6;
                return ChannelValueTile(
                  key: ValueKey(v.id),
                  varId: v.id,
                  name: v.name,
                  color: colors[i % colors.length],
                  isVisible: !hiddenChannelIds.contains(v.id),
                  displayFormat: channelDisplayFormats[v.id] ?? ValueDisplayFormat.normal,
                  intDisplayFormat: channelIntDisplayFormats[v.id] ?? IntDisplayFormat.decimal,
                  isFloat: isFloat,
                  onToggleVisibility: () => onToggleChannel(v.id),
                  onToggleFormat: isFloat ? () => onToggleFormat(v.id) : null,
                  onToggleIntFormat: !isFloat ? () => onToggleIntFormat(v.id) : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
