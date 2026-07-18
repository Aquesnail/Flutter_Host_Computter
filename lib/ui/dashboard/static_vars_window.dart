import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/device_controller.dart';
import '../../debug_protocol.dart';
import 'static_vars_actions.dart';

// ── Global overlay management ──

OverlayEntry? _staticVarsOverlay;

void showStaticVarsWindow(BuildContext context) {
  if (_staticVarsOverlay != null) return;

  final overlay = Overlay.of(context);
  _staticVarsOverlay = OverlayEntry(
    builder: (_) => _StaticVarsFloatingPanel(
      onClose: () {
        _staticVarsOverlay?.remove();
        _staticVarsOverlay = null;
      },
    ),
  );
  overlay.insert(_staticVarsOverlay!);
}

// ── Floating panel wrapper ──

class _StaticVarsFloatingPanel extends StatefulWidget {
  final VoidCallback onClose;

  const _StaticVarsFloatingPanel({required this.onClose});

  @override
  State<_StaticVarsFloatingPanel> createState() => _StaticVarsFloatingPanelState();
}

class _StaticVarsFloatingPanelState extends State<_StaticVarsFloatingPanel> {
  double _x = 100;
  double _y = 80;
  bool _minimized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final size = MediaQuery.of(context).size;
      setState(() {
        _x = size.width - 620;
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
                border: Border.all(color: Colors.purple.withValues(alpha: 0.3)),
              ),
              constraints: const BoxConstraints(maxWidth: 600, maxHeight: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Draggable header (purple theme)
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
                        color: Colors.purple.withValues(alpha: 0.12),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          Icon(Icons.drag_indicator, size: 14,
                              color: Colors.purple.withValues(alpha: 0.8)),
                          const SizedBox(width: 6),
                          Text('静态变量',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.purple.withValues(alpha: 0.9))),
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
                    const Flexible(
                      child: _StaticVarsWindowContent(),
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

// ── Window content ──

class _StaticVarsWindowContent extends StatefulWidget {
  const _StaticVarsWindowContent();

  @override
  State<_StaticVarsWindowContent> createState() => _StaticVarsWindowContentState();
}

class _StaticVarsWindowContentState extends State<_StaticVarsWindowContent> {
  Timer? _pollTimer;
  final Map<int, String> _cachedValues = {};

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) _updateCache();
    });
  }

  void _updateCache() {
    final registry = context.read<DeviceController>().registry;
    bool changed = false;
    for (final entry in registry.entries) {
      if (!entry.value.isStatic) continue;
      final newText = entry.value.value is double
          ? (entry.value.value as double).toStringAsFixed(3)
          : entry.value.value.toString();
      if (_cachedValues[entry.key] != newText) {
        _cachedValues[entry.key] = newText;
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  // ── Single var edit dialog ──

  void _showEditDialog(int varId) {
    final controller = context.read<DeviceController>();
    final v = controller.registry[varId];
    if (v == null) return;

    final TextEditingController valCtrl = TextEditingController();
    valCtrl.text = v.value.toString();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("修改静态变量: ${v.name}"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("ID: ${v.id} | Type: ${VariableType.values[v.type].displayName}"),
            Text("Addr: 0x${v.addr.toRadixString(16).toUpperCase()}"),
            const SizedBox(height: 12),
            TextField(
              controller: valCtrl,
              decoration: const InputDecoration(labelText: "新值", border: OutlineInputBorder()),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          ElevatedButton(
            onPressed: () {
              try {
                final newVal = parseVarValue(valCtrl.text, v.type);
                controller.sendData(DebugProtocol.packWriteCmd(v.id, varTypeLength(v.type), newVal, v.type));
                controller.requestStaticRefresh(v.id);
                Navigator.pop(ctx);
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("数值格式错误: $e"), backgroundColor: Colors.red),
                );
              }
            },
            child: const Text("写入"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final registry = context.read<DeviceController>().registry;
    final isConnected = context.read<DeviceController>().isConnected;
    final groups = buildStaticVarGroups(registry);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Connection warning
        if (!isConnected)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: Colors.orange.withValues(alpha: 0.15),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.warning_amber, size: 14, color: Colors.orange.shade700),
                const SizedBox(width: 6),
                Text('设备未连接，写入功能不可用',
                    style: TextStyle(fontSize: 11, color: Colors.orange.shade700)),
              ],
            ),
          ),

        // Action bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.3))),
          ),
          child: Row(
            children: [
              _ActionChip(Icons.refresh, '全部刷新', () => refreshAllStaticVars(context)),
              const SizedBox(width: 4),
              _ActionChip(Icons.upload, '全部写入', () => writeAllStaticVars(context)),
              const SizedBox(width: 4),
              _ActionChip(Icons.download, '导入', () => importStaticVarsFromJson(context)),
              const SizedBox(width: 4),
              _ActionChip(Icons.save, '导出', () => exportStaticVarsToJson(context)),
              const Spacer(),
              Text('${groups.length} 组', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ],
          ),
        ),

        // Card grid
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.storage_outlined, size: 40, color: Colors.grey.withValues(alpha: 0.4)),
                const SizedBox(height: 8),
                Text("暂无静态变量",
                    style: TextStyle(color: Colors.grey.withValues(alpha: 0.6), fontSize: 13)),
              ],
            ),
          )
        else
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final group in groups)
                    if (group.isArray)
                      _StaticVarArrayCard(group: group)
                    else
                      _StaticVarCard(
                        varId: group.vars.first.id,
                        onTap: () => _showEditDialog(group.vars.first.id),
                      ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionChip(this.icon, this.label, this.onTap);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.purple.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: Colors.purple.withValues(alpha: 0.8)),
              const SizedBox(width: 3),
              Text(label,
                  style: TextStyle(fontSize: 11, color: Colors.purple.withValues(alpha: 0.8), fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Single variable card ──

class _StaticVarCard extends StatelessWidget {
  final int varId;
  final VoidCallback onTap;

  const _StaticVarCard({required this.varId, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = context.read<DeviceController>().registry[varId];
    if (v == null) return const SizedBox.shrink();

    final valueText = v.value is double
        ? (v.value as double).toStringAsFixed(4)
        : v.value.toString();
    final typeName = v.type < VariableType.values.length
        ? VariableType.values[v.type].displayName
        : '?';

    return SizedBox(
      width: 185,
      child: Material(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
        elevation: 1,
        shadowColor: Colors.black26,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Name row
                Row(
                  children: [
                    Expanded(
                      child: Text(v.name,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.purple.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('#${v.id}',
                          style: TextStyle(fontSize: 9, color: Colors.purple.withValues(alpha: 0.8))),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Value (large monospace)
                Text(valueText,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Consolas',
                        color: Colors.purple.withValues(alpha: 0.9))),
                const SizedBox(height: 6),
                // Bottom row: type + refresh
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(typeName, style: const TextStyle(fontSize: 10)),
                    ),
                    if (v.isPeri)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.purple.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Text('PERI', style: TextStyle(fontSize: 8, color: Colors.purple)),
                        ),
                      ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => context.read<DeviceController>().requestStaticRefresh(varId),
                      child: Icon(Icons.refresh, size: 15, color: Colors.purple.withValues(alpha: 0.6)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Array group card ──

class _StaticVarArrayCard extends StatelessWidget {
  final StaticVarGroup group;

  const _StaticVarArrayCard({required this.group});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final registry = context.read<DeviceController>().registry;

    final valueSummary = group.vars
        .map((v) => (registry[v.id]?.value ?? v.value).toString())
        .join(', ');

    return SizedBox(
      width: 185,
      child: Material(
        color: Colors.purple.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        elevation: 1,
        shadowColor: Colors.black26,
        child: InkWell(
          onTap: () => showArrayEditorDialog(context, group),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.purple.withValues(alpha: 0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('${group.name} [0..${group.vars.length - 1}]',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.purple.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('${group.vars.length}项',
                          style: TextStyle(fontSize: 9, color: Colors.purple.withValues(alpha: 0.8))),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(valueSummary,
                    style: TextStyle(fontSize: 11, fontFamily: 'Consolas', color: cs.onSurface.withValues(alpha: 0.7)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.table_chart, size: 14, color: Colors.purple.withValues(alpha: 0.6)),
                    const SizedBox(width: 4),
                    Text('点击编辑', style: TextStyle(fontSize: 10, color: Colors.purple.withValues(alpha: 0.6))),
                    const Spacer(),
                    GestureDetector(
                      onTap: () async {
                        final ctrl = context.read<DeviceController>();
                        for (final v in group.vars) {
                          ctrl.requestStaticRefresh(v.id);
                          await Future.delayed(const Duration(milliseconds: 20));
                        }
                      },
                      child: Icon(Icons.refresh, size: 15, color: Colors.purple.withValues(alpha: 0.6)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
