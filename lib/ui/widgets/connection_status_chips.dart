import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/device_controller.dart';

class ConnectionStatusChips extends StatelessWidget {
  const ConnectionStatusChips({super.key});

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
