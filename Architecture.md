# Architecture

本文档描述本项目的整体架构设计，包括全局状态管理、路由/布局方案以及通信协议。

---

## 1. 全局状态管理

### 1.1 技术选型
- **框架**: `provider` (ChangeNotifierProvider + Selector / context.select)
- **数据流**: 单一数据源 (Single Source of Truth)，以 `DeviceController` 为中心

### 1.2 状态层 (`lib/core/services/`)

| 文件 | 职责 |
|------|------|
| `core/services/device_controller.dart` | 唯一的状态管理器，继承 `ChangeNotifier`。负责串口生命周期、协议解析、变量注册表 (`registry`)、日志缓存、握手状态，以及 Demo 测试数据模式。 |
| `core/models/registered_var.dart` | 变量元数据模型 `RegisteredVar`。 |
| `core/models/log_entry.dart` | 日志模型 `LogEntry` 与枚举 `LogType`。 |

### 1.3 Provider 注入点
```dart
// lib/app.dart
MultiProvider(
  providers: [
    ChangeNotifierProvider(create: (_) => DeviceController()),
  ],
  child: MaterialApp(home: MainWindow()),
)
```

### 1.4 UI 消费方式
- **粗粒度刷新**: 极少数场景使用 `context.watch<DeviceController>()`。
- **精准刷新**: 大量使用 `Selector<T, S>` 与 `context.select<T, S>()`，只监听特定字段（如 `isConnected`、`registry.keys`），避免整树重建。
- **命令发送**: 使用 `context.read<DeviceController>().xxx()` 触发副作用（连接串口、发送数据等）。

### 1.5 高频数据免刷新策略
- 高频采样数据通过 `DeviceController.highFreqStream`（`Stream<MapEntry<int, double>>`）直接推流。
- 底层绘图区（`ScopeDashboard`）订阅该 Stream，在内存中写入 `RingBuffer`，不经过 Provider，从而彻底绕过 Flutter 的 build 阶段。
- `ScopeDashboard` 使用独立的 60Hz `Timer` 做 UI 刷新，与数据接收解耦。

---

## 2. 路由方案

本项目采用**无 Navigator 路由**的单页面应用（SPA）架构，所有界面通过物理布局分割与标签页切换组合而成。

### 2.1 顶层结构
```
MainWindow (AppBar 区域)
  └── LayoutDashboard (Body 区域)
        ├── TOP_ROW (上方主区域)
        │     └── MultiSplitView (水平)
        │           ├── top_left   → ScopeDashboard (示波器)
        │           └── top_right  → StaticVarsPanel (静态变量面板)
        └── BOTTOM_ROW (下方区域)
              └── MultiSplitView (水平)
                    ├── bottom_left  → BottomTabbedPanel (标签页)
                    └── bottom_right → 占位面板
        └── ATTITUDE_WINDOW (模态对话框)
              └── AttitudeWindowContent (720×560 3D 姿态指示器)
```

### 2.2 标签页 (`BottomTabbedPanel`)
- 使用 `DefaultTabController` + `TabBar` + `TabBarView` 实现。
- 标签内容：
  1. **变量监控** → `LowFreqWindow`
  2. **调试控制台** → `DebugConsole`
- `physics: NeverScrollableScrollPhysics()` 禁用滑动，仅通过 Tab 切换。

### 2.3 分屏 (`multi_split_view`)
- 使用 `MultiSplitViewController` 管理各区域比例/固定尺寸。
- 顶部左侧（示波器）与底部左侧（标签页）使用 `flex: 1` 自适应。
- 右侧面板使用固定 `size` + `min`/`max` 限制，防止被压扁。

---

## 3. 通信协议

### 3.1 物理层
- **接口**: USB 串口 (via `flutter_libserialport`)
- **配置**: 波特率可配置（默认 115200），数据位 8，停止位 1

### 3.2 上位机 → 下位机（请求帧）
帧格式定义在 `lib/debug_protocol.dart` 的 `DebugProtocol` 类中：

| 偏移 | 长度 | 说明 |
|------|------|------|
| 0 | 1 | 帧头 `0x55` |
| 1 | 1 | 命令字 (CMD) |
| 2 | 1 | 内部载荷长度 N |
| 3 | N | 载荷数据 |
| 3+N | 2 | CRC16-MODBUS (高字节在前) |

**CRC 范围**: 命令字 + 长度 + 载荷（不含帧头和 CRC 自身）。

**支持的命令字**: `0x00` 握手、`0x55` 修改变量、`0x56` 动态注册、`0x57` 文本、`0x58` 请求刷新静态变量。

### 3.3 下位机 → 上位机（数据帧）
定义在 `DeviceController._onDataReceived` 中解析：

| 偏移 | 长度 | 说明 |
|------|------|------|
| 0 | 1 | 帧头 `0xAA` |
| 1 | 1 | 变量 ID (VID) |
| 2 | 1 | 原始类型字节 (含高频/静态标志) |
| 3 | 1 | 数据长度 VLen |
| 4 | VLen | 数据载荷 |
| 4+VLen | 2 | CRC16-MODBUS (高字节在前) |

**特殊 VID 定义**:
- `0xFD`: 握手响应
- `0xFC`: 批量高频数据包
- `0xFE`: 变量元数据注册/更新
- `0xFF`: 日志文本 (ASCII)
- 其他: 普通变量当前值

### 3.4 类型字节编码
- 低 4 位 (`maskType = 0x0F`): 基础类型 (`uint8`~`float`)
- 第 4 位 (`maskFreq = 0x10`): 高频标志
- 第 5 位 (`maskStatic = 0x20`): 静态变量标志（需手动刷新）

### 3.5 数据缓存与流
- `DeviceController.highFreqStream` 向订阅者推送每条解析出的高频数据。
- `DeviceController.logStream` 向 `DebugConsole` 推送新增的日志条目。

---

## 4. 静态变量功能设计

### 4.1 功能概述
静态变量是一种特殊类型的监控变量，其值**不会自动刷新**，需要上位机主动发送刷新请求 (CMD=0x58)。

### 4.2 UI 布局
- **静态变量面板** (`StaticVarsPanel`) 位于主界面右上角
- **低频变量窗口** (`LowFreqWindow`) 位于底部标签页，仅显示非静态变量

### 4.3 交互行为
| 操作 | 行为 |
|------|------|
| 修改变量值 | 发送写命令 (0x55)，如为静态变量则**自动**请求刷新 |
| 点击刷新按钮 | 发送刷新请求 (0x58) |
| 点击"全部刷新" | 批量发送所有静态变量的刷新请求 |

### 4.4 数据分类
| 类型 | 高频标志 | 静态标志 | 刷新方式 | 显示位置 |
|------|---------|---------|---------|---------|
| 高频变量 | 1 | 0 | 下位机周期性批量推送 | 示波器 |
| 低频变量 | 0 | 0 | 下位机值变化时推送 | LowFreqWindow |
| 静态变量 | 0 | 1 | 需上位机主动请求 | StaticVarsPanel |

---

## 5. Demo 测试模式

### 5.1 功能概述
Demo 模式是一种**离线调试**机制，无需连接真实串口即可模拟下位机数据，用于快速验证上位机 UI 各面板（示波器、变量监控、静态变量、调试控制台）是否正常工作。

### 5.2 数据来源
- `DeviceController._demoTimer` 以 **50Hz** 周期生成模拟数据
- 高频变量：正弦波、余弦波、锯齿波（推入 `highFreqStream`）
- 低频变量：循环计数器、模拟温度（每 25 个 tick 更新一次，触发 `notifyListeners`）
- 静态变量：固定值 `version`（0x00010203）、`threshold`（3.14159）
- 日志：每 100 个 tick 输出一条 `LogType.info` 日志

### 5.3 UI 入口
- **位置**：`MainWindow` 顶部工具栏，位于 `SerialTrafficMonitor` 右侧
- **状态指示**：
  - 未启动：灰色 `bug_report` 图标 + "Demo" 文字
  - 运行中：橙色 `stop_circle` 图标 + "Demo中" 文字
- **操作**：点击切换启动/停止；停止时自动清空 `registry` 中所有模拟变量

### 5.4 实现要点
- `toggleDemoMode()` 控制启停，内部通过 `_startDemoData()` / `_stopDemoData()` 管理
- Demo 变量直接写入 `registry`，复用与真实设备完全一致的数据通路
- `dispose()` 中自动取消 `_demoTimer`，防止内存泄漏

---

## 6. 姿态指示器模块

### 6.1 功能概述
姿态指示器是一个 3D 可视化窗口，用于实时显示飞行器的 Roll/Pitch/Yaw 姿态角度。该窗口以模态对话框形式弹出，大小为 720×560。

### 6.2 数据来源
- 订阅 `DeviceController.highFreqStream`，监听变量名为 `pitch`、`roll`、`yaw` 的高频变量
- 自动从 `registry` 中解析变量 ID，支持动态注册
- 数据单位可切换：角度（°）或弧度（rad）

### 6.3 支持的模型
- **无人机（Drone）**：带有机臂、电机、螺旋桨的 4 轴无人机模型
- **小车（Car）**：带有底盘、车轮的小车模型

### 6.4 渲染模式
- **线框模式**：仅绘制边缘线条
- **实体模式**：绘制填充面，包含简单的光照计算和背面剔除

### 6.5 相机控制
- 支持鼠标拖拽调整视角（水平拖拽调整 Yaw，垂直拖拽调整 Pitch）
- Pitch 范围限制在 [-80°, 11°] 以防止翻转

### 6.6 UI 入口
- `showAttitudeWindow(BuildContext)` 函数以对话框形式展示窗口

---

## 6. 模块目录结构（模块化后）

```
lib/
├── main.dart                     # 入口
├── app.dart                      # Provider 注入 + MaterialApp
├── debug_protocol.dart           # 通信协议帧封装/常量
├── ring_buffer.dart              # 环形缓冲区工具
├── device_control.dart           # Barrel 文件：重新导出 models + services
├── debug_console.dart            # 调试控制台 UI
├── lowfreq_window.dart           # 低频变量监控 UI
├── core/
│   ├── models/
│   │   ├── log_entry.dart
│   │   └── registered_var.dart
│   └── services/
│       └── device_controller.dart
└── ui/
    ├── main_window.dart
    ├── widgets/
    │   ├── connection_status_chips.dart
    │   ├── handshake_button.dart
    │   └── serial_traffic_monitor.dart
    ├── dashboard/
    │   ├── bottom_tabbed_panel.dart
    │   ├── layout_dashboard.dart
    │   ├── scope_dashboard.dart
    │   └── static_vars_panel.dart
    └── scope/
        ├── channel_value_tile.dart
        ├── interactive_scope.dart
        └── pro_scope_painter.dart
    └── attitude/
        ├── attitude_indicator.dart
        └── attitude_window.dart
```
