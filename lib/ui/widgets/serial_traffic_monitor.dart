import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/device_controller.dart';

class SerialTrafficMonitor extends StatefulWidget {
  const SerialTrafficMonitor({super.key});

  @override
  State<SerialTrafficMonitor> createState() => _SerialTrafficMonitorState();
}

class _SerialTrafficMonitorState extends State<SerialTrafficMonitor> {
  Timer? _timer;

  int _lastBytes = 0;
  String _speedStr = "0 B/s";
  double _loadPercent = 0.0;
  Color _statusColor = Colors.grey;

  @override
  void initState() {
    super.initState();
    // 10Hz 刷新率 (100ms)
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _updateTraffic());
  }

  void _updateTraffic() {
    if (!mounted) return;
    final ctrl = context.read<DeviceController>();

    if (!ctrl.isConnected) {
      if (_loadPercent != 0) {
        setState(() {
          _speedStr = "Offline";
          _loadPercent = 0.0;
          _statusColor = Colors.grey;
        });
      }
      return;
    }

    // 1. 计算增量 (Delta)
    final currentBytes = ctrl.totalRxBytes;
    final deltaBytes = currentBytes - _lastBytes;
    _lastBytes = currentBytes;

    // 2. 计算速率 (Bytes per second)
    // 因为是 100ms 采样一次，所以 1秒内的速率 = delta * 10
    final bytesPerSec = deltaBytes * 10;

    // 3. 计算占用率 (Load Percentage)
    // 串口理论模型：1 Byte ≈ 10 Bits (8数据位 + 1起始 + 1停止)
    // 带宽 (Bytes/s) = BaudRate / 10
    final baudRate = ctrl.selectedBaudRate;
    final maxBytesPerSec = baudRate / 10.0;

    double percent = 0.0;
    if (maxBytesPerSec > 0) {
      percent = bytesPerSec / maxBytesPerSec;
      if (percent > 1.0) percent = 1.0; // 理论上不应超过，除非缓冲区积压瞬间释放
    }

    // 4. 格式化文本
    String newSpeedStr;
    if (bytesPerSec > 1024) {
      newSpeedStr = "${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s";
    } else {
      newSpeedStr = "$bytesPerSec B/s";
    }

    // 5. 决定颜色 (负载越高颜色越深/越红)
    Color newColor;
    if (percent < 0.5)
      newColor = Colors.greenAccent;
    else if (percent < 0.8)
      newColor = Colors.orangeAccent;
    else
      newColor = Colors.redAccent;

    // 6. 只有显示内容变化时才 setState (性能优化)
    if (newSpeedStr != _speedStr || (percent - _loadPercent).abs() > 0.01) {
      setState(() {
        _speedStr = newSpeedStr;
        _loadPercent = percent;
        _statusColor = newColor;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 负载进度条图标
          SizedBox(
            width: 10,
            height: 24,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Container(color: Colors.white10),
                FractionallySizedBox(
                  heightFactor: _loadPercent,
                  child: Container(color: _statusColor),
                )
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                "RX Load: ${(_loadPercent * 100).toStringAsFixed(0)}%",
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  height: 1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _speedStr,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  height: 1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
