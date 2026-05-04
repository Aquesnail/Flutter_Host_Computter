# Flowave CLI 文档

Flowave 是配套 Flutter 上位机应用的命令行工具，用于串口设备调试、变量操作和实时监控。

---

## 架构

```
flowave (CLI 客户端) ──HTTP/JSON──> flowaved (守护进程) ──DeviceCore──> 串口
    纯 Dart                         纯 Dart + FFI
    无状态                           持有连接
    执行后退出                       持久运行
```

- **`flowaved`**：守护进程，持有 `DeviceCore` 实例，通过 HTTP（127.0.0.1:9876）暴露 API。串口连接持久保持。
- **`flowave`**：命令行客户端，将每个 CLI 命令转为 HTTP 请求发往守护进程，输出响应内容。本身无状态，执行完即退出。

多个终端窗口或 AI Agent 可同时共享一个设备连接，无需每次命令都重新连接串口。

---

## 快速开始

```bash
# 终端 1：启动守护进程（可选自动连接串口）
flowaved --port COM3

# 终端 2：运行命令
flowave handshake
flowave demo start
flowave list-vars
```

---

## 命令参考

### 1. 守护进程管理

| 命令 | 说明 |
|------|------|
| `flowave ping` | 检查守护进程连通性 |
| `flowave shutdown` | 关闭守护进程 |

**守护进程启动选项**：

| 选项 | 说明 |
|------|------|
| `flowaved --port <name>` | 启动时连接指定串口 |
| `flowaved --baud <rate>` | 设置波特率（默认 115200） |
| `flowaved -h` | 显示帮助 |

### 2. 连接管理

| 命令 | 说明 |
|------|------|
| `flowave list-ports` | 列出系统可用串口 |
| `flowave connect <port> [--baud <rate>]` | 连接串口（默认波特率 115200） |
| `flowave disconnect` | 断开连接 |
| `flowave handshake` | 与设备握手 |

### 3. 变量操作

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

### 4. 监控

| 命令 | 说明 |
|------|------|
| `flowave monitor [--highfreq] [--log] [--timeout <sec>]` | 实时监控数据流 |

监控流使用 SSE（Server-Sent Events）传输。

**示例**:
```bash
# 监控高频数据 10 秒
flowave monitor --highfreq --timeout 10

# 监控日志
flowave monitor --log

# 同时监控高频和日志
flowave monitor --highfreq --log
```

### 5. 统计分析

| 命令 | 说明 |
|------|------|
| `flowave stats <varId> [--window N] [--duration N]` | 计算统计信息 |
| `flowave plot <varId> [--width N] [--duration N]` | 绘制 ASCII 波形 |

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
{"status":"ok","varId":1,"count":100,"min":-99.5,"max":99.8,"mean":0.3,"std":57.2,"trend":0.01}
```

**输出示例 (plot)**:
```json
{"plot":"|                                        ●●●●●●●●●●●●●●●●●●●●●●●●●|\n|                             ●●●●●●●●●●●                      |\n...","min":-99.9,"max":99.9,"avg":12.3}
```

### 6. Demo 模式

| 命令 | 说明 |
|------|------|
| `flowave demo start` | 启动 Demo 测试模式 |
| `flowave demo stop` | 停止 Demo 测试模式 |

Demo 模式无需真实串口设备，可快速验证所有功能。

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

**监控流** (SSE → 客户端剥离 `data: ` 前缀后输出):
```json
{"type":"highfreq","varId":1,"value":3.14,"timestamp":"2026-05-04T12:00:00.000Z"}
{"type":"log","content":"[INFO] Hello","logType":"info","timestamp":"2026-05-04T12:00:00.000Z"}
```

---

## HTTP API 参考

客户端将 CLI 命令映射为 HTTP 请求。以下是所有端点：

| 端点 | 方法 | 说明 | Body |
|------|------|------|------|
| `/ping` | GET | 健康检查 | - |
| `/list-ports` | GET | 列出可用串口 | - |
| `/connect` | POST | 连接串口 | `{"port":"COM3","baud":115200}` |
| `/disconnect` | POST | 断开串口 | `{}` |
| `/handshake` | POST | 握手 | `{}` |
| `/register` | POST | 注册变量 | `{"addr":...,"name":...,"type":...,"isHighFreq":false,"isStatic":false}` |
| `/write` | POST | 修改变量 | `{"varId":1,"value":3.14,"type":6}` |
| `/refresh` | POST | 刷新单个静态变量 | `{"varId":1}` |
| `/refresh-all` | POST | 刷新全部静态变量 | `{}` |
| `/list-vars` | GET | 列出变量 | - |
| `/save-static` | POST | 导出静态变量 | `{"path":"config.json"}` |
| `/load-static` | POST | 导入静态变量 | `{"path":"config.json"}` |
| `/write-all-static` | POST | 批量写入静态变量 | `{}` |
| `/text` | POST | 发送文本 | `{"message":"Hello"}` |
| `/monitor/highfreq` | GET | SSE 高频数据流 | query: `timeout` |
| `/monitor/logs` | GET | SSE 日志流 | query: `timeout` |
| `/stats` | GET | 统计摘要 | query: `varId`, `window`, `duration` |
| `/plot` | GET | ASCII 波形图 | query: `varId`, `width`, `duration` |
| `/demo/start` | POST | 启动 Demo | `{}` |
| `/demo/stop` | POST | 停止 Demo | `{}` |
| `/shutdown` | POST | 关闭守护进程 | `{}` |

---

## 编译

```bash
# 守护进程（需要 Flutter 项目上下文）
dart compile exe bin/flowaved.dart -o build/flowaved.exe

# CLI 客户端（纯 Dart，无需 Flutter）
dart compile exe bin/flowave.dart -o build/flowave.exe
```

将两个可执行文件放在同一目录（如 `C:\Tools`）并加入环境变量 PATH。
