import 'package:flutter/material.dart';
import '../../debug_console.dart';
import '../../lowfreq_window.dart';

class BottomTabbedPanel extends StatelessWidget {
  const BottomTabbedPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // 假设这是你接下来要写的第二个控件，暂时用占位符代替
    final Widget secondWidget = Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.terminal, size: 48, color: Colors.grey),
          const SizedBox(height: 10),
          Text("调试控制台 (待开发)", style: TextStyle(color: colorScheme.onSurfaceVariant)),
        ],
      ),
    );

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
                // 可以在右侧加一些小工具按钮，比如“清空”、“导出”等
                IconButton(
                  icon: const Icon(Icons.more_horiz, size: 16),
                  onPressed: () {},
                  tooltip: "更多选项",
                )
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
