import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/device_controller.dart';
import 'attitude_indicator.dart';

class AttitudeWindowContent extends StatefulWidget {
  const AttitudeWindowContent({super.key});

  @override
  State<AttitudeWindowContent> createState() => _AttitudeWindowContentState();
}

class _AttitudeWindowContentState extends State<AttitudeWindowContent> {
  late final ValueNotifier<Attitude> _attitude;
  StreamSubscription? _sub;

  bool _isDrone = true;
  bool _useDegrees = true;

  int? _pitchId;
  int? _rollId;
  int? _yawId;

  @override
  void initState() {
    super.initState();
    _attitude = ValueNotifier(const Attitude.zero());
    _resolveVarIds();
    _startListening();
  }

  void _resolveVarIds() {
    final ctrl = context.read<DeviceController>();
    _pitchId = null;
    _rollId = null;
    _yawId = null;
    for (final entry in ctrl.registry.entries) {
      final name = entry.value.name.toLowerCase().trim();
      if (name == 'pitch') _pitchId = entry.key;
      if (name == 'roll') _rollId = entry.key;
      if (name == 'yaw') _yawId = entry.key;
    }
  }

  void _startListening() {
    final ctrl = context.read<DeviceController>();
    _sub = ctrl.highFreqStream.listen((e) {
      final id = e.key;
      final value = e.value;
      if (id != _pitchId && id != _rollId && id != _yawId) return;

      double rad = value;
      if (_useDegrees) rad = value * pi / 180.0;

      final old = _attitude.value;
      Attitude next = old;
      if (id == _pitchId) next = old.copyWith(pitch: rad);
      if (id == _rollId) next = old.copyWith(roll: rad);
      if (id == _yawId) next = old.copyWith(yaw: rad);

      if (next != old) {
        _attitude.value = next;
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _attitude.dispose();
    super.dispose();
  }

  String _fmt(double rad) {
    if (_useDegrees) {
      return '${(rad * 180.0 / pi).toStringAsFixed(1)}°';
    }
    return '${rad.toStringAsFixed(3)} rad';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Retry resolving IDs if not found yet (registry may update after window opens)
    if (_pitchId == null && _rollId == null && _yawId == null) {
      _resolveVarIds();
    }
    final hasData = _pitchId != null || _rollId != null || _yawId != null;

    return SizedBox(
      width: 560,
      height: 520,
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
            child: Row(
              children: [
                Text(
                  '3D 姿态指示器',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          // Controls
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                // Model switch
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('无人机')),
                    ButtonSegment(value: false, label: Text('小车')),
                  ],
                  selected: {_isDrone},
                  onSelectionChanged: (set) {
                    if (set.isNotEmpty) {
                      setState(() => _isDrone = set.first);
                    }
                  },
                ),
                const SizedBox(width: 12),
                // Unit switch
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('°')),
                    ButtonSegment(value: false, label: Text('rad')),
                  ],
                  selected: {_useDegrees},
                  onSelectionChanged: (set) {
                    if (set.isNotEmpty) {
                      setState(() => _useDegrees = set.first);
                    }
                  },
                ),
                const Spacer(),
                // Value readout
                ValueListenableBuilder<Attitude>(
                  valueListenable: _attitude,
                  builder: (_, att, _) {
                    return Row(
                      children: [
                        _ValueChip('P', _fmt(att.pitch)),
                        const SizedBox(width: 8),
                        _ValueChip('R', _fmt(att.roll)),
                        const SizedBox(width: 8),
                        _ValueChip('Y', _fmt(att.yaw)),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),

          // Canvas
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: !hasData
                      ? Center(
                          child: Text(
                            '未检测到 pitch / roll / yaw 高频变量\n请确保下位机已注册对应变量',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        )
                      : ValueListenableBuilder<Attitude>(
                          valueListenable: _attitude,
                          builder: (_, att, _) {
                            return CustomPaint(
                              painter: AttitudePainter(
                                attitude: att,
                                isDrone: _isDrone,
                                color: colorScheme.primary,
                              ),
                              size: Size.infinite,
                            );
                          },
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ValueChip extends StatelessWidget {
  final String label;
  final String value;

  const _ValueChip(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 12,
          fontFamily: 'Consolas',
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

void showAttitudeWindow(BuildContext context) {
  showDialog(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => const Dialog(
      insetPadding: EdgeInsets.all(40),
      child: AttitudeWindowContent(),
    ),
  );
}
