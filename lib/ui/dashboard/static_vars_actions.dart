import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../core/services/device_controller.dart';
import '../../core/models/registered_var.dart';
import '../../debug_protocol.dart';

// ── Action functions ──

Future<void> refreshAllStaticVars(BuildContext context) async {
  final controller = context.read<DeviceController>();
  final staticVars = controller.registry.values.where((v) => v.isStatic).toList();

  if (staticVars.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("没有静态变量需要刷新"), duration: Duration(seconds: 1)),
      );
    }
    return;
  }

  for (final variable in staticVars) {
    controller.requestStaticRefresh(variable.id);
    await Future.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> writeAllStaticVars(BuildContext context) async {
  final controller = context.read<DeviceController>();
  final staticVars = controller.registry.values.where((v) => v.isStatic).toList();

  if (staticVars.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("没有静态变量可写入"), duration: Duration(seconds: 1)),
      );
    }
    return;
  }

  if (!controller.isConnected) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("请先连接串口"), duration: Duration(seconds: 1)),
      );
    }
    return;
  }

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("正在写入 ${staticVars.length} 个静态变量..."), duration: const Duration(seconds: 1)),
    );
  }

  await controller.writeAllStaticVarsToDevice();

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("已发送 ${staticVars.length} 个静态变量到下位机"), duration: const Duration(seconds: 1)),
    );
  }
}

Future<void> importStaticVarsFromJson(BuildContext context) async {
  final controller = context.read<DeviceController>();

  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['json'],
    dialogTitle: "选择静态变量配置文件",
  );

  if (result == null || result.files.isEmpty) return;
  final path = result.files.single.path;
  if (path == null) return;

  // 判断是否可启用合并模式
  final hasStaticVars = controller.registry.values.any((v) => v.isStatic);
  final canMerge = controller.shakeHandSuccessful && hasStaticVars;

  bool useMerge = false;

  if (canMerge) {
    if (!context.mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("导入模式选择"),
        content: const Text(
          "已检测到设备握手成功且上位机已有静态变量参数表。\n\n"
          "请选择导入方式：\n"
          "• 覆盖导入：用 JSON 中的 id/addr/name/type/value 整体替换参数表\n"
          "• 合并导入：按变量名匹配，仅写入值，不动 id 和地址（类型不匹配则跳过）",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'overwrite'),
            child: const Text("覆盖导入"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'merge'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purple,
              foregroundColor: Colors.white,
            ),
            child: const Text("合并导入（按名称匹配）"),
          ),
        ],
      ),
    );
    if (choice == null) return; // 用户取消
    useMerge = choice == 'merge';
  }

  try {
    final count = await controller.loadStaticVarsFromJson(path, mergeMode: useMerge);
    if (context.mounted) {
      final modeLabel = useMerge ? "已合并导入" : "已导入";
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("$modeLabel $count 个静态变量"), duration: const Duration(seconds: 2)),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("导入失败: $e"), backgroundColor: Colors.red, duration: const Duration(seconds: 2)),
      );
    }
  }
}

Future<void> exportStaticVarsToJson(BuildContext context) async {
  final controller = context.read<DeviceController>();
  final staticVars = controller.registry.values.where((v) => v.isStatic).toList();

  if (staticVars.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("没有静态变量可导出"), duration: Duration(seconds: 1)),
      );
    }
    return;
  }

  final result = await FilePicker.platform.saveFile(
    dialogTitle: "保存静态变量配置文件",
    fileName: "static_vars.json",
    type: FileType.custom,
    allowedExtensions: ['json'],
  );

  if (result == null) return;

  try {
    await controller.saveStaticVarsToJson(result);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("已导出到 $result"), duration: const Duration(seconds: 2)),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("导出失败: $e"), backgroundColor: Colors.red, duration: const Duration(seconds: 2)),
      );
    }
  }
}

// ── Shared utilities ──

/// category → 中文标签
const Map<int, String> categoryLabels = {
  0x00: 'ADC 误差权重',
  0x01: '外环控制',
  0x02: '内环 PI',
  0x03: '速度输出',
  0x04: '模糊 PID',
  0x05: '元素行为',
  0x06: '系统杂项',
  0x07: '观测变量',
  0x08: '电机外设',
  0xFF: '未分类',
};

/// element → 中文标签（空字符串表示全局，不显示）
const Map<int, String> elementLabels = {
  0x00: '',
  0x01: '直线',
  0x02: '十字',
  0x03: '环岛',
  0x04: '墙面',
};

/// 将静态变量按 (category) 分组，返回按 category ID 排序的 LinkedHashMap
Map<int, List<RegisteredVar>> groupVarsByCategory(Iterable<RegisteredVar> vars) {
  final map = <int, List<RegisteredVar>>{};
  for (final v in vars) {
    map.putIfAbsent(v.category, () => []).add(v);
  }
  // 按 category ID 排序
  final sorted = Map<int, List<RegisteredVar>>.fromEntries(
    map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
  return sorted;
}

int varTypeLength(int type) {
  if (type == 0 || type == 1) return 1;
  if (type == 2 || type == 3) return 2;
  if (type >= 4 && type <= 6) return 4;
  return 0;
}

num parseVarValue(String input, int type) {
  final text = input.trim();
  if (type == VariableType.float.index) {
    return double.parse(text);
  }
  if (text.startsWith("0x") || text.startsWith("0X")) {
    return int.parse(text.substring(2), radix: 16);
  }
  return int.parse(text);
}

// ── StaticVarGroup model ──

class StaticVarGroup {
  final String name;
  final List<RegisteredVar> vars; // sorted by id ascending

  const StaticVarGroup._(this.name, this.vars);

  factory StaticVarGroup.single(RegisteredVar v) => StaticVarGroup._(v.name, [v]);

  factory StaticVarGroup.array(String name, List<RegisteredVar> vars) => StaticVarGroup._(name, vars);

  bool get isArray => vars.length > 1;
}

List<StaticVarGroup> buildStaticVarGroups(Map<int, RegisteredVar> registry) {
  final byName = <String, List<RegisteredVar>>{};
  for (final v in registry.values) {
    if (!v.isStatic) continue;
    final key = v.name.toLowerCase().trim();
    byName.putIfAbsent(key, () => []).add(v);
  }
  for (final list in byName.values) {
    list.sort((a, b) => a.id.compareTo(b.id));
  }
  final groups = byName.entries.map((e) {
    if (e.value.length == 1) {
      return StaticVarGroup.single(e.value.first);
    }
    return StaticVarGroup.array(e.value.first.name, e.value);
  }).toList();
  groups.sort((a, b) => a.vars.first.id.compareTo(b.vars.first.id));
  return groups;
}

// ── Array editor dialog ──

void showArrayEditorDialog(BuildContext context, StaticVarGroup group) {
  showDialog(
    context: context,
    builder: (ctx) => ArrayEditorDialog(group: group),
  );
}

class ArrayEditorDialog extends StatefulWidget {
  final StaticVarGroup group;

  const ArrayEditorDialog({super.key, required this.group});

  @override
  State<ArrayEditorDialog> createState() => _ArrayEditorDialogState();
}

class _ArrayEditorDialogState extends State<ArrayEditorDialog> {
  late List<TextEditingController> _controllers;
  late List<FocusNode> _focusNodes;
  final Set<int> _dirtyIndices = {};
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    final n = widget.group.vars.length;
    _controllers = List.generate(n, (i) => TextEditingController(text: widget.group.vars[i].value.toString()));
    _focusNodes = List.generate(n, (_) => FocusNode());
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) _refreshDisplays();
    });
  }

  void _refreshDisplays() {
    final ctrl = context.read<DeviceController>();
    bool changed = false;
    for (int i = 0; i < widget.group.vars.length; i++) {
      // Skip fields the user has modified — preserve their edits
      if (_dirtyIndices.contains(i)) continue;
      final v = ctrl.registry[widget.group.vars[i].id];
      if (v == null) continue;
      final newText = v.value is double ? (v.value as double).toStringAsFixed(3) : v.value.toString();
      if (_controllers[i].text != newText) {
        _controllers[i].text = newText;
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

  Future<void> _refreshAll() async {
    final ctrl = context.read<DeviceController>();
    for (final v in widget.group.vars) {
      ctrl.requestStaticRefresh(v.id);
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> _writeAll() async {
    final ctrl = context.read<DeviceController>();
    if (!ctrl.isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("请先连接串口"), duration: Duration(seconds: 1)),
        );
      }
      return;
    }

    int written = 0;
    for (int i = 0; i < widget.group.vars.length; i++) {
      final v = widget.group.vars[i];
      final newText = _controllers[i].text.trim();
      final oldText = v.value is double ? (v.value as double).toStringAsFixed(3) : v.value.toString();
      if (newText == oldText) continue;

      try {
        final newVal = parseVarValue(newText, v.type);
        ctrl.sendData(DebugProtocol.packWriteCmd(v.id, varTypeLength(v.type), newVal, v.type));
        v.value = newVal; // 立即更新本地 registry，确保导出拿到最新值
        ctrl.requestStaticRefresh(v.id);
        _dirtyIndices.remove(i);
        written++;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("${v.name}[$i] 解析错误: $e"), backgroundColor: Colors.red, duration: const Duration(seconds: 2)),
          );
        }
      }
      await Future.delayed(const Duration(milliseconds: 20));
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("已写入 $written 个变量"), duration: const Duration(seconds: 1)),
      );
    }
  }

  Future<void> _refreshOne(int i) async {
    context.read<DeviceController>().requestStaticRefresh(widget.group.vars[i].id);
    _dirtyIndices.remove(i);
  }

  Future<void> _writeOne(int i) async {
    final ctrl = context.read<DeviceController>();
    if (!ctrl.isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("请先连接串口"), duration: Duration(seconds: 1)),
        );
      }
      return;
    }

    final v = widget.group.vars[i];
    try {
      final newVal = parseVarValue(_controllers[i].text.trim(), v.type);
      ctrl.sendData(DebugProtocol.packWriteCmd(v.id, varTypeLength(v.type), newVal, v.type));
      v.value = newVal; // 立即更新本地 registry，确保导出拿到最新值
      ctrl.requestStaticRefresh(v.id);
      _dirtyIndices.remove(i);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("解析错误: $e"), backgroundColor: Colors.red, duration: const Duration(seconds: 2)),
        );
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = widget.group.name;
    final count = widget.group.vars.length;

    return AlertDialog(
      title: Text("数组编辑: $name ($count 个元素)"),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  const SizedBox(width: 36, child: Text("索引", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                  const Expanded(child: Text("值", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                  const SizedBox(width: 60, child: Text("类型", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                  const SizedBox(width: 72, child: Text("操作", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (int i = 0; i < count; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 36,
                              child: Text("[$i]", style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                            ),
                            Expanded(
                              child: SizedBox(
                                height: 32,
                                child: TextField(
                                  controller: _controllers[i],
                                  focusNode: _focusNodes[i],
                                  onChanged: (_) => _dirtyIndices.add(i),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                                  decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(5)),
                                    isDense: true,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            SizedBox(
                              width: 56,
                              child: Text(
                                VariableType.values[widget.group.vars[i].type].displayName,
                                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                              ),
                            ),
                            SizedBox(
                              width: 72,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.refresh, size: 16),
                                    tooltip: "刷新",
                                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                    padding: EdgeInsets.zero,
                                    onPressed: () => _refreshOne(i),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.send, size: 16),
                                    tooltip: "写入",
                                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                    padding: EdgeInsets.zero,
                                    onPressed: () => _writeOne(i),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("关闭")),
        ElevatedButton.icon(
          onPressed: _refreshAll,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text("全部刷新"),
        ),
        ElevatedButton.icon(
          onPressed: _writeAll,
          icon: const Icon(Icons.upload, size: 16),
          label: const Text("全部写入"),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.purple, foregroundColor: Colors.white),
        ),
      ],
    );
  }
}
