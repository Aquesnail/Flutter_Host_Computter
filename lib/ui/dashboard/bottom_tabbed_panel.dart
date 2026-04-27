import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/device_controller.dart';
import '../../debug_console.dart';
import '../../lowfreq_window.dart';
import '../attitude/attitude_window.dart';

class BottomTabbedPanel extends StatelessWidget {
  const BottomTabbedPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DefaultTabController(
      length: 2, // 标签数量
      child: Column(
        children: [
          // --- 顶部标签栏区域 ---
          Container(
            height: 36, // 设定一个较小的高度，类似浏览器标签栏
            width: double.infinity,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest, // 深色背景区分头部
              border: Border(bottom: BorderSide(color: colorScheme.outlineVariant)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TabBar(
                    isScrollable: true, // 允许标签靠左排列，而不是撑满宽度
                    tabAlignment: TabAlignment.start, // Flutter 3.13+ 支持，靠左对齐
                    dividerColor: Colors.transparent, // 去掉默认的下划线分割
                    labelPadding: const EdgeInsets.symmetric(horizontal: 20),
                    indicatorSize: TabBarIndicatorSize.tab,
                    // 选中的样式：底部有粗线条，文字高亮
                    indicator: UnderlineTabIndicator(
                      borderSide: BorderSide(width: 3.0, color: colorScheme.primary),
                    ),
                    labelColor: colorScheme.primary,
                    labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    unselectedLabelColor: colorScheme.onSurfaceVariant,
                    tabs: const [
                      Tab(text: "变量监控"), // Tab 1
                      Tab(text: "调试控制台"), // Tab 2
                    ],
                  ),
                ),
                Builder(builder: (context) {
                  final isDemo = context.select<DeviceController, bool>((c) => c.demoModeActive);
                  return PopupMenuButton<String>(
                    icon: Icon(Icons.more_horiz, size: 16, color: isDemo ? Colors.orangeAccent : null),
                    tooltip: "更多选项",
                    onSelected: (value) {
                      if (value == 'demo') {
                        context.read<DeviceController>().toggleDemoMode();
                      } else if (value == 'attitude') {
                        showAttitudeWindow(context);
                      }
                    },
                    itemBuilder: (context) {
                      return [
                        const PopupMenuItem(
                          value: 'attitude',
                          child: Row(
                            children: [
                              Icon(Icons.threed_rotation, size: 18),
                              SizedBox(width: 8),
                              Text('3D 姿态指示器'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'demo',
                          child: Builder(builder: (context) {
                            final isDemo = context.select<DeviceController, bool>((c) => c.demoModeActive);
                            return Row(
                              children: [
                                Icon(
                                  isDemo ? Icons.stop_circle : Icons.bug_report,
                                  size: 18,
                                  color: isDemo ? Colors.orangeAccent : null,
                                ),
                                const SizedBox(width: 8),
                                Text(isDemo ? "停止Demo" : "载入Demo数据"),
                              ],
                            );
                          }),
                        ),
                      ];
                    },
                  );
                }),
              ],
            ),
          ),

          // --- 下方内容区域 ---
          Expanded(
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(),
              children: [
                const LowFreqWindow(),
                const DebugConsole(), // <--- 把原来的占位符替换成这个
              ],
            ),
          ),
        ],
      ),
    );
  }
}
