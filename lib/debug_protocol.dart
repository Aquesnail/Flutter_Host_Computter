import 'dart:convert';
import 'dart:typed_data';

/// 变量类型定义 (对应 Python 中的 0-6)
enum VariableType { 
  uint8, int8, uint16, int16, uint32, int32, float ;
  String get displayName => name;
  }

class DebugProtocol {
  static const int maskFreq = 0x10; // 第4位 (0001 0000) - 高频标志
  static const int maskStatic = 0x20; // 第5位 (0010 0000) - 静态变量标志
  static const int maskPeri = 0x40; // 第6位 (0100 0000) - 外设变量标志
  static const int maskType = 0x0F; // 低4位 (0000 1111) 用于原始类型

  // ── ID 空间分区 ──
  // 0x0000 ~ 0x00FF: 协议控制帧 (256 slots, 将来新增包类型只用这个区间)
  // 0x0100 ~ 0xFFFF: 变量 ID (65280 slots)
  static const int protoReservedMax = 0x00FF; // 协议保留区间上界
  static const int varIdBase         = 0x0100; // 变量 ID 起始值

  // ── 语义分类常量 ──
  static const int catAdcErr    = 0x00;
  static const int catOuterLoop = 0x01;
  static const int catInnerPI   = 0x02;
  static const int catSpeedOut  = 0x03;
  static const int catFuzzyPID  = 0x04;
  static const int catElement   = 0x05;
  static const int catSystem    = 0x06;
  static const int catObserve   = 0x07;
  static const int catMotorPeri = 0x08;

  // ── 元素类型常量 ──
  static const int elemGlobal   = 0x00;
  static const int elemStraight = 0x01;
  static const int elemCross    = 0x02;
  static const int elemRing     = 0x03;
  static const int elemWall     = 0x04;

  // --- CRC16-MODBUS ---
  static int calcCrc(List<int> data) {
    int crc = 0xFFFF;
    for (int pos in data) {
      crc ^= (pos & 0xFF);
      for (int i = 0; i < 8; i++) {
        if ((crc & 1) != 0) {
          crc >>= 1;
          crc ^= 0xA001;
        } else {
          crc >>= 1;
        }
      }
    }
    return crc & 0xFFFF;
  }

  static Uint8List _finalizeFrame(int cmd, List<int> innerPayload) {
    final builder = BytesBuilder();
    List<int> protoPayload = [];
    protoPayload.add(cmd);
    protoPayload.add(innerPayload.length);
    protoPayload.addAll(innerPayload);
    int crc = calcCrc(protoPayload);
    builder.addByte(0x55);
    builder.add(protoPayload);
    builder.addByte((crc >> 8) & 0xFF);
    builder.addByte(crc & 0xFF);
    return builder.toBytes();
  }

  // --- 1. 构建修改变量指令 ---
  static Uint8List packWriteCmd(int varId, int varLen, dynamic value, int varTypeInt) {
    // varTypeInt 传入时应该是纯类型 (0-6)，不需要包含频率位
    final inner = BytesBuilder();
    // ID 2 字节大端序（协议 v2）
    inner.addByte((varId >> 8) & 0xFF);
    inner.addByte(varId & 0xFF);
    inner.addByte(varLen);
    final bData = ByteData(4);
    
    if (varLen == 1) {
      inner.addByte(value & 0xFF);
    } else if (varLen == 2) {
      if (varTypeInt == 3) {
        // int16
         bData.setInt16(0, value, Endian.big);
      } else {
        bData.setUint16(0, value, Endian.big);
      }
      inner.add(bData.buffer.asUint8List(0, 2));
    } else if (varLen == 4) {
      if (varTypeInt == 6) {
        // Float
        bData.setFloat32(0, value.toDouble(), Endian.big);
      } else if (varTypeInt == 5) // Int32
        bData.setInt32(0, value, Endian.big);
      else 
        bData.setUint32(0, value, Endian.big);
      inner.add(bData.buffer.asUint8List(0, 4));
    }
    return _finalizeFrame(0x5A, inner.takeBytes());
  }

  // --- 2. 构建动态注册指令 (CMD 0x56) ---
  // v3: payload 从 15 字节扩展为 23 字节，新增 category 和 element 字段，name 从 10 扩展到 16 字节
  static Uint8List packRegisterCmd(int address, String name, int varType,
      {bool isHighFreq = false, bool isStatic = false, bool isPeri = false,
       int category = 0xFF, int element = 0x00}) {
    final inner = BytesBuilder();

    // 组合 Type、Freq 标志、Static 标志和 Peri 标志
    int typeByte = (varType & maskType);
    if (isHighFreq) {
      typeByte |= maskFreq; // 置位第4位
    }
    if (isStatic) {
      typeByte |= maskStatic; // 置位第5位
    }
    if (isPeri) {
      typeByte |= maskPeri; // 置位第6位
    }
    inner.addByte(typeByte);

    // 地址 4 字节 (Big Endian)
    inner.addByte((address >> 24) & 0xFF);
    inner.addByte((address >> 16) & 0xFF);
    inner.addByte((address >> 8) & 0xFF);
    inner.addByte(address & 0xFF);

    // 语义分类 (v3 新增)
    inner.addByte(category);
    // 元素类型 (v3 新增)
    inner.addByte(element);

    // 名字补齐 (v3: 10→16 字节)
    List<int> nameBytes = ascii.encode(name);
    if (nameBytes.length > 16) nameBytes = nameBytes.sublist(0, 16);
    inner.add(nameBytes);
    for (int i = 0; i < 16 - nameBytes.length; i++) {
      inner.addByte(0);
    }

    return _finalizeFrame(0x56, inner.takeBytes());
  }

  static Uint8List packTextCmd(String text) {
    List<int> textBytes = ascii.encode(text);
    if (textBytes.length > 60) textBytes = textBytes.sublist(0, 60);
    return _finalizeFrame(0x57, textBytes);
  }

  static Uint8List packHandshake() {
    return _finalizeFrame(0x00, [0xDE, 0xAD, 0xBE, 0xEF]);
  }

  // --- 3. 构建请求刷新静态变量指令 (CMD 0x58) ---
  // 上位机发送此指令请求下位机发送指定静态变量的当前值
  static Uint8List packStaticRefreshCmd(int varId) {
    // ID 2 字节大端序（协议 v2）
    return _finalizeFrame(0x58, [(varId >> 8) & 0xFF, varId & 0xFF]);
  }
}