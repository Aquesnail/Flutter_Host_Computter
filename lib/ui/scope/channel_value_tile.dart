import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/device_controller.dart';
import 'value_display_format.dart';

class ChannelValueTile extends StatefulWidget {
  final int varId;
  final String name;
  final Color color;
  final bool isVisible;
  final ValueDisplayFormat displayFormat;
  final IntDisplayFormat intDisplayFormat;
  final bool isFloat;
  final double scale;
  final VoidCallback onToggleVisibility;
  final VoidCallback? onToggleFormat;
  final VoidCallback? onToggleIntFormat;
  final ValueChanged<double>? onUpdateScale;

  const ChannelValueTile({
    super.key,
    required this.varId,
    required this.name,
    required this.color,
    this.isVisible = true,
    this.displayFormat = ValueDisplayFormat.normal,
    this.intDisplayFormat = IntDisplayFormat.decimal,
    this.isFloat = false,
    this.scale = 1.0,
    required this.onToggleVisibility,
    this.onToggleFormat,
    this.onToggleIntFormat,
    this.onUpdateScale,
  });

  @override
  State<ChannelValueTile> createState() => _ChannelValueTileState();
}

class _ChannelValueTileState extends State<ChannelValueTile> {
  static const _nameStyle = TextStyle(fontSize: 11);
  static const _valueStyle = TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace');

  Timer? _lowFreqTimer;
  double _displayValue = 0.0;
  late TextEditingController _scaleCtrl;

  @override
  void initState() {
    super.initState();
    _scaleCtrl = TextEditingController(text: widget.scale.toString());
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
  void didUpdateWidget(ChannelValueTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scale != oldWidget.scale) {
      _scaleCtrl.text = widget.scale.toString();
    }
  }

  @override
  void dispose() {
    _lowFreqTimer?.cancel();
    _scaleCtrl.dispose();
    super.dispose();
  }

  void _applyScale() {
    final parsed = double.tryParse(_scaleCtrl.text);
    if (parsed != null && parsed > 0) {
      widget.onUpdateScale?.call(parsed);
    } else {
      // Revert to current scale on invalid input
      _scaleCtrl.text = widget.scale.toString();
    }
  }

  String _formattedValue() {
    if (widget.isFloat) {
      return formatValue(_displayValue, widget.displayFormat);
    }
    return formatIntValue(_displayValue, widget.intDisplayFormat);
  }

  String _intFormatLabel(IntDisplayFormat fmt) {
    switch (fmt) {
      case IntDisplayFormat.decimal:
        return 'Dec';
      case IntDisplayFormat.hex:
        return 'Hex';
      case IntDisplayFormat.binary:
        return 'Bin';
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.isVisible;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 20,
            color: visible ? widget.color : widget.color.withValues(alpha: 0.3),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.name,
                  style: _nameStyle.copyWith(color: visible ? Colors.white70 : Colors.white30),
                ),
                Text(
                  _formattedValue(),
                  style: _valueStyle.copyWith(
                    color: visible ? widget.color : widget.color.withValues(alpha: 0.3),
                  ),
                ),
              ],
            ),
          ),
          if (widget.onUpdateScale != null)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('×', style: TextStyle(fontSize: 9, color: Colors.white38)),
                  SizedBox(
                    width: 36,
                    height: 18,
                    child: TextField(
                      controller: _scaleCtrl,
                      style: const TextStyle(color: Colors.white70, fontSize: 10),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        filled: true,
                        fillColor: Colors.black38,
                        contentPadding: EdgeInsets.symmetric(horizontal: 3, vertical: 0),
                        border: OutlineInputBorder(borderSide: BorderSide.none),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _applyScale(),
                      onTapOutside: (_) => _applyScale(),
                    ),
                  ),
                ],
              ),
            ),
          if (widget.isFloat)
            GestureDetector(
              onTap: widget.onToggleFormat,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  widget.displayFormat == ValueDisplayFormat.normal ? 'F' : 'Sci',
                  style: const TextStyle(fontSize: 9, color: Colors.white38),
                ),
              ),
            ),
          if (!widget.isFloat)
            GestureDetector(
              onTap: widget.onToggleIntFormat,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  _intFormatLabel(widget.intDisplayFormat),
                  style: const TextStyle(fontSize: 9, color: Colors.white38),
                ),
              ),
            ),
          GestureDetector(
            onTap: widget.onToggleVisibility,
            child: Icon(
              visible ? Icons.visibility : Icons.visibility_off,
              size: 14,
              color: visible ? Colors.white38 : Colors.white12,
            ),
          ),
        ],
      ),
    );
  }
}
