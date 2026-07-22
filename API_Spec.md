# API Spec

本文档记录项目中所有公共接口的定义，包括数据模型、协议方法、状态管理器 API 以及主要 UI 组件签名。

---

## 1. 数据模型 (`core/models/`)

### `RegisteredVar`
```dart
class RegisteredVar {
  final int id;
  final String name;
  final int type;      // 纯类型 0-6
  final int addr;
  final bool isHighFreq;
  final bool isStatic;
  final bool isPeri;   // 是否外设变量
  dynamic value;

  RegisteredVar(
    this.id,
    this.name,
    this.type,
    this.addr, {
    this.value = 0,
    this.isHighFreq = false,
    this.isStatic = false,
    this.isPeri = false,
  });
}
```

### `LogType`
```dart
enum LogType { rx, tx, info, error }
```

### `LogEntry`
```dart
class LogEntry {
  final DateTime timestamp;
  final LogType type;
  final String content;

  LogEntry(this.type, this.content);

  String get timeStr; // 格式: HH:MM:SS.mmm
}
```

---

## 2. 通信协议 (`debug_protocol.dart`)

### `VariableType`
```dart
enum VariableType { uint8, int8, uint16, int16, uint32, int32, float }
```

### `DebugProtocol`

| 静态成员 | 签名 | 说明 |
|----------|------|------|
| `maskFreq` | `static const int maskFreq = 0x10` | 高频标志位 |
| `maskStatic` | `static const int maskStatic = 0x20` | 静态变量标志位 |
| `maskPeri` | `static const int maskPeri = 0x40` | 外设变量标志位 |
| `maskType` | `static const int maskType = 0x0F` | 类型掩码（低4位） |
| `calcCrc` | `static int calcCrc(List<int> data)` | CRC16-MODBUS 计算 |
| `packHandshake` | `static Uint8List packHandshake()` | 构建握手帧 (CMD=0x00) |
| `packWriteCmd` | `static Uint8List packWriteCmd(int varId, int varLen, dynamic value, int varTypeInt)` | 修改变量帧 (CMD=0x5A) |
| `packRegisterCmd` | `static Uint8List packRegisterCmd(int address, String name, int varType, {bool isHighFreq = false, bool isStatic = false, bool isPeri = false})` | 动态注册帧 (CMD=0x56) |
| `packTextCmd` | `static Uint8List packTextCmd(String text)` | 文本发送帧 (CMD=0x57) |
| `packStaticRefreshCmd` | `static Uint8List packStaticRefreshCmd(int varId)` | 请求刷新静态变量 (CMD=0x58) |

---

## 3. 状态管理器 (`core/services/device_controller.dart`)

### `DeviceController extends ChangeNotifier`

#### 状态字段
| 字段 | 类型 | 说明 |
|------|------|------|
| `isConnected` | `bool` | 串口是否已连接 |
| `shakeHandSuccessful` | `bool` | 握手是否成功 |
| `selectedPort` | `String?` | 当前选中的串口名称（setter 会 notify） |
| `selectedBaudRate` | `int` | 当前波特率（setter 会 notify） |
| `availablePorts` | `List<String>` | 系统可用串口列表 |
| `totalRxBytes` | `int` | 累计接收字节数（用于流量统计） |
| `registry` | `Map<int, RegisteredVar>` | 已注册变量字典（按插入/排序顺序保留） |
| `combinedHistory` | `List<LogEntry>` | 合并并按时间排序的历史日志 |
| `demoModeActive` | `bool` | Demo 测试模式是否正在运行 |

#### Stream
| 名称 | 类型 | 说明 |
|------|------|------|
| `highFreqStream` | `Stream<MapEntry<int, double>>` | 高频数据实时流 |
| `logStream` | `Stream<LogEntry>` | 日志实时流 |

#### 公共方法
| 方法 | 签名 | 说明 |
|------|------|------|
| `refreshPorts` | `void refreshPorts()` | 刷新可用串口列表 |
| `connectWithInternal` | `Future<bool> connectWithInternal()` | 使用内部保存的端口/波特率连接 |
| `connect` | `Future<bool> connect(String portName, int baudRate)` | 打开指定串口并启动 Reader |
| `disconnect` | `void disconnect()` | 关闭串口并重置连接状态 |
| `shakeWithMCU` | `Future<bool> shakeWithMCU()` | 发送握手帧并等待 2 秒超时 |
| `sendData` | `void sendData(Uint8List data)` | 向串口写入原始数据并记录 TX 日志 |
| `reorderRegistry` | `void reorderRegistry(int oldIndex, int newIndex)` | 调整 `registry` 中变量的显示顺序 |
| `reorderNonStaticVars` | `void reorderNonStaticVars(int oldIndex, int newIndex)` | 仅调整非静态变量的显示顺序（用于 LowFreqWindow） |
| `clearRegistry` | `void clearRegistry()` | 清空所有已注册的变量元数据 |
| `requestStaticRefresh` | `void requestStaticRefresh(int varId)` | 发送指定静态变量的刷新请求 |
| `toggleDemoMode` | `void toggleDemoMode()` | 切换 Demo 测试模式：启动时自动注册模拟变量并生成 50Hz 数据流，停止时清空变量 |
| `saveStaticVarsToJson` | `Future<String> saveStaticVarsToJson(String path)` | 导出所有静态变量到 JSON 文件 |
| `loadStaticVarsFromJson` | `Future<int> loadStaticVarsFromJson(String path)` | 从 JSON 文件导入静态变量，返回加载数量 |
| `writeAllStaticVarsToDevice` | `Future<void> writeAllStaticVarsToDevice()` | 批量发送所有静态变量到下位机（每条间隔 20ms） |
| `setAutoSavePath` | `void setAutoSavePath(String path)` | 设置自动保存路径 |
| `triggerAutoSave` | `Future<void> triggerAutoSave()` | 触发自动保存（带 500ms 防抖） |
| `dispose` | `@override void dispose()` | 关闭 `logStream` 并调用父类 dispose |

### `DeviceCore` (纯 Dart 业务核心)

`DeviceCore` 是 `DeviceController` 的底层实现，包含所有实际的状态字段、Stream 和业务方法。`DeviceController` 不重复定义这些成员，而是通过 **代理模式（proxy/getter）** 将全部调用委托给内部的 `_core` 实例，同时通过 `onChanged` 回调桥接 `ChangeNotifier.notifyListeners()`。

这在文档中表现为两者的接口高度相似，但在代码层面并无重复——`DeviceController` 是纯粹的 Flutter 绑定层，与 `DeviceCore`（纯 Dart）分离以支持 CLI 和守护进程复用。

| 差异点 | DeviceController | DeviceCore |
|--------|-----------------|------------|
| 基类 | `ChangeNotifier` | 无 |
| 状态字段 | 通过 getter 代理到 `_core` | 实际持有字段 |
| 公共方法 | 通过方法代理到 `_core` | 实际实现 |
| Stream | 通过 getter 代理到 `_core` | 实际持有 `StreamController` |
| UI 通知 | `notifyListeners()` | `onChanged` 回调 |
| 使用场景 | Flutter GUI | CLI 守护进程 (`flowaved`) |

---

## 4. 工具类 (`ring_buffer.dart`)

### `RingBuffer`
```dart
class RingBuffer {
  RingBuffer(int capacity);

  int get capacity;
  int get length;

  void add(double value);
  void clear();
  double operator [](int index);
  void resize(int newCapacity);
}
```

---

## 5. UI 组件接口

### 5.1 顶层页面

#### `MyApp` (`app.dart`)
```dart
class MyApp extends StatelessWidget
```
- 职责：注入 `ChangeNotifierProvider<DeviceController>` 并挂载 `MaterialApp`。

#### `MainWindow` (`ui/main_window.dart`)
```dart
class MainWindow extends StatelessWidget
```
- 职责：顶部工具栏（串口选择、连接、握手、状态面板、Demo 测试数据按钮）。

#### `LayoutDashboard` (`ui/dashboard/layout_dashboard.dart`)
```dart
class LayoutDashboard extends StatefulWidget
```
- 职责：使用 `multi_split_view` 管理上下/左右分屏布局。

#### `BottomTabbedPanel` (`ui/dashboard/bottom_tabbed_panel.dart`)
```dart
class BottomTabbedPanel extends StatelessWidget
```
- 职责：底部标签栏容器，包含 `LowFreqWindow` 与 `DebugConsole` 两个 Tab。

---

### 5.2 工具栏子组件

#### `HandshakeButton` (`ui/widgets/handshake_button.dart`)
```dart
class HandshakeButton extends StatelessWidget
```
- 说明：仅在 `isConnected == true` 时可点击，点击后调用 `shakeWithMCU` 并显示结果 SnackBar。

#### `ConnectionStatusChips` (`ui/widgets/connection_status_chips.dart`)
```dart
class ConnectionStatusChips extends StatelessWidget
```
- 说明：使用 `context.select` 监听 `isConnected` 与 `shakeHandSuccessful`，动态渲染状态 Chip。

#### `SerialTrafficMonitor` (`ui/widgets/serial_traffic_monitor.dart`)
```dart
class SerialTrafficMonitor extends StatefulWidget
```
- 说明：每 100ms 采样一次 `totalRxBytes`，计算 RX 负载百分比与速率并显示。

---

### 5.3 示波器相关 (`ui/dashboard/scope_dashboard.dart` + `ui/scope/`)

#### `ValueDisplayFormat` (`ui/scope/value_display_format.dart`)
```dart
enum ValueDisplayFormat { normal, scientific }

String formatValue(double value, ValueDisplayFormat format);
```
- `normal`: `toStringAsFixed(2)` — 保留两位小数，如 `3.14`
- `scientific`: `toStringAsExponential(3)` — 保留三位小数的科学计数法，如 `1.235e+02`

`IntDisplayFormat` — 整数显示格式
```dart
enum IntDisplayFormat { decimal, hex, binary }

String formatIntValue(double value, IntDisplayFormat format);
```
- `decimal`: 十进制整数，如 `255`
- `hex`: 十六进制（`0x` 前缀，大写），如 `0xFF`
- `binary`: 二进制（`0b` 前缀），如 `0b11111111`

#### `ScopeDashboard` (`ui/dashboard/scope_dashboard.dart`)
```dart
class ScopeDashboard extends StatefulWidget
```
- 状态：
  - `Map<int, RingBuffer> multiChannelBuffers`
  - `int _bufferSize` (默认 2000)
  - `double _deltaTime` (默认 20.0)
- 说明：订阅 `highFreqStream` 写数据到 RingBuffer，同时使用 16ms 定时器触发 `setState` 刷新视图。

#### `InteractiveScope` (`ui/scope/interactive_scope.dart`)
```dart
class InteractiveScope extends StatefulWidget {
  const InteractiveScope({
    super.key,
    required Map<int, RingBuffer> dataPoints,
    required List<int> varIds,
    required List<Color> colors,
    double deltaTime = 1.0,
    Map<int, ValueDisplayFormat> displayFormats = const {},
  });
}
```
- 工具栏（右上角浮动，半透明深色背景）：
  - **平移模式**（`ScopeTool.pan`，默认）：左键拖拽平移视图，滚轮缩放，双击添加游标，拖拽松手自动吸附右边缘锁定
  - **框选缩放模式**（`ScopeTool.zoomRect`）：左键拖拽绘制矩形选区，松手后自动缩放到该区域（X/Y 同时适配），右键取消当前选区；完成后保持当前模式不切换
  - **自动适配 Y**：扫描全部通道数据，根据最大/最小幅值自动计算 `scaleY` 和 `offsetY`（上下留 10% 边距）
  - **自动适配 X**：根据数据总长度自动计算 `scaleX`，使全部数据可见（关闭自动锁定）
  - **重置视图**：恢复所有变换参数为默认值，清除游标，重新开启右边缘锁定
- 框选矩形 < 5px 时忽略，防止误触造成极端缩放。

#### `ProScopePainter` (`ui/scope/pro_scope_painter.dart`)
```dart
class ProScopePainter extends CustomPainter {
  ProScopePainter({
    required Map<int, RingBuffer> allPoints,
    required List<int> ids,
    required List<Color> colors,
    required double scaleX,
    required double scaleY,
    required double offsetX,
    required double offsetY,
    double? cursorX,
    required double yAxisWidth,
    required double xAxisHeight,
    required double deltaTime,
    Offset? rectStart,
    Offset? rectEnd,
    Map<int, ValueDisplayFormat> displayFormats = const {},
    Map<int, IntDisplayFormat> intDisplayFormats = const {},
  });
}
```
- 说明：自定义绘制网格、波形、游标、坐标轴刻度与标签、矩形选区叠加（蓝色半透明填充 + 白色边框）。仅绘制可见索引范围内的点以优化性能。
- `displayFormats`：各 float 通道的数值显示格式映射。
- `intDisplayFormats`：各整数通道的数值显示格式映射，优先于 `displayFormats`。

#### `ChannelValueTile` (`ui/scope/channel_value_tile.dart`)
```dart
class ChannelValueTile extends StatefulWidget {
  const ChannelValueTile({
    super.key,
    required int varId,
    required String name,
    required Color color,
    bool isVisible = true,
    ValueDisplayFormat displayFormat = ValueDisplayFormat.normal,
    bool isFloat = false,
    required VoidCallback onToggleVisibility,
    VoidCallback? onToggleFormat,
    VoidCallback? onToggleIntFormat,
  });
}
```
- 说明：以 100ms 周期轮询 `registry[varId]?.value`，仅在数值变化时触发局部 `setState`。
- `isVisible`：控制通道波形是否在示波器中显示，`false` 时 tile 半透明。
- `displayFormat`：float 通道的数值显示格式。
- `intDisplayFormat`：整数通道的数值显示格式（decimal / hex / binary）。
- `isFloat`：标记通道类型，为 `true` 时显示浮点格式按钮（`F`/`Sci`），否则显示整数格式按钮（`Dec`/`Hex`/`Bin`）。
- `onToggleVisibility`：点击眼睛图标回调。
- `onToggleFormat`：点击浮点格式标签回调（仅 float 通道）。
- `onToggleIntFormat`：点击整数格式标签回调（仅整数通道）。

---

### 5.4 低频变量监控 (`lowfreq_window.dart`)

#### `LowFreqWindow` (`lowfreq_window.dart`)
```dart
class LowFreqWindow extends StatefulWidget
```
- 说明：展示 `registry` 中**非静态**变量（高频+低频），支持长按拖拽排序、注册弹窗、修改变量值弹窗。修改变量值时，如为静态变量自动请求刷新。

#### `MonitorListTile` (`lowfreq_window.dart`)
```dart
class MonitorListTile extends StatefulWidget {
  const MonitorListTile({
    super.key,
    required int varId,
    required Function(RegisteredVar) onTap,
  });
}
```
- 说明：每个列表项以 200ms 周期轮询对应变量值，显示名称、地址、类型标签和当前值。点击触发修改变量弹窗。

---

### 5.5 静态变量面板 (`ui/dashboard/static_vars_panel.dart`)

#### `StaticVarsPanel`
```dart
class StaticVarsPanel extends StatelessWidget
```
- 说明：展示 `registry` 中所有静态变量，位于右上角面板。顶部横栏包含标题、变量计数和"全部刷新"按钮。

#### `StaticVarTile`
```dart
class StaticVarTile extends StatefulWidget {
  const StaticVarTile({
    super.key,
    required int varId,
  });
}
```
- 说明：静态变量列表项，显示名称、地址、类型和当前值。支持点击修改值和单独刷新。

---

### 5.6 调试控制台 (`debug_console.dart`)

#### `DebugConsole` (`debug_console.dart`)
```dart
class DebugConsole extends StatefulWidget
```
- 状态：
  - `List<LogEntry> _allLogs`（全量日志）
  - `List<LogEntry> _visibleLogs`（经 Hex 过滤后的可见日志）
  - `List<LogEntry> _pendingLogs`（100ms 临时缓冲）
  - `bool _useProtocol`（是否使用协议封装发送）
  - `bool _isHexMode`（裸数据模式下的 ASCII/HEX 切换）
  - `bool _showHex`（日志面板的 RX/TX 显示开关）
  - `bool _autoScroll`
- 说明：订阅 `logStream`，以 100ms 批量写入并刷新 UI。支持日志过滤、自动滚动、 Hex 输入校验、协议/裸数据双模式发送。

---

## 6. 姿态指示器 (`ui/attitude/`)

### 6.1 数据模型

#### `Attitude` (`attitude_indicator.dart`)
```dart
class Attitude {
  final double roll;
  final double pitch;
  final double yaw;

  const Attitude(this.roll, this.pitch, this.yaw);
  const Attitude.zero();

  Attitude copyWith({double? roll, double? pitch, double? yaw});
}
```

### 6.2 绘制器

#### `AttitudePainter` (`attitude_indicator.dart`)
```dart
class AttitudePainter extends CustomPainter {
  AttitudePainter({
    required Attitude attitude,
    required bool isDrone,
    required Color color,
    bool solidMode = false,
    double cameraPitch = -0.45,
    double cameraYaw = -0.55,
  });
}
```
- 说明：根据 roll/pitch/yaw 角度渲染无人机或小车 3D 模型，支持线框/实体两种模式，正弦波投影显示地面参考网格。

### 6.3 主窗口

#### `AttitudeWindowContent` (`attitude_window.dart`)
```dart
class AttitudeWindowContent extends StatefulWidget
```
- 状态：
  - `ValueNotifier<Attitude> _attitude`（当前姿态）
  - `bool _isDrone`（无人机/小车切换）
  - `bool _useDegrees`（角度单位）
  - `bool _solidMode`（线框/实体模式）
  - `double _cameraPitch / _cameraYaw`（相机视角）
- 说明：订阅 `highFreqStream` 监听名为 `pitch`、`roll`、`yaw` 的高频变量，自动解析变量 ID 并实时更新姿态显示。

#### `showAttitudeWindow()` (`attitude_window.dart`)
```dart
void showAttitudeWindow(BuildContext context)
```
- 说明：以对话框形式展示 720×560 姿态指示器窗口。

---

## 7. HTTP API (`core/services/http_api.dart`)

### `HttpApi`

守护进程的 HTTP API 处理器，包装 `DeviceCore` 并暴露 REST + SSE 端点。

```dart
class HttpApi {
  final DeviceCore _core;
  HttpApi(this._core);

  Future<void> handleRequest(HttpRequest request);
  Future<T> _synchronized<T>(Future<T> Function() fn);  // 并发锁
}
```

#### 端点列表

| 端点 | 方法 | 说明 | 并发锁 |
|------|------|------|--------|
| `/ping` | GET | 健康检查，返回 `{"status":"ok","message":"pong"}` | - |
| `/list-ports` | GET | 列出可用串口 | - |
| `/connect` | POST | 连接串口，body: `{"port":"COM3","baud":115200}` | ✓ |
| `/disconnect` | POST | 断开串口 | ✓ |
| `/handshake` | POST | 握手，返回 `{"status":"ok","success":true}` | ✓ |
| `/register` | POST | 注册变量，body: `{"addr":...,"name":...,"type":...,"isHighFreq":false,"isStatic":false,"isPeri":false}` | ✓ |
| `/write` | POST | 修改变量值，body: `{"varId":1,"value":3.14,"type":6}` | ✓ |
| `/refresh` | POST | 请求刷新单个静态变量，body: `{"varId":1}` | ✓ |
| `/refresh-all` | POST | 请求刷新所有静态变量 | ✓ |
| `/list-vars` | GET | 列出所有变量及其当前值 | - |
| `/save-static` | POST | 导出静态变量 JSON，body: `{"path":"config.json"}` | ✓ |
| `/load-static` | POST | 导入静态变量 JSON，body: `{"path":"config.json"}` | ✓ |
| `/write-all-static` | POST | 批量写入所有静态变量到下位机 | ✓ |
| `/text` | POST | 发送文本，body: `{"message":"Hello"}` | ✓ |
| `/monitor/highfreq` | GET | SSE 高频数据流，query: `timeout`（秒） | - |
| `/monitor/logs` | GET | SSE 日志流，query: `timeout`（秒） | - |
| `/stats` | GET | 统计摘要，query: `varId`, `window`, `duration` | - |
| `/plot` | GET | ASCII 波形图，query: `varId`, `width`, `duration` | - |
| `/demo/start` | POST | 启动 Demo 测试模式 | ✓ |
| `/demo/stop` | POST | 停止 Demo 测试模式 | ✓ |
| `/shutdown` | POST | 关闭守护进程 | ✓ |

**并发安全**：标记 ✓ 的端点通过 `_synchronized()` 串行化执行，避免并发修改 `DeviceCore` 状态导致竞态条件。

**SSE 超时机制**：`timeout` 参数由**服务端** `Timer` 实现。当 `timeout > 0` 时，服务端在指定秒数后主动取消 `StreamSubscription` 并关闭 HTTP 响应；客户端无需自行断连。`timeout` 为 0 时连接持续直到客户端断开。

**SSE 多客户端支持**：`highFreqStream` 和 `logStream` 均为广播流（`StreamController.broadcast()`），多个 CLI/GUI 客户端可同时订阅同一 SSE 端点而不会冲突。

**SSE 格式**：
```
data: {"type":"highfreq","varId":1,"value":3.14,"timestamp":"2026-05-04T12:00:00.000Z"}

```

---

## 8. 入口文件

### `flowaved` (`bin/flowaved.dart`) — 守护进程

```dart
void main(List<String> args) async
```
- 职责：解析 `--port` / `--baud` 参数，创建 `DeviceCore` 实例（可选自动连接串口），启动 HTTP 服务器监听 `127.0.0.1:9876`。
- 信号处理：SIGINT 时调用 `core.dispose()` 并关闭服务器。

### `flowave` (`bin/flowave.dart`) — CLI 客户端

```dart
void main(List<String> args)
```
- 职责：解析命令行参数，映射为 HTTP 请求发送到 `http://127.0.0.1:9876`，输出 JSON 响应。
- 依赖：仅 `http` + `args` 包，不依赖 `DeviceCore` 或 Flutter。
- 命令映射：参见 Architecture.md §9.3。

---

## 9. barrel 文件说明

### `device_control.dart`（根目录）
```dart
export 'core/models/log_entry.dart';
export 'core/models/registered_var.dart';
export 'core/services/device_controller.dart';
```
- 说明：保持原有 `import 'device_control.dart'` 的兼容性，使其仍能一次性引入 `DeviceController`、`LogEntry`、`LogType`、`RegisteredVar`。
