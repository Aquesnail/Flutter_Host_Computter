# Flowave CLI 文档

Flowave 是配套 Flutter 上位机应用的命令行工具，用于串口设备调试、变量操作和实时监控。

---

## 设计原则

1. **一次性命令**：除 `monitor` 外，所有命令执行完成后立即退出
2. **握手等待**：执行 `handshake` 时只处理握手响应 (VID=0xFD)，忽略其他数据包
3. **每次独立**：每个命令创建新的 DeviceCore 实例，连接后执行操作然后退出

---

## 快速开始

```bash
# 列出可用串口
flowave list-ports

# 连接设备
flowave connect --port COM3

# 握手
flowave handshake
```

---

## 命令参考

### 1. 连接管理

| 命令 | 说明 |
|------|------|
| `flowave list-ports` | 列出系统可用串口 |
| `flowave connect --port <name> [--baud <rate>]` | 连接串口（默认波特率 115200） |
| `flowave disconnect` | 断开连接 |
| `flowave handshake` | 与设备握手 |

### 2. 变量操作

| 命令 | 说明 |
|------|------|
| `flowave register <addr> <name> <type> [--highfreq] [--static]` | 注册变量 |
| `flowave write <varId> <value> <type>` | 修改变量值 |
| `flowave refresh <varId>` | 刷新静态变量 |
| `flowave refresh-all` | 刷新所有静态变量 |
| `flowave list-vars` | 列出已注册变量 |
| `flowave save-static <path>` | 导出静态变量到 JSON |
| `flowave load-static <path>` | 从 JSON 导入静态变量 |
| `flowave write-all-static` | 批量写入所有静态变量到设备 |
| `flowave text <message>` | 发送文本消息到设备 |

**类型值 (type)**:
- `0`: uint8
- `1`: int8
- `2`: uint16
- `3`: int16
- `4`: uint32
- `5`: int32
- `6`: float

**地址格式**: 十六进制，如 `0x20001000`

**示例**:
```bash
# 注册高频变量
flowave register 0x20001000 voltage 6 --highfreq

# 注册静态变量
flowave register 0x20003000 threshold 6 --static

# 修改变量
flowave write 1 3.14159 6

# 刷新静态变量
flowave refresh 1

# 导出静态配置
flowave save-static config.json

# 发送文本
flowave text "Hello Device!"
```

### 3. 监控

| 命令 | 说明 |
|------|------|
| `flowave monitor [--highfreq] [--log] [--timeout <sec>]` | 实时监控数据流 |

**示例**:
```bash
# 监控高频数据 10 秒
flowave monitor --highfreq --timeout 10

# 监控日志
flowave monitor --log

# 同时监控高频和日志
flowave monitor --highfreq --log
```

### 4. 统计分析

| 命令 | 说明 |
|------|------|
| `flowave stats <varId> [--window N] [--duration N]` | 计算统计信息 |
| `flowave plot <varId> [--width N]` | 绘制 ASCII 波形 |

**示例**:
```bash
# 收集 4 秒数据，计算统计
flowave stats 1

# 自定义窗口和时长
flowave stats 1 --window 200 --duration 10

# 绘制波形
flowave plot 1
```

**输出示例 (stats)**:
```json
{"status":"ok","varId":1,"count":200,"min":-99.5,"max":99.8,"mean":0.3,"std":57.2,"trend":0.01}
```

---

## 变量类型说明

| 类型值 | 说明 | 字节长度 |
|--------|------|---------|
| 0 | uint8 | 1 |
| 1 | int8 | 1 |
| 2 | uint16 | 2 |
| 3 | int16 | 2 |
| 4 | uint32 | 4 |
| 5 | int32 | 4 |
| 6 | float | 4 |

---

## JSON 输出格式

所有命令输出单行 JSON，便于脚本解析。

**成功**:
```json
{"status":"ok","varId":1}
```

**错误**:
```json
{"status":"error","message":"Invalid varId"}
```

**监控流**:
```json
{"type":"highfreq","varId":1,"value":3.14,"timestamp":"2026-05-04T12:00:00.000Z"}
{"type":"log","content":"[INFO] Hello","logType":"info","timestamp":"2026-05-04T12:00:00.000Z"}
```

---

## 编译

```bash
dart compile exe bin/flowave.dart -o build/flowave.exe
```

或使用 Flutter:
```bash
flutter build windows
```