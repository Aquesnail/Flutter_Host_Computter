# Debug 协议文档

基于 `lib/debug_protocol.dart` 实现的调试协议，用于与目标设备通信。

## 协议概览

协议使用二进制帧格式，包含帧头、命令、载荷长度、数据和CRC校验。

### 基本帧格式

每个帧的结构如下：

| 字节位置 | 长度 | 描述 |
|---------|------|------|
| 0 | 1 | 帧起始符：0x55 |
| 1 | 1 | 命令字 (CMD) |
| 2 | 1 | 内部载荷长度 (N) |
| 3 ~ 3+N-1 | N | 内部载荷数据 |
| 3+N ~ 3+N+1 | 2 | CRC16-MODBUS校验 (高位在前) |

### CRC16-MODBUS计算

CRC16-MODBUS算法用于帧校验，计算范围包括命令字、载荷长度和内部载荷（不包括帧起始符0x55和CRC本身）。

## 变量类型定义

对应Python中的0-6，定义在`VariableType`枚举中：

| 类型值 | 枚举值 | 描述 | 字节长度 |
|--------|--------|------|----------|
| 0 | uint8 | 无符号8位整数 | 1 |
| 1 | int8 | 有符号8位整数 | 1 |
| 2 | uint16 | 无符号16位整数 | 2 |
| 3 | int16 | 有符号16位整数 | 2 |
| 4 | uint32 | 无符号32位整数 | 4 |
| 5 | int32 | 有符号32位整数 | 4 |
| 6 | float | 32位浮点数 | 4 |

## 命令详解

### 1. 握手命令 (CMD: 0x00)

用于建立连接确认。

**请求帧格式：**
- 命令字：0x00
- 内部载荷：[0xDE, 0xAD, 0xBE, 0xEF] (固定)

**使用方式：**
```dart
Uint8List frame = DebugProtocol.packHandshake();
```

### 2. 修改变量命令 (CMD: 0x55)

用于修改目标设备上的变量值。

**请求帧格式：**
- 命令字：0x55
- 内部载荷：
  - 字节0：变量ID
  - 字节1：变量长度 (1, 2 或 4)
  - 字节2~：变量值 (根据类型编码)

**参数说明：**
- `varId`: 变量标识符 (0-255)
- `varLen`: 变量字节长度 (1, 2, 4)
- `value`: 变量值 (根据类型自动转换)
- `varTypeInt`: 变量类型值 (0-6，对应VariableType枚举)

**编码规则：**
- 1字节数据：直接写入
- 2字节数据：使用大端序
  - int16 (类型3): `setInt16`
  - 其他: `setUint16`
- 4字节数据：使用大端序
  - float (类型6): `setFloat32`
  - int32 (类型5): `setInt32`
  - 其他: `setUint32`

**使用方式：**
```dart
// 修改一个uint8变量
Uint8List frame = DebugProtocol.packWriteCmd(1, 1, 100, 0);

// 修改一个int16变量
Uint8List frame = DebugProtocol.packWriteCmd(2, 2, -1500, 3);

// 修改一个float变量
Uint8List frame = DebugProtocol.packWriteCmd(3, 4, 3.14, 6);
```

### 3. 动态注册命令 (CMD: 0x56)

用于向设备注册一个新的变量，使其可被监控。

**请求帧格式：**
- 命令字：0x56
- 内部载荷：
  - 字节0：类型字节 (低4位=类型，第4位=高频标志)
  - 字节1-4：地址 (4字节大端序)
  - 字节5-14：变量名 (ASCII，最多10字节，不足补0)

**类型字节编码：**
- 低4位 (maskType=0x0F): 变量类型值 (0-6)
- 第4位 (maskFreq=0x10): 高频刷新标志 (1=高频，0=低频)

**参数说明：**
- `address`: 变量内存地址 (32位)
- `name`: 变量名称 (ASCII字符串，最长10字符)
- `varType`: 变量类型值 (0-6)
- `isHighFreq`: 是否为高频变量 (默认false)

**使用方式：**
```dart
// 注册一个低频uint16变量
Uint8List frame = DebugProtocol.packRegisterCmd(0x20001000, "speed", 2);

// 注册一个高频float变量
Uint8List frame = DebugProtocol.packRegisterCmd(0x20002000, "voltage", 6, isHighFreq: true);
```

### 4. 文本命令 (CMD: 0x57)

用于发送文本信息到设备。

**请求帧格式：**
- 命令字：0x57
- 内部载荷：文本数据 (ASCII编码，最多60字节)

**使用方式：**
```dart
Uint8List frame = DebugProtocol.packTextCmd("Hello Device!");
```

## 协议常量

| 常量名 | 值 | 描述 |
|--------|-----|------|
| maskFreq | 0x10 (0001 0000) | 高频标志掩码 (第4位) |
| maskType | 0x0F (0000 1111) | 类型掩码 (低4位) |

## 使用示例

```dart
import 'debug_protocol.dart';

// 1. 握手
Uint8List handshakeFrame = DebugProtocol.packHandshake();

// 2. 注册变量
Uint8List registerFrame = DebugProtocol.packRegisterCmd(
  0x20001000, 
  "motor_speed", 
  2,  // uint16
  isHighFreq: true
);

// 3. 修改变量值
Uint8List writeFrame = DebugProtocol.packWriteCmd(1, 2, 1500, 2); // uint16=1500

// 4. 发送文本
Uint8List textFrame = DebugProtocol.packTextCmd("System ready");
```

## 注意事项

1. 所有多字节数据都使用**大端序** (Big Endian)
2. 变量名称使用ASCII编码，超出10字符会被截断
3. 文本命令最大长度为60字节
4. CRC校验采用MODBUS算法
5. 高频变量标志用于优化数据传输频率

## 版本历史

- 动态注册命令 (0x56) 已移除memType参数，地址扩展为4字节
- 类型字节现在包含高频刷新标志位