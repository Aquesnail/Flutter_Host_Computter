Flowave 是一款面向嵌入式调试的跨平台工具套件，提供**上位机 GUI / 命令行 / 下位机固件库**三位一体的实时变量监控与交互方案。

### ✨ 核心特性
- **上位机 GUI**：基于 Flutter，集成**多通道示波器、变量监控面板、静态参数配置、调试控制台、3D 姿态指示器**，支持分屏 / 拖拽排序 / 通道数值实时显示。
- **命令行 + 守护进程**：`flowaved` 后台持有串口连接，`flowave` 通过 HTTP / SSE 接口远程交互，适合自动化、AI Agent 和多终端协作。
- **多类型变量支持**：uint8 / int8 / uint16 / int16 / uint32 / int32 / float，兼容高频、低频、静态三种刷新策略。
- **Demo 测试模式**：无需硬件即可模拟数据源，快速验证 UI 和流程。
- **HTTP REST & SSE API**：标准 JSON 接口，支持 Ping、连接、变量注册/写入、静态变量导入导出、监控流、统计与 ASCII 波形图。
- **下位机即插即用**：提供适用于 STC32G 的 C 库 `debug_arch`，只需简单注册变量即可通过串口实时上传数据、接收命令，并支持日志、文本传输和 CRC 校验。

### 📦 构成
```
flowave/
├── Flutter 上位机          → 可视化调试与监控
├── flowaved (守护进程)     → 持久串口连接 + HTTP API
├── flowave  (CLI)          → 命令行远程控制
└── debug_arch (C 库)       → 下位机协议实现，支 FreeRTOS
```

### 🚀 快速开始
```bash
# 启动守护进程并连接串口
flowaved --port COM3

# 注册变量、开启 Demo、统计数据
flowave demo start
flowave register 0x20001000 voltage 6 --highfreq
flowave stats 1 --duration 5
```

适用于嵌入式开发中参数调优、实时波形捕获、远程日志监控和批量设备配置等场景。完整文档见源码内各 Markdown 文件。