import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import '../../core/services/device_controller.dart';
import '../../core/models/registered_var.dart';
import '../../debug_protocol.dart';

class StaticVarsPanel extends StatelessWidget {
  const StaticVarsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: colorScheme.surface,
      child: Column(
        children: [
          // 标题栏：包含标题和一键刷新按钮
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.purple.withValues(alpha: 0.15),
              border: Border(
                bottom: BorderSide(
                  color: Colors.purple.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.storage,
                      size: 18,
                      color: Colors.purple.withValues(alpha: 0.8),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      "静态变量",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.purple,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 显示静态变量数量
                    Selector<DeviceController, int>(
                      selector: (_, c) =>
                          c.registry.values.where((v) => v.isStatic).length,
                      builder: (_, count, __) => Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.purple.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          "$count",
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.purple,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                // 一键刷新所有按钮
                Tooltip(
                  message: "刷新所有静态变量",
                  child: Material(
                    color: Colors.purple.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                    child: InkWell(
                      onTap: () => _refreshAllStaticVars(context),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.refresh,
                              size: 16,
                              color: Colors.purple.withValues(alpha: 0.9),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              "全部刷新",
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.purple.withValues(alpha: 0.9),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 静态变量列表
          Expanded(
            child: Selector<DeviceController, List<int>>(
              selector: (_, c) => c.registry.values
                  .where((v) => v.isStatic)
                  .map((v) => v.id)
                  .toList(),
              shouldRebuild: (prev, next) => !listEquals(prev, next),
              builder: (context, staticVarIds, _) {
                if (staticVarIds.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.storage_outlined,
                          size: 32,
                          color: Colors.grey.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "暂无静态变量",
                          style: TextStyle(
                            color: Colors.grey.withValues(alpha: 0.7),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: staticVarIds.length,
                  itemBuilder: (context, index) {
                    final varId = staticVarIds[index];
                    return StaticVarTile(
                      key: ValueKey(varId),
                      varId: varId,
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

  void _refreshAllStaticVars(BuildContext context) async {
    final controller = context.read<DeviceController>();
    final staticVars =
        controller.registry.values.where((v) => v.isStatic).toList();

    if (staticVars.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("没有静态变量需要刷新"),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }

    // 发送刷新请求，每个请求间隔 20ms，避免下位机处理不过来
    for (final variable in staticVars) {
      controller.requestStaticRefresh(variable.id);
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }
}

class StaticVarTile extends StatefulWidget {
  final int varId;

  const StaticVarTile({
    super.key,
    required this.varId,
  });

  @override
  State<StaticVarTile> createState() => _StaticVarTileState();
}

class _StaticVarTileState extends State<StaticVarTile> {
  Timer? _refreshTimer;
  String _valueDisplay = "0";
  String _nameDisplay = "";
  String _typeStr = "";
  String _addrStr = "";

  @override
  void initState() {
    super.initState();
    _updateData();
    // 静态变量也定期更新显示（值可能从其他方式更新）
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) _updateData();
    });
  }

  void _updateData() {
    final controller = context.read<DeviceController>();
    final v = controller.registry[widget.varId];

    if (v == null) return;

    final newValStr = v.value is double
        ? (v.value as double).toStringAsFixed(3)
        : v.value.toString();

    if (newValStr != _valueDisplay ||
        v.name != _nameDisplay) {
      final newTypeStr = v.type < VariableType.values.length
          ? VariableType.values[v.type].displayName
          : "Unknown";
      final newAddrStr =
          v.addr.toRadixString(16).toUpperCase().padLeft(8, '0');

      setState(() {
        _valueDisplay = newValStr;
        _nameDisplay = v.name;
        _typeStr = newTypeStr;
        _addrStr = newAddrStr;
      });
    }
  }

  void _requestRefresh() {
    final controller = context.read<DeviceController>();
    controller.requestStaticRefresh(widget.varId);
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
            Text(
                "ID: ${v.id} | Type: ${VariableType.values[v.type].displayName}"),
            Text("Addr: 0x${v.addr.toRadixString(16).toUpperCase()}"),
            const SizedBox(height: 12),
            TextField(
              controller: valCtrl,
              decoration: const InputDecoration(
                labelText: "新值",
                border: OutlineInputBorder(),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
          ElevatedButton(
            onPressed: () {
              try {
                num newVal;
                if (v.type == VariableType.float.index) {
                  newVal = double.parse(valCtrl.text);
                } else {
                  String input = valCtrl.text.trim();
                  if (input.startsWith("0x") || input.startsWith("0X")) {
                    newVal = int.parse(input.substring(2), radix: 16);
                  } else {
                    newVal = int.parse(input);
                  }
                }

                int len = _getTypeLength(v.type);
                controller.sendData(
                    DebugProtocol.packWriteCmd(v.id, len, newVal, v.type));

                // 静态变量修改后自动请求刷新以获取更新后的值
                controller.requestStaticRefresh(v.id);

                Navigator.pop(ctx);
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text("数值格式错误: $e"),
                      backgroundColor: Colors.red),
                );
              }
            },
            child: const Text("写入"),
          ),
        ],
      ),
    );
  }

  int _getTypeLength(int type) {
    if (type == 0 || type == 1) return 1;
    if (type == 2 || type == 3) return 2;
    if (type >= 4 && type <= 6) return 4;
    return 0;
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
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 0.5,
          ),
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
            child: Text(
              "${widget.varId}",
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.purple.withValues(alpha: 0.9),
              ),
            ),
          ),
        ),
        title: Text(
          _nameDisplay,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          "0x$_addrStr | $_typeStr",
          style: TextStyle(
            fontSize: 10,
            color: colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _valueDisplay,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.purple.withValues(alpha: 0.9),
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(
                Icons.refresh,
                size: 18,
                color: Colors.purple.withValues(alpha: 0.7),
              ),
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
