import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'device_control.dart';
import 'debug_protocol.dart';

class DebugConsole extends StatefulWidget {
  const DebugConsole({super.key});

  @override
  State<DebugConsole> createState() => _DebugConsoleState();
}
class _DebugConsoleState extends State<DebugConsole> with AutomaticKeepAliveClientMixin { //加上这个才能维持状态

  @override
  bool get wantKeepAlive => true; //保证切换Tab不丢状态
  // 【修改点1】维护两个列表
  final List<LogEntry> _allLogs = [];     // 所有的历史记录 (Source of Truth)
  final List<LogEntry> _visibleLogs = []; // UI 实际渲染的列表 (View Data)
  
  final ScrollController _scrollCtrl = ScrollController();


  // --- 性能优化：临时缓冲区 ---
  final List<LogEntry> _pendingLogs = []; // 攒一波数据再刷新
  Timer? _refreshTimer;

  final TextEditingController _inputCtrl = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  String? _hexErrorText;
  bool _useProtocol = true; // 是否启用协议发送
  bool _isHexMode = false;  // false=ASCII, true=HEX (仅在 _useProtocol=false 时有效)

  bool _autoScroll = true; 
  bool _showHex = false; // 默认显示所有

  StreamSubscription? _sub;
@override
  void initState() {
    super.initState();
    final ctrl = context.read<DeviceController>();

    // 1. 初始化加载历史
    _allLogs.addAll(ctrl.combinedHistory);
    _rebuildVisibleList();

    // 2. 订阅日志流 (只存数据，不刷新 UI)
    _sub = ctrl.logStream.listen((entry) {
      // 【关键点 2】收到数据不再 setState，而是扔进暂存区
      _pendingLogs.add(entry);
    });

    // 3. 启动 10Hz 定时刷新器 (每 100ms 刷新一次)
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_pendingLogs.isEmpty) return;

      if (!mounted) return;

      setState(() {
        // A. 进货
        _allLogs.addAll(_pendingLogs);
        
        // B. 如果开启了 Hex 显示，也同步进货到可见列表
        if (_showHex) {
            _visibleLogs.addAll(_pendingLogs);
        } else {
            // 如果没开 Hex，只挑出 Info/Error 进货
            for (var log in _pendingLogs) {
              if (log.type == LogType.info || log.type == LogType.error) {
                _visibleLogs.add(log);
              }
            }
        }
        
        _pendingLogs.clear();

        // --- C. 核心优化：智能丢弃策略 ---
        const int maxLogs = 3000;
        
        // 只有当总数量超标时才触发修剪
        if (_allLogs.length > maxLogs) {
           int removeCount = _allLogs.length - maxLogs;
           
           // 策略：优先从列表头部开始，查找并删除 RX/TX 类型的日志
           // 这是一个 O(N) 操作，但在 3000 条规模下 100ms 跑一次是完全没压力的
           
          // 倒序循环删除比较安全，或者使用 removeWhere (但 removeWhere 无法控制数量)
          // 我们这里采用简单粗暴但高效的方法：
          // 直接检查头部，如果是 RX/TX 就删，如果是 Info 就跳过继续找
          
          int removed = 0;
          int i = 0;
          while (removed < removeCount && i < _allLogs.length) {
            final type = _allLogs[i].type;
            if (type == LogType.rx || type == LogType.tx) {
              _allLogs.removeAt(i); // 删除当前位置
              // 注意：删除了元素，i 不需要 ++，因为下一个元素补位到了 i
              removed++;
            } else {
              // 这是一个珍贵的 Info/Error，保留它，检查下一个
              i++;
            }
          }
          
          // 如果删了一圈还没删够 (说明满屏都是 Info)，那就只能硬删头部的 Info 了
          if (removed < removeCount) {
            _allLogs.removeRange(0, removeCount - removed);
          }

          if (_visibleLogs.length > maxLogs) {
           _visibleLogs.removeRange(0, _visibleLogs.length - maxLogs);
          }
        }
      });

      // E. 批量更新后的自动滚动
      if (_autoScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollCtrl.hasClients) {
            _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
          }
        });
      }
    });
    
    // 输入框监听
    _inputCtrl.addListener(_validateInput);

    // 滚动监听
    _scrollCtrl.addListener(() {
      final isAtBottom = _scrollCtrl.position.pixels >= _scrollCtrl.position.maxScrollExtent - 50;
      if (isAtBottom && !_autoScroll) {
        setState(() => _autoScroll = true);
      } else if (!isAtBottom && _autoScroll) {
        setState(() => _autoScroll = false);
      }
    });
  }

  // 【核心方法】判断某条日志是否应该显示
  bool _shouldShow(LogEntry log) {
    if (_showHex) return true; // 如果开关打开，显示所有
    // 如果开关关闭，只显示 Info 和 Error，隐藏 RX/TX
    return log.type == LogType.info || log.type == LogType.error;
  }

  // 【核心方法】当开关切换时，全量重新计算显示列表
  void _rebuildVisibleList() {
    _visibleLogs.clear();
    if (_showHex) {
      _visibleLogs.addAll(_allLogs);
    } else {
      _visibleLogs.addAll(_allLogs.where((log) => 
        log.type == LogType.info || log.type == LogType.error
      ));
    }
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _inputFocus.dispose();
    _refreshTimer?.cancel();
    _sub?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // 校验 Hex 输入逻辑
  void _validateInput() {
    if (_useProtocol || !_isHexMode) {
      if (_hexErrorText != null) setState(() => _hexErrorText = null);
      return;
    }

    String text = _inputCtrl.text;
    // 1. 允许空格，所以先去掉空格
    String cleanText = text.replaceAll(RegExp(r'\s+'), '');
    
    if (cleanText.isEmpty) {
      setState(() => _hexErrorText = null); // 空输入不算错
      return;
    }

    // 2. 正则校验：只能包含 0-9, a-f, A-F
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(cleanText)) {
      setState(() => _hexErrorText = "包含非法字符 (仅限 0-9, A-F)");
      return;
    }

    // 3. 长度校验：必须是偶数 (2个字符=1字节)
    if (cleanText.length % 2 != 0) {
      setState(() => _hexErrorText = "位数不完整 (需为偶数)");
      return;
    }

    // 校验通过
    if (_hexErrorText != null) setState(() => _hexErrorText = null);
  }

  void _sendMessage() {
    final text = _inputCtrl.text;
    if (text.isEmpty) return;
    if (_hexErrorText != null) return; // 有错误不发送

    final ctrl = context.read<DeviceController>();
    if (!ctrl.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("请先连接串口!"), backgroundColor: Colors.red));
      return;
    }

    try {
      Uint8List dataToSend;

      if (_useProtocol) {
        // 模式 A: 协议封装发送 (作为文本)
        dataToSend = DebugProtocol.packTextCmd(text);
      } else {
        // 模式 B: 裸数据发送
        if (_isHexMode) {
          // HEX 发送：清洗空格 -> 解析
          String cleanText = text.replaceAll(RegExp(r'\s+'), '');
          List<int> bytes = [];
          for (int i = 0; i < cleanText.length; i += 2) {
            String byteStr = cleanText.substring(i, i + 2);
            bytes.add(int.parse(byteStr, radix: 16));
          }
          dataToSend = Uint8List.fromList(bytes);
        } else {
          // ASCII 发送
          dataToSend = Uint8List.fromList(utf8.encode(text));
        }
      }

      // 执行发送
      ctrl.sendData(dataToSend);
      
      // 可选：发送后清空输入框
      // _inputCtrl.clear(); 
      
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("发送失败: $e"), backgroundColor: Colors.red));
    }
  }

  void _clearLogs() {
    setState(() {
      _allLogs.clear();
      _visibleLogs.clear();
    });
  }

 @override
  Widget build(BuildContext context) {
    super.build(context);
    const fontFamily = 'monospace'; 

    return Container(
      color: const Color(0xFF1E1E1E), 
      child: Column(
        children: [
          // --- 工具栏 ---
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: const BoxDecoration(
              color: Colors.black26,
              border: Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20, color: Colors.white70),
                  onPressed: _clearLogs,
                  tooltip: "清空日志",
                ),
                const SizedBox(width: 10),
                
                // --- 过滤器开关 ---
                FilterChip(
                  label: Text(_showHex ? "显示裸包 (Hex)" : "只看日志"),
                  selected: _showHex,
                  checkmarkColor: Colors.white,
                  selectedColor: Colors.blueAccent.withOpacity(0.3),
                  labelStyle: TextStyle(
                    color: _showHex ? Colors.blueAccent : const Color.fromARGB(179, 110, 110, 110), 
                    fontSize: 12
                  ),
                  onSelected: (val) {
                    setState(() {
                      _showHex = val;
                      _rebuildVisibleList(); // 【关键】切换后立刻重算列表
                      
                      // 切换过滤后，如果之前在底部，最好重新跳到底部
                      if (_autoScroll) {
                         WidgetsBinding.instance.addPostFrameCallback((_) {
                            if(_scrollCtrl.hasClients) _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
                         });
                      }
                    });
                  },
                ),

                const Spacer(),
                if (!_autoScroll)
                  InkWell(
                    onTap: () {
                      setState(() => _autoScroll = true);
                      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.blue, 
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.arrow_downward, size: 14, color: Colors.white),
                          SizedBox(width: 4),
                          Text("滚动到底部", style: TextStyle(fontSize: 11, color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // --- 日志列表 ---
          Expanded(
            child: SelectionArea(
              child: ListView.builder(
                controller: _scrollCtrl,
                // 【关键】itemCount 是可见列表的长度
                itemCount: _visibleLogs.length, 
                padding: const EdgeInsets.all(8),
                
                // 【性能优化】现在你可以放心地使用 itemExtent 了！
                // 因为没有了 SizedBox.shrink()，每一行都是实实在在的内容
                // 如果你的日志大部分是单行，开启这个会飞快。如果是多行，就不要开。
                itemExtent: 20, 

                itemBuilder: (context, index) {
                  // 直接取可见列表的数据，无需再做 if 判断
                  final log = _visibleLogs[index]; 
                  return _buildLogItem(log, fontFamily);
                },
              ),
            ),
          ),
          _buildInputArea(context),
        ],
      ),
    );
  }

  Widget _buildLogItem(LogEntry log, String fontFamily) {
    Color color;
    String prefix;

    switch (log.type) {
      case LogType.tx:
        color = Colors.greenAccent; // 发送：绿色
        prefix = "TX >>";
        break;
      case LogType.rx:
        color = Colors.blueAccent;  // 接收：蓝色
        prefix = "RX <<";
        break;
      case LogType.info:
        color = Colors.amberAccent; // MCU 消息：黄色
        prefix = "[MSG]";
        break;
      case LogType.error:
        color = Colors.redAccent;   // 错误：红色
        prefix = "[ERR]";
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: RichText(
        text: TextSpan(
          style: TextStyle(fontFamily: fontFamily, fontSize: 12),
          children: [
            // 时间 (灰色)
            TextSpan(
              text: "[${log.timeStr}] ", 
              style: const TextStyle(color: Colors.grey)
            ),
            // 前缀 (彩色)
            TextSpan(
              text: "$prefix ", 
              style: TextStyle(color: color, fontWeight: FontWeight.bold)
            ),
            // 内容 (白色)
            TextSpan(
              text: log.content, 
              style: const TextStyle(color: Colors.white70)
            ),
          ],
        ),
      ),
    );
  }
  Widget _buildInputArea(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: const BoxDecoration(
        color: Color(0xFF2D2D2D), // 比背景稍亮
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- 第一行：发送配置 ---
          Row(
            children: [
              // 协议开关
              _buildCheckOption(
                label: "协议封装", 
                value: _useProtocol, 
                onChanged: (v) {
                  setState(() {
                    _useProtocol = v;
                    _validateInput(); // 切换模式需重新校验
                  });
                }
              ),
              
              const SizedBox(width: 16),
              
              // 裸数据模式下的格式选择 (互斥)
              // 只有当不使用协议时才可用
              Opacity(
                opacity: _useProtocol ? 0.5 : 1.0,
                child: Row(
                  children: [
                    _buildRadioOption(label: "ASCII", isHex: false),
                    const SizedBox(width: 8),
                    _buildRadioOption(label: "HEX", isHex: true),
                  ],
                ),
              ),
              
              const Spacer(),
              // 提示信息
              if (_hexErrorText != null)
                Text(_hexErrorText!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ),
          
          const SizedBox(height: 8),
          
          // --- 第二行：输入框 + 发送按钮 ---
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inputCtrl,
                  focusNode: _inputFocus,
                  style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: _useProtocol 
                        ? "输入文本 (将自动封装为协议包)" 
                        : (_isHexMode ? "输入 HEX (如: AA BB CC)" : "输入 ASCII 字符串"),
                    hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
                    filled: true,
                    fillColor: Colors.black26,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    // 如果有错误，输入框变红
                    errorText: _hexErrorText == null ? null : "", 
                    errorStyle: const TextStyle(height: 0), // 隐藏自带的错误文字，用上面的 Text 显示
                  ),
                  onSubmitted: (_) => _sendMessage(), // 回车发送
                ),
              ),
              const SizedBox(width: 8),
              
              // 发送按钮
              ElevatedButton.icon(
                onPressed: (_hexErrorText != null) ? null : _sendMessage,
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                ),
                icon: const Icon(Icons.send, size: 16),
                label: const Text("发送"),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 辅助构建 Checkbox
  Widget _buildCheckOption({required String label, required bool value, required Function(bool) onChanged}) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24, 
            height: 24, 
            child: Checkbox(
              value: value, 
              onChanged: (v) => onChanged(v!),
              activeColor: Colors.blueAccent,
            )
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }

  // 辅助构建 Radio 样式
  Widget _buildRadioOption({required String label, required bool isHex}) {
    final isSelected = _isHexMode == isHex;
    return InkWell(
      onTap: _useProtocol ? null : () {
        setState(() {
          _isHexMode = isHex;
          _validateInput();
        });
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blueAccent.withOpacity(0.2) : Colors.transparent,
          border: Border.all(color: isSelected ? Colors.blueAccent : Colors.white24),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label, 
          style: TextStyle(
            color: isSelected ? Colors.blueAccent : Colors.white54, 
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal
          )
        ),
      ),
    );
  }
}