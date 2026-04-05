import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/device_controller.dart';

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
