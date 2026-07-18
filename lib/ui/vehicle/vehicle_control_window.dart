import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/services/device_controller.dart';
import '../../debug_protocol.dart';

enum _DriveMode { variableWrite, command }

// ── Global overlay management ──

OverlayEntry? _globalOverlay;

void showVehicleControlWindow(BuildContext context) {
  if (_globalOverlay != null) return; // already showing

  final overlay = Overlay.of(context);
  _globalOverlay = OverlayEntry(
    builder: (_) => _VehicleFloatingPanel(
      onClose: () {
        _globalOverlay?.remove();
        _globalOverlay = null;
      },
    ),
  );
  overlay.insert(_globalOverlay!);
}

// ── Floating panel wrapper ──

class _VehicleFloatingPanel extends StatefulWidget {
  final VoidCallback onClose;

  const _VehicleFloatingPanel({required this.onClose});

  @override
  State<_VehicleFloatingPanel> createState() => _VehicleFloatingPanelState();
}

class _VehicleFloatingPanelState extends State<_VehicleFloatingPanel> {
  double _x = 100;
  double _y = 80;
  bool _minimized = false;

  @override
  void initState() {
    super.initState();
    // Default to right side of screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final size = MediaQuery.of(context).size;
      setState(() {
        _x = size.width - 440;
        _y = 60;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: _x.clamp(0, MediaQuery.of(context).size.width - 100),
          top: _y.clamp(0, MediaQuery.of(context).size.height - 100),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(10),
            shadowColor: Colors.black38,
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              ),
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Draggable header
                  GestureDetector(
                    onPanUpdate: (d) {
                      setState(() {
                        _x += d.delta.dx;
                        _y += d.delta.dy;
                      });
                    },
                    child: Container(
                      height: 36,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          Icon(Icons.drag_indicator, size: 14,
                              color: Theme.of(context).colorScheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Text('车辆操控',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
                          const Spacer(),
                          IconButton(
                            icon: Icon(
                              _minimized ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                              size: 18,
                            ),
                            onPressed: () => setState(() => _minimized = !_minimized),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                            tooltip: _minimized ? '展开' : '收起',
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: widget.onClose,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                            tooltip: '关闭',
                          ),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ),
                  // Content (collapsible)
                  if (!_minimized)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 520),
                      child: SingleChildScrollView(
                        child: _VehicleControlContent(onClose: widget.onClose),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Vehicle control content ──

class _VehicleControlContent extends StatefulWidget {
  final VoidCallback onClose;

  const _VehicleControlContent({required this.onClose});

  @override
  State<_VehicleControlContent> createState() => _VehicleControlContentState();
}

class _VehicleControlContentState extends State<_VehicleControlContent> {
  double _forwardSpeed = 100;
  double _turnSpeed = 50;
  double _backwardSpeed = 80;

  _DriveMode _driveMode = _DriveMode.variableWrite;

  int? _lSpeedId;
  int? _rSpeedId;

  String _activeKey = '';
  bool _controlActive = false;

  final _focusNode = FocusNode();

  final _forwardCtrl = TextEditingController(text: '100');
  final _turnCtrl = TextEditingController(text: '50');
  final _backwardCtrl = TextEditingController(text: '80');

  static String get _configPath {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
    return '$home/.flowave/vehicle_control_config.json';
  }

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _resolveVarIds();
  }

  @override
  void dispose() {
    _forwardCtrl.dispose();
    _turnCtrl.dispose();
    _backwardCtrl.dispose();
    _stopControl();
    _focusNode.dispose();
    super.dispose();
  }

  void _resolveVarIds() {
    final ctrl = context.read<DeviceController>();
    _lSpeedId = null;
    _rSpeedId = null;
    for (final entry in ctrl.registry.entries) {
      final name = entry.value.name.toLowerCase().trim();
      if (name == 'l_speed') _lSpeedId = entry.key;
      if (name == 'r_speed') _rSpeedId = entry.key;
    }
  }

  bool get _varsReady => _lSpeedId != null && _rSpeedId != null;

  bool get _canStart {
    if (_driveMode == _DriveMode.command) {
      return context.read<DeviceController>().isConnected;
    }
    return _varsReady;
  }

  // ── Config persistence ──

  Future<void> _loadConfig() async {
    try {
      final file = File(_configPath);
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        _forwardSpeed = (json['forward'] as num?)?.toDouble() ?? 100;
        _turnSpeed = (json['turn'] as num?)?.toDouble() ?? 50;
        _backwardSpeed = (json['backward'] as num?)?.toDouble() ?? 80;
        _forwardCtrl.text = _forwardSpeed.toStringAsFixed(1);
        _turnCtrl.text = _turnSpeed.toStringAsFixed(1);
        _backwardCtrl.text = _backwardSpeed.toStringAsFixed(1);
        final mode = json['mode'] as String?;
        if (mode == 'command') _driveMode = _DriveMode.command;
      }
    } catch (_) {}
  }

  // ── Speed parsing ──

  void _parseSpeeds() {
    _forwardSpeed = double.tryParse(_forwardCtrl.text) ?? 0;
    _turnSpeed = double.tryParse(_turnCtrl.text) ?? 0;
    _backwardSpeed = double.tryParse(_backwardCtrl.text) ?? 0;
    if (_activeKey.isNotEmpty) _writeSpeeds();
  }

  // ── Control start/stop ──

  void _startControl() {
    _controlActive = true;
    if (FocusManager.instance.primaryFocus != null) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    _focusNode.requestFocus();
    setState(() {});
  }

  void _stopControl() {
    _controlActive = false;
    if (_activeKey.isNotEmpty) {
      _activeKey = '';
      if (_driveMode == _DriveMode.command) {
        _writeCommand('stop');
      } else {
        _writeZero();
      }
    }
    setState(() {});
  }

  // ── Keyboard ──

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_controlActive) return KeyEventResult.ignored;

    String? k;
    if (event.logicalKey == LogicalKeyboardKey.keyW) {
      k = 'W';
    } else if (event.logicalKey == LogicalKeyboardKey.keyA) {
      k = 'A';
    } else if (event.logicalKey == LogicalKeyboardKey.keyS) {
      k = 'S';
    } else if (event.logicalKey == LogicalKeyboardKey.keyD) {
      k = 'D';
    } else {
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent) {
      if (_activeKey.isEmpty) {
        _activeKey = k;
        if (_driveMode == _DriveMode.command) {
          _writeCommand(_keyToCommand(k));
        } else {
          _writeSpeeds();
        }
        setState(() {});
      }
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent && _activeKey == k) {
      _activeKey = '';
      if (_driveMode == _DriveMode.command) {
        _writeCommand('stop');
      } else {
        _writeZero();
      }
      setState(() {});
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  // ── Variable-write mode ──

  void _writeSpeeds() {
    final (l, r) = _calc();
    _writeVar(_lSpeedId, l);
    _writeVar(_rSpeedId, r);
  }

  void _writeZero() {
    _writeVar(_lSpeedId, 0);
    _writeVar(_rSpeedId, 0);
  }

  (double, double) _calc() {
    return switch (_activeKey) {
      'W' => (_forwardSpeed, _forwardSpeed),
      'S' => (-_backwardSpeed, -_backwardSpeed),
      'A' => (-_turnSpeed, _turnSpeed),
      'D' => (_turnSpeed, -_turnSpeed),
      _ => (0.0, 0.0),
    };
  }

  void _writeVar(int? varId, double value) {
    if (varId == null) return;
    context.read<DeviceController>().setVariableValue(varId, value);
  }

  // ── Command mode ──

  String _keyToCommand(String key) {
    return switch (key) {
      'W' => 'forward',
      'A' => 'left',
      'S' => 'backward',
      'D' => 'right',
      _ => 'stop',
    };
  }

  void _writeCommand(String cmd) {
    context.read<DeviceController>().sendData(DebugProtocol.packTextCmd(cmd));
  }

  // ── Labels ──

  String _activeKeyLabel() {
    return switch (_activeKey) {
      'W' => '前进',
      'S' => '后退',
      'A' => '左转',
      'D' => '右转',
      '' => '静止',
      _ => _activeKey,
    };
  }

  String _activeKeyCommand() {
    return _keyToCommand(_activeKey);
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    _resolveVarIds();

    final (curL, curR) = _activeKey.isEmpty ? (0.0, 0.0) : _calc();
    final isVarMode = _driveMode == _DriveMode.variableWrite;

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKeyEvent,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drive type + mode selector
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('两轮差速', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
                const Spacer(),
                SegmentedButton<_DriveMode>(
                  segments: const [
                    ButtonSegment(value: _DriveMode.variableWrite, label: Text('变量写入', style: TextStyle(fontSize: 11))),
                    ButtonSegment(value: _DriveMode.command, label: Text('指令模式', style: TextStyle(fontSize: 11))),
                  ],
                  selected: {_driveMode},
                  onSelectionChanged: _controlActive
                      ? null
                      : (set) {
                          if (set.isNotEmpty) {
                            setState(() => _driveMode = set.first);
                          }
                        },
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Variable status or connection status
            if (isVarMode) ...[
              _VarStatus(name: 'L_Speed', varId: _lSpeedId),
              _VarStatus(name: 'R_Speed', varId: _rSpeedId),
            ] else
              _buildConnectionStatus(cs),

            const Divider(height: 20),

            // Speed inputs or command mapping
            if (isVarMode) ...[
              _SpeedInput(label: '前进速度', controller: _forwardCtrl, enabled: !_controlActive, onChanged: (_) => _parseSpeeds()),
              _SpeedInput(label: '转向速度', controller: _turnCtrl, enabled: !_controlActive, onChanged: (_) => _parseSpeeds()),
              _SpeedInput(label: '后退速度', controller: _backwardCtrl, enabled: !_controlActive, onChanged: (_) => _parseSpeeds()),
            ] else ...[
              const Text('指令映射:', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              _CmdLine('W', 'forward', '前进', cs.primary),
              _CmdLine('A', 'left', '左转', cs.primary),
              _CmdLine('S', 'backward', '后退', cs.primary),
              _CmdLine('D', 'right', '右转', cs.primary),
              _CmdLine('释放', 'stop', '停止', Colors.orange),
            ],

            const Divider(height: 20),

            // Preview
            if (isVarMode)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('轮速映射:', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  _PreviewLine('W', '+${_forwardSpeed.toStringAsFixed(1)}', '+${_forwardSpeed.toStringAsFixed(1)}'),
                  _PreviewLine('A', '-${_turnSpeed.toStringAsFixed(1)}', '+${_turnSpeed.toStringAsFixed(1)}'),
                  _PreviewLine('S', '-${_backwardSpeed.toStringAsFixed(1)}', '-${_backwardSpeed.toStringAsFixed(1)}'),
                  _PreviewLine('D', '+${_turnSpeed.toStringAsFixed(1)}', '-${_turnSpeed.toStringAsFixed(1)}'),
                ],
              ),

            const Divider(height: 20),

            // Current status
            Row(
              children: [
                Text('按键: [${_activeKey.isEmpty ? "无" : _activeKey}]  ', style: const TextStyle(fontSize: 12)),
                Text('状态: ${_activeKeyLabel()}',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                        color: _activeKey.isEmpty ? cs.onSurfaceVariant : cs.primary)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              isVarMode
                  ? 'L_Speed: ${curL.toStringAsFixed(1)}    R_Speed: ${curR.toStringAsFixed(1)}'
                  : '最后指令: "${_activeKeyCommand()}"',
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 8),

            // Warnings
            if (isVarMode && !_varsReady && !_controlActive)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('未检测到 L_Speed / R_Speed 变量', style: TextStyle(fontSize: 11, color: cs.error)),
              ),
            if (!isVarMode && !_canStart && !_controlActive)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('指令模式需要先连接设备', style: TextStyle(fontSize: 11, color: cs.error)),
              ),

            // Hint
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                _controlActive ? 'WASD 操控中...' : '配置后点开始，WASD 操控',
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
              ),
            ),

            // Button
            ElevatedButton.icon(
              onPressed: _canStart
                  ? () {
                      if (_controlActive) {
                        _stopControl();
                      } else {
                        _startControl();
                      }
                    }
                  : null,
              icon: Icon(_controlActive ? Icons.stop : Icons.play_arrow, size: 16),
              label: Text(_controlActive ? '停止操控' : '开始操控', style: const TextStyle(fontSize: 13)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _controlActive ? Colors.redAccent : cs.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionStatus(ColorScheme cs) {
    final isConnected = context.read<DeviceController>().isConnected;
    return Row(
      children: [
        const Text('连接状态 ', style: TextStyle(fontFamily: 'Consolas', fontSize: 12)),
        Icon(isConnected ? Icons.check_circle : Icons.cancel, size: 14,
            color: isConnected ? Colors.green : cs.error),
        const SizedBox(width: 4),
        Text(isConnected ? '已连接' : '未连接',
            style: TextStyle(fontSize: 12, color: isConnected ? Colors.green : cs.error)),
      ],
    );
  }
}

// ── Widgets ──

class _VarStatus extends StatelessWidget {
  final String name;
  final int? varId;

  const _VarStatus({required this.name, required this.varId});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final found = varId != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(name, style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
          const SizedBox(width: 8),
          Icon(found ? Icons.check_circle : Icons.cancel, size: 14,
              color: found ? Colors.green : cs.error),
          const SizedBox(width: 4),
          Text(found ? '已检测到' : '未找到',
              style: TextStyle(fontSize: 11, color: found ? Colors.green : cs.error)),
          if (found) ...[
            const SizedBox(width: 4),
            Text('(ID: $varId)', style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

class _SpeedInput extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String>? onChanged;

  const _SpeedInput({
    required this.label,
    required this.controller,
    required this.enabled,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(width: 60, child: Text(label, style: const TextStyle(fontSize: 12))),
          SizedBox(
            width: 90,
            height: 30,
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              readOnly: !enabled,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(5)),
                isDense: true,
              ),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewLine extends StatelessWidget {
  final String keyLabel;
  final String l;
  final String r;

  const _PreviewLine(this.keyLabel, this.l, this.r);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text('  $keyLabel:  L=$l    R=$r',
          style: const TextStyle(fontSize: 11, fontFamily: 'Consolas')),
    );
  }
}

class _CmdLine extends StatelessWidget {
  final String keyLabel;
  final String cmd;
  final String desc;
  final Color color;

  const _CmdLine(this.keyLabel, this.cmd, this.desc, this.color);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(width: 36,
              child: Text(keyLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text('"$cmd"', style: TextStyle(fontSize: 11, fontFamily: 'Consolas', color: color)),
          ),
          const SizedBox(width: 6),
          Text(desc, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}
