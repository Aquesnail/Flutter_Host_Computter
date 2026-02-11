import 'dart:convert';
import 'dart:typed_data';

/// 变量类型定义 (对应 Python 中的 0-6)
enum VariableType { 
  uint8, int8, uint16, int16, uint32, int32, float ;
  String get displayName => name;
  }

class DebugProtocol {
  static const int maskFreq = 0x10; // 第4位 (0001 0000)
  static const int maskType = 0x0F; // 低4位 (0000 1111) 用于原始类型

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
    inner.addByte(varId);
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
    return _finalizeFrame(0x55, inner.takeBytes());
  }

  // --- 2. 构建动态注册指令 (CMD 0x56) ---
  // 【修改点】移除 memType，地址改为 4 字节，增加 isHighFreq
  static Uint8List packRegisterCmd(int address, String name, int varType, {bool isHighFreq = false}) {
    final inner = BytesBuilder();
    
    // 组合 Type 和 Freq 标志
    int typeByte = (varType & maskType);
    if (isHighFreq) {
      typeByte |= maskFreq; // 置位第4位
    }
    inner.addByte(typeByte);

    // 地址 4 字节 (Big Endian)
    inner.addByte((address >> 24) & 0xFF);
    inner.addByte((address >> 16) & 0xFF);
    inner.addByte((address >> 8) & 0xFF);
    inner.addByte(address & 0xFF);

    // 名字补齐
    List<int> nameBytes = ascii.encode(name);
    if (nameBytes.length > 10) nameBytes = nameBytes.sublist(0, 10);
    inner.add(nameBytes);
    for (int i = 0; i < 10 - nameBytes.length; i++) {
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
}