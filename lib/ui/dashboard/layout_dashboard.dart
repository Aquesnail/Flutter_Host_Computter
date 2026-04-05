import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'scope_dashboard.dart';
import 'bottom_tabbed_panel.dart';
import 'static_vars_panel.dart';

class LayoutDashboard extends StatefulWidget {
  const LayoutDashboard({super.key});

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
          size: 250, // 【关键】给一个明确的初始像素宽度，而不是 flex 比例
          min: 150, // 【限位】限制最小宽度 150px，防止内容被压扁
          max: 500 // 【限位】(可选) 限制最大宽度，防止拉太宽
        )
      ]
    );

    // 2. 底部控制器：同理，左侧自适应，右侧固定
    _bottomController = MultiSplitViewController(
      areas: [
        Area(data: 'bottom_left', flex: 1),
        Area(
          data: 'bottom_right',
          size: 250, // 初始宽度
          min: 150, // 最小宽度保护
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
          size: 200, // 初始高度 200px
          min: 150, // 最小高度 100px
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
            backgroundColor: colorScheme.surfaceContainerHighest,
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
                  if (area.data == 'top_left') {
                    return const ScopeDashboard();
                  }
                  return const StaticVarsPanel();
                }
              );
            } else {
              return MultiSplitView(
                axis: Axis.horizontal,
                controller: _bottomController,
                // 下面两格用次级色容器（通常是浅紫色或配套色），看出层次感
                builder: (context, area) {
                  if (area.data == "bottom_left") {
                    return const BottomTabbedPanel();
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
