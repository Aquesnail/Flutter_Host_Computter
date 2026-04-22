import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/services/device_controller.dart';
import 'dashboard/layout_dashboard.dart';
import 'widgets/connection_status_chips.dart';
import 'widgets/handshake_button.dart';
import 'widgets/serial_traffic_monitor.dart';

class MainWindow extends StatelessWidget {
  //完全依赖provider的局部刷新
  const MainWindow({super.key});

  @override
  Widget build(BuildContext context) {
    // 整个 MainWindow 不再监听任何东西
    // 只有内部的 Selector 和 context.select 会触发局部刷新
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: colorScheme.primary,
            child: Row(
              children: [
                // 1. 刷新按钮：只在 [isConnected] 改变时重绘
                Builder(builder: (context) {
                  final isConnected = context.select<DeviceController, bool>((c) => c.isConnected);
                  //这里我们用了StatelessWidget，完全将局部刷新的任务交给了provider
                  //这里的意思是我们只监听DeviceController中isConnected这一个变量的值，
                  return IconButton(
                    tooltip: "刷新端口",
                    icon: const Icon(Icons.refresh, size: 20, color: Colors.white),
                    onPressed: isConnected ? null : () => context.read<DeviceController>().refreshPorts(),//
                  );
                }),

                const SizedBox(width: 10),

                // 2. 串口下拉框：只在 [availablePorts] 或 [selectedPort] 改变时重绘
                Selector<DeviceController, (List<String>, String?)>(
                  selector: (_, c) => (c.availablePorts, c.selectedPort),
                  builder: (context, data, _) {
                    return DropdownButton<String>(
                      value: data.$2,
                      hint: const Text("选择串口", style: TextStyle(color: Colors.white70)),
                      items: data.$1.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                      onChanged: (v) => context.read<DeviceController>().selectedPort = v,
                    );
                  },
                ),

                const SizedBox(width: 10),
                const Text("波特率:", style: TextStyle(color: Colors.white)),

                // 3. 波特率下拉框
                Selector<DeviceController, int>(
                  selector: (_, c) => c.selectedBaudRate,
                  builder: (context, rate, _) {
                    final isConnected = context.select<DeviceController, bool>((c) => c.isConnected);
                    return DropdownButton<int>(
                      value: rate,
                      items: [9600, 19200, 38400, 57600, 115200, 256000]
                          .map((b) => DropdownMenuItem(value: b, child: Text(b.toString())))
                          .toList(),
                      onChanged: isConnected ? null : (v) => context.read<DeviceController>().selectedBaudRate = v!,
                    );
                  },
                ),

                const SizedBox(width: 15),

                // 4. 连接按钮
                Builder(builder: (context) {
                  final isConnected = context.select<DeviceController, bool>((c) => c.isConnected);
                  return ElevatedButton.icon(
                    onPressed: () {
                      final ctrl = context.read<DeviceController>();
                      isConnected ? ctrl.disconnect() : ctrl.connectWithInternal();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isConnected ? Colors.redAccent : Colors.green,
                      foregroundColor: Colors.white,
                    ),
                    icon: Icon(isConnected ? Icons.link_off : Icons.link, size: 18),
                    label: Text(isConnected ? "关闭" : "打开"),
                  );
                }),

                const SizedBox(width: 8),

                // 5. 握手按钮
                const HandshakeButton(),

                const SizedBox(width: 10),

                const SerialTrafficMonitor(),

                const SizedBox(width: 10),

                // Demo 测试数据按钮
                Builder(builder: (context) {
                  final isDemo = context.select<DeviceController, bool>((c) => c.demoModeActive);
                  return Tooltip(
                    message: isDemo ? "停止Demo数据" : "载入Demo测试数据",
                    child: Material(
                      color: isDemo ? Colors.orange.withValues(alpha: 0.3) : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => context.read<DeviceController>().toggleDemoMode(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isDemo ? Icons.stop_circle : Icons.bug_report,
                                size: 18,
                                color: isDemo ? Colors.orangeAccent : Colors.white70,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isDemo ? "Demo中" : "Demo",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDemo ? Colors.orangeAccent : Colors.white70,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),

                const Spacer(),

                // 6. 状态标签：精准监听
                const ConnectionStatusChips(),
              ],
            ),
          ),
          // 7. 核心优化：LayoutDashboard 现在被 const 保护，或者完全不受上方 UI 波动影响
          const Expanded(child: LayoutDashboard())
        ],
      ),
    );
  }
}
