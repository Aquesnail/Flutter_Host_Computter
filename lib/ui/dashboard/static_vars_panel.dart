import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import '../../core/services/device_controller.dart';
import '../../core/models/registered_var.dart';
import '../../debug_protocol.dart';
import 'static_vars_actions.dart';
import 'static_vars_window.dart';

// ── StaticVarsPanel ──

class StaticVarsPanel extends StatelessWidget {
  const StaticVarsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: colorScheme.surface,
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.purple.withValues(alpha: 0.15),
              border: Border(
                bottom: BorderSide(color: Colors.purple.withValues(alpha: 0.3), width: 1),
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.storage, size: 18, color: Colors.purple.withValues(alpha: 0.8)),
                        const SizedBox(width: 8),
                        const Text("静态变量",
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.purple)),
                        const SizedBox(width: 8),
                        Selector<DeviceController, int>(
                          selector: (_, c) => c.registry.values.where((v) => v.isStatic).length,
                          builder: (_, count, _) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.purple.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text("$count",
                                style: const TextStyle(fontSize: 11, color: Colors.purple, fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Tooltip(
                          message: "弹出独立窗口",
                          child: Material(
                            color: Colors.purple.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                            child: InkWell(
                              onTap: () => showStaticVarsWindow(context),
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                child: Icon(Icons.open_in_new, size: 16, color: Colors.purple.withValues(alpha: 0.9)),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Material(
                      color: Colors.purple.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                      child: InkWell(
                        onTap: () => refreshAllStaticVars(context),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.refresh, size: 16, color: Colors.purple.withValues(alpha: 0.9)),
                              const SizedBox(width: 4),
                              Text("全部刷新",
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.purple.withValues(alpha: 0.9), fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _HeaderButton("写入", Icons.upload, () => writeAllStaticVars(context)),
                    const SizedBox(width: 6),
                    _HeaderButton("导入", Icons.download, () => importStaticVarsFromJson(context)),
                    const SizedBox(width: 6),
                    _HeaderButton("导出", Icons.save, () => exportStaticVarsToJson(context)),
                  ],
                ),
              ],
            ),
          ),

          // List
          Expanded(
            child: Selector<DeviceController, List<int>>(
              selector: (_, c) =>
                  c.registry.values.where((v) => v.isStatic).map((v) => v.id).toList(),
              shouldRebuild: (prev, next) => !listEquals(prev, next),
              builder: (context, staticVarIds, _) {
                if (staticVarIds.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.storage_outlined, size: 32, color: Colors.grey.withValues(alpha: 0.5)),
                        const SizedBox(height: 8),
                        Text("暂无静态变量",
                            style: TextStyle(color: Colors.grey.withValues(alpha: 0.7), fontSize: 12)),
                      ],
                    ),
                  );
                }

                final registry = context.read<DeviceController>().registry;
                final staticVars = registry.values.where((v) => v.isStatic).toList();
                final catGroups = groupVarsByCategory(staticVars);

                if (catGroups.length == 1 && catGroups.keys.first == 0xFF) {
                  // 全部未分类 → 保持旧版平铺展示
                  final groups = buildStaticVarGroups(registry);
                  return ListView.builder(
                    itemCount: groups.length,
                    itemBuilder: (context, index) {
                      final group = groups[index];
                      if (group.isArray) {
                        return _StaticArrayTile(
                          key: ValueKey('arr_${group.name}'),
                          group: group,
                        );
                      }
                      return StaticVarTile(
                        key: ValueKey(group.vars.first.id),
                        varId: group.vars.first.id,
                      );
                    },
                  );
                }

                // 有分类 → 二级分组折叠展示
                return ListView.builder(
                  itemCount: catGroups.entries.length,
                  itemBuilder: (context, index) {
                    final entry = catGroups.entries.elementAt(index);
                    final catName = categoryLabels[entry.key] ?? '其他';
                    final catVars = entry.value;
                    final groups = buildStaticVarGroups(
                      Map<int, RegisteredVar>.fromEntries(
                        catVars.map((v) => MapEntry(v.id, v)),
                      ),
                    );

                    return ExpansionTile(
                      title: Text('$catName (${catVars.length})',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      initiallyExpanded: entry.key != 0x07, // 观测变量默认折叠
                      children: groups.map((group) {
                        if (group.isArray) {
                          return _StaticArrayTile(
                            key: ValueKey('arr_${group.name}'),
                            group: group,
                          );
                        }
                        return StaticVarTile(
                          key: ValueKey(group.vars.first.id),
                          varId: group.vars.first.id,
                        );
                      }).toList(),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _HeaderButton(this.label, this.icon, this.onTap);

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: "$label静态变量",
      child: Material(
        color: Colors.purple.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: Colors.purple.withValues(alpha: 0.9)),
                const SizedBox(width: 4),
                Text(label,
                    style: TextStyle(
                        fontSize: 12, color: Colors.purple.withValues(alpha: 0.9), fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── StaticArrayTile ──

class _StaticArrayTile extends StatelessWidget {
  final StaticVarGroup group;

  const _StaticArrayTile({super.key, required this.group});

  void _refreshAll(BuildContext context) async {
    final ctrl = context.read<DeviceController>();
    for (final v in group.vars) {
      ctrl.requestStaticRefresh(v.id);
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final name = group.name;
    final count = group.vars.length;
    final registry = context.read<DeviceController>().registry;

    final valueSummary = group.vars
        .map((v) => (registry[v.id]?.value ?? v.value).toString())
        .join(', ');

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5), width: 0.5)),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        leading: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Colors.purple.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.purple.withValues(alpha: 0.5)),
          ),
          child: Center(
            child: Text("$count", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.purple.withValues(alpha: 0.9))),
          ),
        ),
        title: Text("$name [0..${count - 1}]",
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13), overflow: TextOverflow.ellipsis),
        subtitle: Text(valueSummary,
            style: TextStyle(fontSize: 10, color: colorScheme.onSurface.withValues(alpha: 0.5)),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(Icons.refresh, size: 18, color: Colors.purple.withValues(alpha: 0.7)),
              tooltip: "全部刷新",
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: () => _refreshAll(context),
            ),
            Icon(Icons.chevron_right, size: 18, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
          ],
        ),
        onTap: () => showArrayEditorDialog(context, group),
      ),
    );
  }
}

// ── StaticVarTile ──

class StaticVarTile extends StatefulWidget {
  final int varId;

  const StaticVarTile({super.key, required this.varId});

  @override
  State<StaticVarTile> createState() => _StaticVarTileState();
}

class _StaticVarTileState extends State<StaticVarTile> {
  Timer? _refreshTimer;
  String _valueDisplay = "0";
  String _nameDisplay = "";
  String _typeStr = "";
  String _addrStr = "";
  bool _isPeri = false;

  @override
  void initState() {
    super.initState();
    _updateData();
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) _updateData();
    });
  }

  void _updateData() {
    final controller = context.read<DeviceController>();
    final v = controller.registry[widget.varId];
    if (v == null) return;

    final newValStr = v.value is double ? (v.value as double).toStringAsFixed(3) : v.value.toString();
    if (newValStr != _valueDisplay || v.name != _nameDisplay || v.isPeri != _isPeri) {
      final newTypeStr =
          v.type < VariableType.values.length ? VariableType.values[v.type].displayName : "Unknown";
      final newAddrStr = v.addr.toRadixString(16).toUpperCase().padLeft(8, '0');
      setState(() {
        _valueDisplay = newValStr;
        _nameDisplay = v.name;
        _typeStr = newTypeStr;
        _addrStr = newAddrStr;
        _isPeri = v.isPeri;
      });
    }
  }

  void _requestRefresh() {
    context.read<DeviceController>().requestStaticRefresh(widget.varId);
  }

  void _showModifyDialog() {
    final controller = context.read<DeviceController>();
    final v = controller.registry[widget.varId];
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
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5), width: 0.5),
        ),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        leading: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Colors.purple.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.purple.withValues(alpha: 0.4)),
          ),
          child: Center(
            child: Text("${widget.varId}",
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.purple.withValues(alpha: 0.9))),
          ),
        ),
        title: Text(_nameDisplay,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13), overflow: TextOverflow.ellipsis),
        subtitle: Row(
          children: [
            Text("0x$_addrStr | $_typeStr",
                style: TextStyle(fontSize: 10, color: colorScheme.onSurface.withValues(alpha: 0.6))),
            if (_isPeri)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.purple.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: Colors.purple.withValues(alpha: 0.5)),
                  ),
                  child: const Text("PERI",
                      style: TextStyle(fontSize: 9, color: Colors.purple, fontWeight: FontWeight.bold)),
                ),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_valueDisplay,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.purple.withValues(alpha: 0.9),
                    fontFamily: 'monospace')),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(Icons.refresh, size: 18, color: Colors.purple.withValues(alpha: 0.7)),
              tooltip: "刷新",
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: _requestRefresh,
            ),
          ],
        ),
        onTap: _showModifyDialog,
      ),
    );
  }
}
