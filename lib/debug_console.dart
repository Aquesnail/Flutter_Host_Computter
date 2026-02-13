import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'device_control.dart';

class DebugConsole extends StatefulWidget {
  const DebugConsole({super.key});

  @override
  State<DebugConsole> createState() => _DebugConsoleState();
}
class _DebugConsoleState extends State<DebugConsole> {
  // 【修改点1】维护两个列表
  final List<LogEntry> _allLogs = [];     // 所有的历史记录 (Source of Truth)
  final List<LogEntry> _visibleLogs = []; // UI 实际渲染的列表 (View Data)
  
  final ScrollController _scrollCtrl = ScrollController();
  bool _autoScroll = true; 
  bool _showHex = false; // 默认显示所有

  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    final ctrl = context.read<DeviceController>();

    // 1. 初始化加载
    _allLogs.addAll(ctrl.recentLogs);
    _rebuildVisibleList(); // 根据当前开关生成显示列表

    // 2. 订阅新日志
    _sub = ctrl.logStream.listen((entry) {
      if (!mounted) return;
      setState(() {
        // A. 添加到总表
        _allLogs.add(entry);
        if (_allLogs.length > 2000) _allLogs.removeAt(0);

        // B. 判断是否需要添加到显示表 (增量更新，不要每次都全量重算，性能更好)
        if (_shouldShow(entry)) {
           _visibleLogs.add(entry);
           // 如果总表删了旧数据，显示表可能也需要同步删除头部
           // (简单的做法是限制 visibleLogs 长度，或者定期清理)
           if (_visibleLogs.length > 2000) _visibleLogs.removeAt(0);
        }
      });

      // 3. 自动滚动
      if (_autoScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollCtrl.hasClients) {
            _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
          }
        });
      }
    });

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
    _sub?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _clearLogs() {
    setState(() {
      _allLogs.clear();
      _visibleLogs.clear();
    });
  }

 @override
  Widget build(BuildContext context) {
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
}