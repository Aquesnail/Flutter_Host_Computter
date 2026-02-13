import "dart:async";
import "device_control.dart";
import "debug_protocol.dart";
import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:flutter/foundation.dart";


class LowFreqWindow extends StatefulWidget{
  const LowFreqWindow({super.key});

  @override
  State<LowFreqWindow> createState() => _LowFreqWindow();
}

class _LowFreqWindow extends State<LowFreqWindow>{

  int _getTypeLength(int type) {
    // 同样提取低4位
    int typeIndex = type & 0x0F;
    
    switch (typeIndex) {
      case 0: // uint8
      case 1: // int8
        return 1;
      case 2: // uint16
      case 3: // int16
        return 2;
      case 4: // uint32
      case 5: // int32
      case 6: // float (通常是 4 字节)
        return 4;
      default:
        return 0;
    }
  }
  void _showRegisterDialog(BuildContext context){
    final nameCtrl = TextEditingController();
    final addrCtrl = TextEditingController();

    int selectedVarType=0;
    bool isHighFreq = false;

    final List<String> typeLabels = ["Uint8", "Int8", "Uint16", "Int16", "Uint32", "Int32", "Float"];

    showDialog(
      context: context,
      builder: (Diactx) => AlertDialog(//这里直接现写一个构造函数，所以匿名函数参量和前面不一样
        title: Text("注册变量"),
        content: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller:nameCtrl,
              decoration: const InputDecoration(labelText: "变量名称(Max 10 chars)"),
              maxLength: 10,
            ),
            const SizedBox(height: 10,),
            TextField(
              controller: addrCtrl,
              decoration: const InputDecoration(labelText: "地址 (Hex, 4字节 e.g. 20000000)"),
            ),
            const SizedBox(height: 10,),
            DropdownButtonFormField<int>(
              items: List.generate(7, (index) {
                return DropdownMenuItem(
                  value:index,
                  child: Text("$index: ${typeLabels[index]}")
                );
              }),
              onChanged: (v) => setState(()=> selectedVarType = v!),
            ),
            SwitchListTile(
              title: const Text("高频信号 (波形显示)"),
              subtitle: const Text("开启后置位 Type 第4位"),
              value: isHighFreq,
              onChanged: (v) => setState(() => isHighFreq = v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: ()=> Navigator.pop(Diactx),
            child: const Text("取消"),
          ),
          ElevatedButton(
            onPressed: (){
              try {
                String name = nameCtrl.text.trim();
                if (name.isEmpty) throw "名字不能为空";

                String addrStr = addrCtrl.text.trim();
                if (addrStr.startsWith("0x") || addrStr.startsWith("0X")) addrStr = addrStr.substring(2);
                if (addrStr.isEmpty) throw "地址不能为空";
                
                int addr = int.parse(addrStr, radix: 16);

                // 发送注册指令 [修改后的调用]
                final controller = context.read<DeviceController>();
                controller.sendData(DebugProtocol.packRegisterCmd(
                  addr, // 4字节地址
                  name, 
                  selectedVarType, 
                  isHighFreq: isHighFreq // 传入高频标志
                ));

                Navigator.pop(Diactx);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("注册请求发送: $name")));
              } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("错误: $e"), backgroundColor: Colors.red));
              }
            },
            child:const Text("注册"),
          )
        ],
      )
    );
  }
  void _showModifyDialog(BuildContext context,RegisteredVar v){
    final TextEditingController valCtrl=TextEditingController();

    valCtrl.text = v.value.toString();
    showDialog(
      context: context,
      builder:(Diactx)=> AlertDialog(
        title: Text("修改变量,${v.name}"),
        content: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,//max为占满全屏幕，min为包裹内容
          children: [
            Text("ID: ${v.id} | Type: ${VariableType.values[v.type & 0x0F].displayName} | Addr: 0x${v.addr.toRadixString(16).toUpperCase()}"),
            const SizedBox(height: 10,),
            TextField(
              controller: valCtrl,
              decoration: const InputDecoration(
                labelText: "New Value",
                border:OutlineInputBorder(),
                helperText: "请输入正确类型的数值"
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal:true),
            )
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(Diactx), child: const Text("取消")),
          ElevatedButton(
            onPressed: (){
              try{
                num newVal;//浮点数和整数的父类，不需要用dynamic
                if((v.type & 0x0F) == VariableType.float.index){
                  newVal = double.parse(valCtrl.text);//防止这里处理错误，所以用了try
                }else{
                  String input = valCtrl.text.trim();
                  if(input.startsWith("0x") || input.startsWith("0X")){
                    newVal = int.parse(input.substring(2),radix:16);//从索引2开始截取至末尾，这里字符串索引从1开始
                  }else{
                    newVal = int.parse(input);
                  }
                }
                
                int len = _getTypeLength(v.type);

                final controller = context.read<DeviceController>();
                controller.sendData(DebugProtocol.packWriteCmd(v.id, len,newVal, v.type));

                Navigator.pop(Diactx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("指令已经发送")));

              } catch(e){
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("数值格式错误: $e"), backgroundColor: Colors.red));
              }
            }, 
            child: const Text("写入")
          ),
        ],
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    //final controller = context.watch<DeviceController>(); //
    final colorScheme = Theme.of(context).colorScheme;
    
    // 定义状态相关的颜色
    // 当握手成功时，上半部分区域变亮（或变色），否则维持普通表面色
    // final registerAreaColor = controller.shakeHandSuccessful 
    //     ? colorScheme.primaryContainer 
    //     : colorScheme.surface;

    return Scaffold(
      body: Row(
        children: [
          Expanded(
            flex: 2,
            child: Column(
              children: [
                // 标题栏保持不变
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  color: colorScheme.surfaceContainerHighest,
                  width: double.infinity,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // const Text("变量监控 (长按拖动排序)", 
                      //   style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
                      // // 可以在这里加一个分页指示器或搜索框
                      // Text("共 ${controller.registry.length} 个变量", style: const TextStyle(fontSize: 12)), //不再依赖下面的setState更新，改为监听逻辑

                      const Text("变量监控，长按拖动排序",
                        style: TextStyle(fontWeight: FontWeight.bold,color: Colors.black54),
                      ),
                      Selector<DeviceController,int>(
                        selector:(_,c) => c.registry.length,
                        builder:(_,count,__)=>Text("共 $count 个变量", style: const TextStyle(fontSize:12)),
                      )
                      //当更新调用了notifylistener函数时，这个Selector执行selector:内部的函数
                      //如果返回值发生了改变
                      //它就对其builder内的函数进行重新构建
                    ],
                  ),
                ),
                
               Expanded(
                  // 核心优化 1：只监听 ID 列表的【顺序】和【内容】
                  // 如果数值改变但顺序没变，ReorderableListView 不会重建！
                  child: Selector<DeviceController, List<int>>(
                    selector: (_, c) => c.registry.keys.toList(),//通过selector达到只更新变量列表的目的
                    shouldRebuild: (prev, next) => !listEquals(prev, next), // 使用 listEquals 深度比较
                    builder: (context, keys, child) {
                      if (keys.isEmpty) {
                        return const Center(child: Text("等待握手或数据...", style: TextStyle(color: Colors.grey)));
                      }
                      
                      return Theme(
                        data: Theme.of(context).copyWith(canvasColor: Colors.transparent),
                        child: ReorderableListView.builder(
                          itemExtent: 60.0,
                          itemCount: keys.length,
                          onReorder: (oldIndex, newIndex) {
                            // 排序操作不需要 setState，直接调逻辑，Selector 会监测到 key 顺序变化自动刷新
                            if (newIndex > oldIndex) newIndex -= 1;
                            context.read<DeviceController>().reorderRegistry(oldIndex, newIndex);
                          },
                          itemBuilder: (ctx, index) {
                            final id = keys[index];
                            // 核心优化 2：每个 Item 是独立的，可以精准刷新
                            return MonitorListTile(
                              key: ValueKey(id), // 必须有 Key
                              varId: id,
                              onTap: (v) => _showModifyDialog(context, v),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // 右侧操作栏容器
          
        ],
      ),
    );
  }

  Widget _buildRightPanel(BuildContext context,ColorScheme colorScheme){
    return Container(
        width: 120,
        decoration: BoxDecoration(
          color: colorScheme.surface, // 整体底色
          border: Border(
            left: BorderSide(color: colorScheme.outlineVariant, width: 1.0),
          ),
        ),
        child: Column(
          children: [
            // --- 上半部分：注册变量 ---
            Expanded(
              child: Selector<DeviceController,bool>(
                selector: (_,c)=> c.shakeHandSuccessful,
                builder: (context,isHandshaked,_){
                    // 根据状态计算颜色
                  final bgColor = isHandshaked ? colorScheme.primaryContainer : colorScheme.surface;
                  final fgColor = isHandshaked ? colorScheme.primary : colorScheme.outline;
                  final textColor = isHandshaked ? colorScheme.onPrimaryContainer : colorScheme.outline;
                  
                  return Material(
                    color: bgColor, // 背景色
                    child: InkWell(
                      // 只有握手成功才允许点击
                      onTap: isHandshaked ? () => _showRegisterDialog(context) : null,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add_circle_outline, color: fgColor, size: 28),
                            const SizedBox(height: 8),
                            Text(
                              "注册变量",
                              style: TextStyle(
                                color: textColor,
                                fontWeight: isHandshaked ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }
              )
            ),

            Divider(height: 1, thickness: 1, color: colorScheme.outlineVariant, indent: 10, endIndent: 10),

            // --- 下半部分：参数设置 ---
            Expanded(
              child: Material(
                color: colorScheme.surface, // 同样建议给下半部分也加上 Material 背景
                child: InkWell(
                  onTap: () { /* 设置逻辑 */ },
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.settings),
                        const SizedBox(height: 8),
                        const Text("参数设置"),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        )
      );
  }
}
class MonitorListTile extends StatefulWidget {
  final int varId;
  final Function(RegisteredVar) onTap;

  const MonitorListTile({
    super.key, 
    required this.varId, 
    required this.onTap
  });

  @override
  State<MonitorListTile> createState() => _MonitorListTileState();
}

class _MonitorListTileState extends State<MonitorListTile> {
  Timer? _refreshTimer;
  
  // 缓存显示用的字符串，避免浮点数微小波动导致无意义的重绘
  String _valueDisplay = "0";
  String _nameDisplay = "";
  String _typeStr = "";
  String _addrStr = "";

  @override
  void initState() {
    super.initState();
    
    // 初始化一次数据，避免第一帧空白
    _updateData();

    // 启动 5Hz (200ms) 的采样定时器
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) _updateData();
    });
  }

  void _updateData() {
    // 1. 直接读取 controller (不使用 watch/select，完全不产生依赖)
    final controller = context.read<DeviceController>();
    final v = controller.registry[widget.varId];

    if (v == null) return;

    // 2. 格式化数据
    final newValStr = v.value is double
        ? (v.value as double).toStringAsFixed(3)
        : v.value.toString();
    
    // 3. 只有当【显示内容】发生变化时才触发 setState
    // 这样不仅限制了频率，还过滤了无效更新
    if (newValStr != _valueDisplay || v.name != _nameDisplay) {
      
      // 这些静态信息通常不变，也可以放在这里惰性计算
      final newTypeStr = v.type < VariableType.values.length
            ? VariableType.values[v.type].displayName
            : "Unknown";
      final newAddrStr = v.addr.toRadixString(16).toUpperCase().padLeft(4, '0');

      setState(() {
        _valueDisplay = newValStr;
        _nameDisplay = v.name;
        _typeStr = newTypeStr;
        _addrStr = newAddrStr;
      });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      dense: true,
      // 使用 const 组件优化结构
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: colorScheme.secondaryContainer,
        child: Text("${widget.varId}",
            style: TextStyle(fontSize: 10, color: colorScheme.onSecondaryContainer)),
      ),
      title: Text(_nameDisplay, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(
        "Addr: 0x$_addrStr | Type: $_typeStr",
        style: const TextStyle(fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _valueDisplay,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: colorScheme.primary,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.drag_handle, size: 16, color: Colors.grey),
        ],
      ),
      onTap: () {
        // 获取最新的对象传给弹窗
        final v = context.read<DeviceController>().registry[widget.varId];
        if (v != null) widget.onTap(v);
      },
    );
  }
}