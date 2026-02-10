import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'dart:async';
import 'device_control.dart'; // 确保路径对应你的实际文件结构
import 'debug_protocol.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(
    // 关键步骤：在这里注入你的控制器
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DeviceController()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: MainWindow(), // 现在 MainWindow 就能通过 context 找到控制器了
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color.fromARGB(255, 63, 124, 255)),
          useMaterial3: true,
        ),
      ),
    ),
  );
}
class MainWindow extends StatefulWidget {
  @override 
  State<MainWindow> createState() => _MainWindow();
}

class _MainWindow extends State<MainWindow> {

  String? selectedPort;
  @override
  Widget build(BuildContext context){
    final controller = context.watch<DeviceController>();
    final availablePorts = SerialPort.availablePorts;
    final _colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12,vertical: 8),
            color: _colorScheme.primary,
            child: Row(
              children: [
                const Icon(
                  Icons.usb,
                  color: Colors.grey
                ),
                const SizedBox(width:8),
                DropdownButton<String>(
                  items: availablePorts.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                  value: selectedPort,
                  hint: const Text("选择串口"),
                  onChanged: (v) => setState(() => selectedPort = v),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: controller.isConnected
                      ? () => controller.disconnect()
                      : () => selectedPort != null ? controller.connect(selectedPort!, 115200) : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: controller.isConnected ? Colors.redAccent : Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  icon: Icon(controller.isConnected ? Icons.link_off : Icons.link, size: 18),
                  label: Text(controller.isConnected ? "关闭" : "打开"),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.back_hand, size: 18),
                  label: const Text("握手"),
                  // 只有连接成功了才能点握手
                  onPressed: controller.isConnected 
                      ? () async {
                          // 1. 显示加载中 (可选，如果 UI 需要)
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text("正在握手..."), 
                              duration: Duration(milliseconds: 500)
                            )
                          );

                          // 2. 调用异步握手逻辑
                          bool success = await controller.shakeWithMCU();

                          // 3. 根据结果显示提示
                          if (context.mounted) { // 检查页面是否还存在
                            if (success) {
                              ScaffoldMessenger.of(context).hideCurrentSnackBar();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text("握手成功！开始同步数据..."), 
                                  backgroundColor: Colors.green
                                )
                              );
                            } else {
                              ScaffoldMessenger.of(context).hideCurrentSnackBar();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text("握手失败：超时或无响应"), 
                                  backgroundColor: Colors.red
                                )
                              );
                            }
                          }
                        }
                      : null, // 未连接时禁用
                ),
                const Spacer(),
                if (controller.isConnected) 
                  const Chip(
                     label: Text("已连接", style: TextStyle(color: Colors.white)), 
                     backgroundColor: Colors.green,
                     padding: EdgeInsets.zero,
                     visualDensity: VisualDensity.compact,
                   ),
                if(controller.shakeHandSuccessful)
                  const Chip(
                     label: Text("握手成功", style: TextStyle(color: Colors.white)), 
                     backgroundColor: Colors.green,
                     padding: EdgeInsets.zero,
                     visualDensity: VisualDensity.compact,
                   ),
              ],
            ),
          ),
          Expanded(
            child:  LayoutDashboard()
          )
        ],
      ),
    );
  }
}

class LayoutDashboard extends StatefulWidget {
  @override
  State<LayoutDashboard> createState() => _LayoutDashboardState();
}
class _LayoutDashboardState extends State<LayoutDashboard> {
  late MultiSplitViewController _rootController;
  late MultiSplitViewController _topController;
  late MultiSplitViewController _bottomController;

@override
  void initState() {
    super.initState();

    // 1. 顶部控制器：左侧自适应，右侧固定初始大小
    _topController = MultiSplitViewController(
      areas: [
        // 左侧：主显示区，不设 size，让它用 flex 占满剩余空间
        Area(data: 'top_left', flex: 1), 
        
        // 右侧：控制面板
        Area(
          data: 'top_right', 
          size: 250,    // 【关键】给一个明确的初始像素宽度，而不是 flex 比例
          min: 150,     // 【限位】限制最小宽度 150px，防止内容被压扁
          max: 500      // 【限位】(可选) 限制最大宽度，防止拉太宽
        )
      ]
    );
    
    // 2. 底部控制器：同理，左侧自适应，右侧固定
    _bottomController = MultiSplitViewController(
      areas: [
        Area(data: 'bottom_left', flex: 1), 
        Area(
          data: 'bottom_right', 
          size: 250,    // 初始宽度
          min: 150,      // 最小宽度保护
          max: 600
        )
      ]
    );

    // 3. 根控制器（垂直）：上方自适应，下方固定
    _rootController = MultiSplitViewController(
      areas: [
        // 上方：主要区域
        Area(data: 'TOP_ROW', flex: 1),
        
        // 下方：次要波形区域
        Area(
          data: 'BOTTOM_ROW',
          size: 200,    // 初始高度 200px
          min: 150,     // 最小高度 100px
          max: 400
        ),
      ]
    );
  }

  @override
  Widget build(BuildContext context) {
    // 2. 在 build 方法里获取颜色是安全的，因为此时 Widget 树已经构建好了
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: MultiSplitViewTheme(
        data: MultiSplitViewThemeData(
          dividerThickness: 10.0,
          dividerPainter: DividerPainters.grooved1(
            backgroundColor: colorScheme.surfaceVariant,
            highlightedColor: colorScheme.primary
          )
        ),
        child: MultiSplitView(
          axis: Axis.vertical,
          controller: _rootController,
          builder: (BuildContext context, Area area) {
            if (area.data == 'TOP_ROW') {
              return MultiSplitView(
                axis: Axis.horizontal,
                controller: _topController,
                // 上面两格用主色容器（浅蓝）
                builder: (context, area) {
                  if(area.data == 'top_left'){
                    return const ScopeDashboard();
                  }
                  return _buildContent(colorScheme.primaryContainer, "Primary");
                }
              );
            } else {
              return MultiSplitView(
                axis: Axis.horizontal,
                controller: _bottomController,
                // 下面两格用次级色容器（通常是浅紫色或配套色），看出层次感
                builder: (context, area) {
                  if(area.data == "bottom_left"){
                    return const LowFreqWindow();
                  }
                  return _buildContent(colorScheme.surface, "right_bottom");
                }
              );
            }
          }
        )
      )
    );
  }

  Widget _buildContent(Color color, String label) {
    return Container(
      color: color,
      child: Center(
        child: Text(
          label,
          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
  
}

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
                  child: Text("${index}: ${typeLabels[index]}")
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

  Widget build(BuildContext context) {
    final controller = context.watch<DeviceController>();
    final colorScheme = Theme.of(context).colorScheme;
    
    // 定义状态相关的颜色
    // 当握手成功时，上半部分区域变亮（或变色），否则维持普通表面色
    final registerAreaColor = controller.shakeHandSuccessful 
        ? colorScheme.primaryContainer 
        : colorScheme.surface;

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
                  color: colorScheme.surfaceVariant,
                  width: double.infinity,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("变量监控 (长按拖动排序)", 
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
                      // 可以在这里加一个分页指示器或搜索框
                      Text("共 ${controller.registry.length} 个变量", style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
                
                Expanded(
                  child: controller.registry.isEmpty
                      ? const Center(child: Text("等待握手或数据...", style: TextStyle(color: Colors.grey)))
                      : Theme(
                          // 移除 ReorderableListView 默认的画布颜色，使其透明
                          data: Theme.of(context).copyWith(canvasColor: Colors.transparent),
                          child: ReorderableListView.builder(
                            // 使用这种方式模拟双列：如果数据量大，可以将每一个 item 内部做成 Row
                            // 或者调整 item 的宽度，这里演示标准拖拽
                            itemCount: controller.registry.length,
                            onReorder: (oldIndex, newIndex) {
                              setState(() {
                                if (newIndex > oldIndex) newIndex -= 1;
                                // 注意：这里需要你的 controller.registry 支持排序
                                // 如果 registry 是 Map，你需要先转成 List 处理排序后再同步
                                controller.reorderRegistry(oldIndex, newIndex);
                              });
                            },
                            itemBuilder: (ctx, index) {
                              final id = controller.registry.keys.elementAt(index);
                              final v = controller.registry[id]!;
                              
                              // --- 格式化显示逻辑 ---
                              // 1. 类型显示转换
                              String typeStr = v.type < VariableType.values.length 
                                  ? VariableType.values[v.type].displayName 
                                  : "Unknown";

                              // 2. 浮点数保留三位小数
                              String valueDisplay = v.value is double 
                                  ? (v.value as double).toStringAsFixed(3) 
                                  : v.value.toString();

                              return ListTile(
                                key: ValueKey(id), // 拖拽必须有 Key
                                dense: true,
                                leading: CircleAvatar(
                                  radius: 14,
                                  backgroundColor: colorScheme.secondaryContainer,
                                  child: Text("$id", style: TextStyle(fontSize: 10, color: colorScheme.onSecondaryContainer)),
                                ),
                                title: Text(v.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                                subtitle: Text(
                                  "Addr: 0x${v.addr.toRadixString(16).toUpperCase().padLeft(4, '0')} | Type: $typeStr",
                                  style: const TextStyle(fontSize: 11),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      valueDisplay,
                                      style: TextStyle(
                                        fontSize: 16, 
                                        fontWeight: FontWeight.bold, 
                                        color: colorScheme.primary, 
                                        fontFamily: 'monospace'
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Icon(Icons.drag_handle, size: 16, color: Colors.grey),
                                  ],
                                ),
                                onTap: () => _showModifyDialog(context, v),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),

          // 右侧操作栏容器
          Container(
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
                  child: Material(
                    // 直接在 Material 上设置颜色，它会自动管理水波纹层级
                    color: controller.shakeHandSuccessful 
                        ? colorScheme.primaryContainer 
                        : colorScheme.surface,
                    child: InkWell(
                      onTap: controller.shakeHandSuccessful 
                          ? () => _showRegisterDialog(context) 
                          : null,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.add_circle_outline, 
                              color: controller.shakeHandSuccessful 
                                  ? colorScheme.primary 
                                  : colorScheme.outline,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              "注册变量", 
                              style: TextStyle(
                                color: controller.shakeHandSuccessful 
                                    ? colorScheme.onPrimaryContainer 
                                    : colorScheme.outline,
                                fontWeight: controller.shakeHandSuccessful ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
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
          ),
        ],
      ),
    );
  }
}
class ScopeDashboard extends StatefulWidget {
  const ScopeDashboard({super.key});

  @override
  State<ScopeDashboard> createState() => _ScopeDashboardState();
}

class _ScopeDashboardState extends State<ScopeDashboard> {
  // 存储高频数据点：ID -> List
  Map<int, List<double>> multiChannelPoints = {};
  
  // 增加缓存点数，因为现在支持拖拽回看，数据多一点体验更好
  final int maxPoints = 2000; 
  
  StreamSubscription? _subscription;

  // --- 新增配置状态 ---
  int _bufferSize = 2000; // 默认缓冲区大小
  double _deltaTime = 20.0; // 默认采样间隔 (ms)
  
  // 输入控制器
  late TextEditingController _bufferCtrl;
  late TextEditingController _dtCtrl;
  // 颜色表 (用于区分不同曲线)
  final List<Color> colors = [
    Colors.greenAccent, 
    Colors.yellowAccent, 
    Colors.cyanAccent,
    Colors.orangeAccent,
    Colors.purpleAccent
  ];
  //用于强制重置示波器视图状态的 Key
  int _scopeViewKey = 0;
  @override
  void initState() {
    super.initState();
    _bufferCtrl = TextEditingController(text: _bufferSize.toString());
    _dtCtrl = TextEditingController(text: _deltaTime.toString());

    final controller = context.read<DeviceController>();
    _subscription = controller.highFreqStream.listen((data) {
      if (!mounted) return;
      setState(() {
        multiChannelPoints.putIfAbsent(data.key, () => []);
        final points = multiChannelPoints[data.key]!;
        points.add(data.value);
        
        // --- 使用动态的 Buffer Size ---
        if (points.length > _bufferSize) {
          // 移除超出部分，保持列表长度
          points.removeRange(0, points.length - _bufferSize); 
        }
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _bufferCtrl.dispose();
    _dtCtrl.dispose();
    super.dispose();
  }

  // 更新配置的方法
  void _updateConfig() {
    setState(() {
      int? newBuf = int.tryParse(_bufferCtrl.text);
      if (newBuf != null && newBuf > 10) _bufferSize = newBuf;
      
      double? newDt = double.tryParse(_dtCtrl.text);
      if (newDt != null && newDt > 0) _deltaTime = newDt;
    });
    // 收起键盘
    FocusScope.of(context).unfocus();
  }
  //清空缓冲区逻辑
  void _clearBuffer() {
    setState(() {
      // 1. 清空所有通道的数据
      multiChannelPoints.clear();
      
      // 2. 更新 Key，强制 InteractiveScope 重建
      // 这样可以将 缩放(Scale) 和 偏移(Offset) 重置回初始值
      _scopeViewKey++; 
    });
  }
  @override
  Widget build(BuildContext context) {
    // 获取控制器状态以读取变量列表
    final controller = context.watch<DeviceController>();
    final colorScheme = Theme.of(context).colorScheme;
    

    
    // 获取所有标记为高频的变量
    final highFreqVars = controller.registry.values.where((v) => v.isHighFreq).toList();

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
        // -----------------------------------------------------------
        // 1. 左侧侧边栏 (显示图例、变量名和实时数值)
        // -----------------------------------------------------------
        
              Container(
                width: 160,
                decoration: BoxDecoration(
                  color: const Color(0xFF252526), // 仿 IDE 风格深色背景
                  border: Border(right: BorderSide(color: Colors.white.withOpacity(0.1)))
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Text(
                        "通道列表", 
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white.withOpacity(0.9))
                      ),
                    ),
                    const Divider(height: 1, color: Colors.white24),
                    Expanded(
                      child: ListView.builder(
                        itemCount: highFreqVars.length,
                        itemBuilder: (ctx, i) {
                          final v = highFreqVars[i];
                          final color = colors[i % colors.length];
                          // 获取当前变量的最新值用于展示
                          final currentVal = multiChannelPoints[v.id]?.lastOrNull?.toStringAsFixed(2) ?? "---";

                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.05)))
                            ),
                            child: Row(
                              children: [
                                // 颜色指示器
                                Container(
                                  width: 4, height: 24,
                                  color: color,
                                  margin: const EdgeInsets.only(right: 12),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(v.name, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                      const SizedBox(height: 2),
                                      Text(
                                        currentVal, 
                                        style: TextStyle(color: color, fontFamily: 'monospace', fontWeight: FontWeight.bold)
                                      ),
                                    ],
                                  ),
                                )
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    // 底部提示
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        "操作提示:\n左侧滚轮: 缩放Y轴\n右侧滚轮: 缩放X轴\n双击: 添加游标",
                        style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 10),
                      ),
                    )
                  ],
                ),
              ),
              // -----------------------------------------------------------
              // 2. 右侧绘图区 (集成 InteractiveScope)
              // -----------------------------------------------------------
              Expanded(
                child: InteractiveScope(
                  dataPoints: multiChannelPoints,
                  varIds: highFreqVars.map((e) => e.id).toList(),
                  colors: colors,
                  deltaTime: _deltaTime, // <--- 传入这个关键参数
                ),
              ),
            ],
          )
        ),
        // -----------------------------------------------------------
        // 3. 底部设置栏 (新增)
        // -----------------------------------------------------------
        Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          color: const Color(0xFF333333),
          child: Row(
            children: [
              const Icon(Icons.settings, color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              const Text("配置:", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              const SizedBox(width: 20),
              
              // 缓冲区设置
              _buildInput("缓冲区大小(点)", _bufferCtrl),
              const SizedBox(width: 20),
              
              // Delta T 设置
              _buildInput("采样间隔 Δt (ms)", _dtCtrl),
              
              const SizedBox(width: 20),
              ElevatedButton(
                onPressed: _updateConfig,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
                child: const Text("应用设置"),
              ),
              const SizedBox(width: 20),
              OutlinedButton.icon(
                onPressed: _clearBuffer,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text("清空显示"),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent, // 红色文字警告这是删除操作
                  side: const BorderSide(color: Colors.redAccent),
                  padding: const EdgeInsets.symmetric(horizontal: 16)
                ),
              ),
              const Spacer(),
              // 显示当前状态
              Text(
                "Total: $_bufferSize pts | Rate: ${_deltaTime}ms/pt",
                style: const TextStyle(color: Colors.white38, fontSize: 12)
              ),
              
            ],
          ),
        )
        
        
      ],
    );
  }
  // 辅助构建输入框的小组件
  Widget _buildInput(String label, TextEditingController ctrl) {
    return Row(
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(width: 8),
        SizedBox(
          width: 60,
          height: 30,
          child: TextField(
            controller: ctrl,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              filled: true,
              fillColor: Colors.black26,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              border: OutlineInputBorder(borderSide: BorderSide.none),
            ),
            onSubmitted: (_) => _updateConfig(),
          ),
        ),
      ],
    );
  }
}
class InteractiveScope extends StatefulWidget {
  final Map<int, List<double>> dataPoints;
  final List<int> varIds;
  final List<Color> colors;
  final double deltaTime;

  const InteractiveScope({
    super.key,
    required this.dataPoints,
    required this.varIds,
    required this.colors,
    this.deltaTime = 1.0
  });

  @override
  State<InteractiveScope> createState() => _InteractiveScopeState();
}

class _InteractiveScopeState extends State<InteractiveScope> {
  // 视图变换状态
  double _scaleX = 1.0;
  double _scaleY = 1.0;
  double _offsetX = 0.0; // X轴偏移 (像素)
  double _offsetY = 0.0; // Y轴偏移 (像素)

//是否锁定横坐标至最右侧的标志位
  bool _autoLock = true;
  // 游标系统
  double? _cursorX; // 游标位置 (对应数据的 index 或时间)

  // 布局常量
  final double _yAxisWidth = 50.0; // 左侧 Y 轴区域宽度
  final double _xAxisHeight = 30.0; // 底部 X 轴区域高度
  @override
  void didUpdateWidget(InteractiveScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 关键修复：当数据更新时，如果处于自动锁定模式，强制将视图移到最右边
    if (_autoLock && widget.dataPoints.isNotEmpty) {
      // 找到所有通道中最长的数据长度
      int maxLen = 0;
      for (var p in widget.dataPoints.values) {
        if (p.length > maxLen) maxLen = p.length;
      }
      
      if (maxLen > 0) {
        // 计算 OffsetX，使得最后一个点 (maxLen) 位于绘图区右侧边缘
        // 公式：ScreenX = Index * Scale + Offset
        // Offset = ScreenX - Index * Scale
        // 我们希望 Index = maxLen 时，ScreenX = 控件宽度 - 边距
        
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final drawWidth = context.size?.width ?? 400; // 获取当前宽度
          final chartWidth = drawWidth - _yAxisWidth;
          
          setState(() {
             // 稍微留一点右边距 (-10)
            _offsetX = chartWidth + _yAxisWidth - (maxLen * _scaleX) - 10;
          });
        });
      }
    }
  }

  void _handleWheel(PointerScrollEvent event, BoxConstraints constraints) {
    setState(() {
      final double zoomFactor = 0.1;
      final bool isZoomIn = event.scrollDelta.dy < 0;
      final double scaleMultiplier = isZoomIn ? (1 + zoomFactor) : (1 - zoomFactor);

      // 判断鼠标位置
      final localPos = event.localPosition;
      final bool inYAxisArea = localPos.dx < _yAxisWidth;
      
      _autoLock = false; // 用户介入，取消自动跟随
      // 如果在左侧 Y轴区域，缩放 Y
      if (inYAxisArea) {
        final double focalPointY = localPos.dy;
        // 缩放公式：保持鼠标指向的数值在屏幕位置不变
        // newOffset = mouse - (mouse - oldOffset) * scaleRatio
        _offsetY = focalPointY - (focalPointY - _offsetY) * scaleMultiplier;
        _scaleY *= scaleMultiplier;
      } 
      // 否则缩放 X (以鼠标当前X为中心)
      else {
        final double focalPointX = localPos.dx;
        _offsetX = focalPointX - (focalPointX - _offsetX) * scaleMultiplier;
        _scaleX *= scaleMultiplier;
      }
    });
  }

  void _handlePan(DragUpdateDetails details) {
    setState(() {
      // 同样，根据起始位置判断是拖动 X 还是 Y，或者简单起见支持双向拖动
      // 如果想模仿截图：
      // 在 Y轴区 -> 只拖动 Y
      // 在 绘图区 -> 拖动 X
      _autoLock = false;
      if (details.localPosition.dx < _yAxisWidth) {
         _offsetY += details.delta.dy;
      } else {
         _offsetX += details.delta.dx;
         // 如果想支持在绘图区也能上下拖动，可以取消注释下面这行：
         // _offsetY += details.delta.dy; 
      }
    });
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    // 双击添加/移动游标
    if (details.localPosition.dx > _yAxisWidth) {
      setState(() {
        // 将屏幕坐标反算回数据坐标 (Index)
        // ScreenX = DataX * ScaleX + OffsetX
        // DataX = (ScreenX - OffsetX) / ScaleX
        _cursorX = (details.localPosition.dx - _offsetX) / _scaleX;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) _handleWheel(event, constraints);
          },
          child: GestureDetector(
            onPanUpdate: _handlePan,
            onDoubleTapDown: _handleDoubleTapDown,
            child: Container(
              color: const Color(0xFF1E1E1E),
              child: ClipRect( // 防止绘制溢出
                child: CustomPaint(
                  painter: ProScopePainter(
                    allPoints: widget.dataPoints,
                    ids: widget.varIds,
                    colors: widget.colors,
                    scaleX: _scaleX,
                    scaleY: _scaleY,
                    offsetX: _offsetX,
                    offsetY: _offsetY,
                    cursorX: _cursorX,
                    yAxisWidth: _yAxisWidth,
                    xAxisHeight: _xAxisHeight,
                    deltaTime: widget.deltaTime,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class ProScopePainter extends CustomPainter {
  final Map<int, List<double>> allPoints;
  final List<int> ids;
  final List<Color> colors;
  
  // 视图变换参数
  final double scaleX;
  final double scaleY;
  final double offsetX;
  final double offsetY;
  
  // 游标
  final double? cursorX;

  // 布局参数
  final double yAxisWidth;
  final double xAxisHeight;
  //数据点间隔时间
  final double deltaTime;

  ProScopePainter({
    required this.allPoints,
    required this.ids,
    required this.colors,
    required this.scaleX,
    required this.scaleY,
    required this.offsetX,
    required this.offsetY,
    this.cursorX,
    required this.yAxisWidth,
    required this.xAxisHeight,
    required this.deltaTime,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final chartRect = Rect.fromLTWH(
      yAxisWidth, 
      0, 
      size.width - yAxisWidth, 
      size.height - xAxisHeight
    );

    // 1. 绘制网格
    _drawGrid(canvas, size, chartRect);

    // 2. 绘制波形 (使用 clipRect 确保不画到轴上)
    canvas.save();
    canvas.clipRect(chartRect);
    
    for (int i = 0; i < ids.length; i++) {
      final id = ids[i];
      final points = allPoints[id];
      if (points == null || points.isEmpty) continue;

      final paint = Paint()
        ..color = colors[i % colors.length]
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      final path = Path();
      bool isFirst = true;

      // 优化：只绘制屏幕可见范围内的数据点
      // index = (screenX - offsetX) / scaleX
      int startIndex = ((chartRect.left - offsetX) / scaleX).floor();
      int endIndex = ((chartRect.right - offsetX) / scaleX).ceil();
      
      // 边界检查
      if (startIndex < 0) startIndex = 0;
      if (endIndex > points.length - 1) endIndex = points.length - 1;
      
      // 如果数据过密，可以添加降采样逻辑 (这里暂略)

      for (int j = startIndex; j <= endIndex; j++) {
        // 坐标变换公式
        // X: index * scaleX + offsetX
        // Y: centerY - (value * scaleY) + offsetY
        // 注意：offsetY 这里作为用户拖拽的垂直偏移
        
        double x = (j * scaleX) + offsetX;
        // 默认基准是高度的一半，减去数值(向上)，加上用户偏移
        double y = (size.height / 2) - (points[j] * scaleY * 20) + offsetY; // *20 是个基础系数，让原本很小的值显眼一点

        if (isFirst) {
          path.moveTo(x, y);
          isFirst = false;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore(); // 结束 Clip

    // 3. 绘制游标
    if (cursorX != null) {
      double screenCursorX = (cursorX! * scaleX) + offsetX;

      // 只有游标在显示区域内才绘制
      if (screenCursorX >= chartRect.left && screenCursorX <= chartRect.right) {
        
        // A. 绘制垂直白线
        final cursorLinePaint = Paint()..color = Colors.white70..strokeWidth = 1;
        canvas.drawLine(
          Offset(screenCursorX, chartRect.top), 
          Offset(screenCursorX, chartRect.bottom), 
          cursorLinePaint
        );
        double cursorTime = cursorX! * deltaTime;
        // B. 绘制顶部的时间标签
        final timeTp = TextPainter(
          text: TextSpan(
            // 这里显示正确的时间
            text: " T: ${cursorTime.toStringAsFixed(1)}ms ", 
            style: const TextStyle(color: Colors.black, fontSize: 10, backgroundColor: Colors.white)
          ),
          textDirection: TextDirection.ltr
        )..layout();
        timeTp.paint(canvas, Offset(screenCursorX + 4, 10));

        // C. 遍历所有通道，计算交点并绘制数值
        // 我们取 cursorX 对应的整数索引
        int dataIndex = cursorX!.round();

        for (int i = 0; i < ids.length; i++) {
          final id = ids[i];
          final points = allPoints[id];
          final color = colors[i % colors.length];

          // 检查索引是否有效
          if (points != null && dataIndex >= 0 && dataIndex < points.length) {
            double value = points[dataIndex];
            
            // 计算数据点在屏幕上的 Y 坐标 (必须与绘制波形的公式完全一致)
            double screenY = (size.height / 2) - (value * scaleY * 20) + offsetY;

            // 只有点在可视范围内才画
            if (screenY >= chartRect.top && screenY <= chartRect.bottom) {
              
              // C1. 画一个小圆点
              canvas.drawCircle(Offset(screenCursorX, screenY), 4, Paint()..color = color);
              canvas.drawCircle(Offset(screenCursorX, screenY), 2, Paint()..color = Colors.black);

              // C2. 画数值标签 (带背景色，防止重叠看不清)
              final valTp = TextPainter(
                text: TextSpan(
                  text: value.toStringAsFixed(2), 
                  style: TextStyle(
                    color: Colors.white, 
                    fontSize: 10, 
                    fontWeight: FontWeight.bold,
                    backgroundColor: Colors.black.withOpacity(0.7) // 半透明黑底
                  )
                ),
                textDirection: TextDirection.ltr
              )..layout();

              // 错位显示，防止文字盖住点
              valTp.paint(canvas, Offset(screenCursorX + 8, screenY - 6));
            }
          }
        }
      }
    }

    // 4. 绘制坐标轴覆盖层 (背景)
    Paint bgPaint = Paint()..color = const Color(0xFF2D2D2D);
    // Y轴背景
    canvas.drawRect(Rect.fromLTWH(0, 0, yAxisWidth, size.height), bgPaint);
    // X轴背景
    canvas.drawRect(Rect.fromLTWH(0, size.height - xAxisHeight, size.width, xAxisHeight), bgPaint);

    // 5. 绘制轴刻度
    _drawYAxis(canvas, size);
    _drawXAxis(canvas, size);
  }

  void _drawGrid(Canvas canvas, Size size, Rect rect) {
    final paint = Paint()..color = Colors.white10..strokeWidth = 1;
    // 简单的十字网格
    double stepX = 100.0;
    double stepY = 50.0;
    
    // 实际上应该根据 scaleX/scaleY 动态计算网格密度，这里简化为固定像素间隔
    for (double x = rect.left; x < rect.right; x += stepX) {
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), paint);
    }
    for (double y = rect.top; y < rect.bottom; y += stepY) {
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
    }
  }

  void _drawYAxis(Canvas canvas, Size size) {
    final tp = TextPainter(textDirection: TextDirection.ltr);
    final linePaint = Paint()..color = Colors.white30;
    
    // 动态生成 Y 轴刻度
    // 我们可以根据屏幕像素反推数值
    double stepPixels = 50; 
    for (double y = 0; y < size.height - xAxisHeight; y += stepPixels) {
      // 数值反算: val = (centerY + offsetY - screenY) / (scaleY * 20)
      double center = size.height / 2;
      double val = (center + offsetY - y) / (scaleY * 20);
      
      tp.text = TextSpan(text: val.toStringAsFixed(1), style: const TextStyle(color: Colors.white60, fontSize: 10));
      tp.layout();
      tp.paint(canvas, Offset(5, y - 6));
      canvas.drawLine(Offset(yAxisWidth - 5, y), Offset(yAxisWidth, y), linePaint);
    }
  }
  
  void _drawXAxis(Canvas canvas, Size size) {
    final tp = TextPainter(textDirection: TextDirection.ltr);
    final linePaint = Paint()..color = Colors.white30;
    
    // 动态计算步长：尽量保证屏幕上每隔 80-120 像素显示一个刻度
    double stepPixels = 100 * scaleX; 
    if (stepPixels < 80) stepPixels = 100; // 简单的防过密处理
    
    // 遍历屏幕上的像素位置
    for (double x = yAxisWidth; x < size.width; x += stepPixels) {
       // 1. 反算数据索引 Index
       // ScreenX = Index * ScaleX + OffsetX
       // Index = (ScreenX - OffsetX) / ScaleX
       double indexVal = (x - offsetX) / scaleX;
       
       // 2. 将索引转换为时间 (Time = Index * DeltaT)
       double timeMs = indexVal * deltaTime;
       
       // 3. 格式化文本
       String label;
       if (timeMs.abs() >= 1000) {
         label = "${(timeMs / 1000).toStringAsFixed(1)}s";
       } else {
         label = "${timeMs.toStringAsFixed(0)}ms";
       }

       tp.text = TextSpan(
         text: label, 
         style: const TextStyle(color: Colors.white60, fontSize: 10)
       );
       tp.layout();
       tp.paint(canvas, Offset(x - 10, size.height - xAxisHeight + 5));
       canvas.drawLine(Offset(x, size.height - xAxisHeight), Offset(x, size.height - xAxisHeight + 5), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant ProScopePainter old) => true; // 总是重绘以响应高频数据
}