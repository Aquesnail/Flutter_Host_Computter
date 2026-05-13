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
    required this.color,
  });

  @override
  State<ChannelValueTile> createState() => _ChannelValueTileState();
}

class _ChannelValueTileState extends State<ChannelValueTile> {
  static const _nameStyle = TextStyle(color: Colors.white70, fontSize: 11);
  static const _valueStyle = TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace');

  Timer? _lowFreqTimer;
  double _displayValue = 0.0;

  @override
  void initState() {
    super.initState();
    _lowFreqTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) return;
      final controller = context.read<DeviceController>();
      final newValue = controller.registry[widget.varId]?.value?.toDouble() ?? 0.0;
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
                Text(widget.name, style: _nameStyle),
                Text(
                  _displayValue.toStringAsFixed(2),
                  style: _valueStyle.copyWith(color: widget.color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
