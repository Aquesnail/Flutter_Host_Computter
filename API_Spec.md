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
  dynamic value;

  RegisteredVar(
    this.id,
    this.name,
    this.type,
    this.addr, {
    this.value = 0,
    this.isHighFreq = false,
    this.isStatic = false,
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
| `maskType` | `static const int maskType = 0x0F` | 类型掩码（低4位） |
| `calcCrc` | `static int calcCrc(List<int> data)` | CRC16-MODBUS 计算 |
| `packHandshake` | `static Uint8List packHandshake()` | 构建握手帧 (CMD=0x00) |
| `packWriteCmd` | `static Uint8List packWriteCmd(int varId, int varLen, dynamic value, int varTypeInt)` | 修改变量帧 (CMD=0x55) |
| `packRegisterCmd` | `static Uint8List packRegisterCmd(int address, String name, int varType, {bool isHighFreq = false, bool isStatic = false})` | 动态注册帧 (CMD=0x56) |
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
| `dispose` | `@override void dispose()` | 关闭 `logStream` 并调用父类 dispose |

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
- 职责：顶部工具栏（串口选择、连接、握手、状态面板）。

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
  });
}
```
- 说明：支持鼠标滚轮缩放（X/Y 轴区分）、拖拽平移、双击添加游标、自动右边缘锁定。

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
  });
}
```
- 说明：自定义绘制网格、波形、游标、坐标轴刻度与标签。仅绘制可见索引范围内的点以优化性能。

#### `ChannelValueTile` (`ui/scope/channel_value_tile.dart`)
```dart
class ChannelValueTile extends StatefulWidget {
  const ChannelValueTile({
    super.key,
    required int varId,
    required String name,
    required Color color,
  });
}
```
- 说明：以 100ms 周期轮询 `registry[varId]?.value`，仅在数值变化时触发局部 `setState`。

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

## 6.  barrel 文件说明

### `device_control.dart`（根目录）
```dart
export 'core/models/log_entry.dart';
export 'core/models/registered_var.dart';
export 'core/services/device_controller.dart';
```
- 说明：保持原有 `import 'device_control.dart'` 的兼容性，使其仍能一次性引入 `DeviceController`、`LogEntry`、`LogType`、`RegisteredVar`。
