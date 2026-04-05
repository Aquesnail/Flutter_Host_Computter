import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import '../../debug_protocol.dart';
import '../models/log_entry.dart';
import '../models/registered_var.dart';

class DeviceController extends ChangeNotifier {
  SerialPort? _port;
  SerialPortReader? _reader;
  bool isConnected = false;
  bool shakeHandSuccessful = false;
  final List<String> logs = [];
  final Map<int, RegisteredVar> registry = {};

  Completer<bool>? _handshakeCompleter;
  final _highFreqDataCtrl = StreamController<MapEntry<int, double>>.broadcast();
  final _logCtrl = StreamController<LogEntry>.broadcast();
  Stream<MapEntry<int, double>> get highFreqStream => _highFreqDataCtrl.stream;
  //暴露 Stream 给外部
  Stream<LogEntry> get logStream => _logCtrl.stream;
  // 优化缓冲区：使用指针法，不频繁remove
  final List<int> _rxBuffer = [];
  static const int MAX_BUFFER_SIZE = 1024 * 1024;
  //Log的缓冲，50条
  final List<LogEntry> _sysLogHistory = [];
  static const int _maxSysLogHistory = 200;

  final List<LogEntry> _dataLogHistory = [];
  static const int _maxDataLogHistory = 100;

  String? _selectedPort;
  int _selectedBaudRate = 115200;
  List<String> _availablePorts = [];

  String? get selectedPort => _selectedPort;
  int get selectedBaudRate => _selectedBaudRate;
  List<String> get availablePorts => _availablePorts;

  //用于统计串口速率
  int _totalRxBytes = 0;
  int get totalRxBytes => _totalRxBytes;

  set selectedPort(String? v) {
    //改变数值以后，调用这个方法，广播给监听这个类的各个函数
    _selectedPort = v;
    notifyListeners();
  }

  set selectedBaudRate(int v) {
    _selectedBaudRate = v;
    notifyListeners();
  }

  void refreshPorts() {
    _availablePorts = SerialPort.availablePorts;
    notifyListeners();
  }

  Future<bool> connectWithInternal() async {
    if (_selectedPort == null) return false;
    return await connect(_selectedPort!, _selectedBaudRate);
  }

  Future<bool> connect(String portName, int baudRate) async {
    try {
      disconnect(); // 先断开旧的

      _port = SerialPort(portName);

      // 注意：libserialport 的 openReadWrite 其实是同步阻塞的 C 可以在这里执行
      // 但因为它很快，通常不会卡死 UI。
      if (!_port!.openReadWrite()) {
        print("打开串口失败: ${SerialPort.lastError}");
        return false;
      }

      SerialPortConfig config = _port!.config;
      config.baudRate = baudRate;
      _port!.config = config;

      // Reader 会在底层创建一个 Isolate 或者 Stream，这是真正的异步读取
      _reader = SerialPortReader(_port!);
      _reader!.stream.listen(
        (data) => _onDataReceived(data),
        onError: (e) {
          disconnect(); // 发生错误自动断开
          print("串口读取错误: $e");
        },
        onDone: () => disconnect(), // 流结束（比如拔线）自动断开
      );

      isConnected = true;
      shakeHandSuccessful = false; // 连接刚建立，握手状态重置
      notifyListeners();

      // 可选：连接后自动握手
      // await shakeWithMCU();

      return true;
    } catch (e) {
      print("Connect Exception: $e");
      return false;
    }
  }

  void disconnect() {
    // 断开连接时，如果有正在等待的握手，直接让它失败
    if (_handshakeCompleter != null && !_handshakeCompleter!.isCompleted) {
      _handshakeCompleter!.complete(false);
      _handshakeCompleter = null;
    }

    _reader?.close();
    _port?.close();
    _port = null;
    isConnected = false;
    shakeHandSuccessful = false;
    // _rxBuffer.clear();
    // registry.clear();
    notifyListeners();
  }

  Future<bool> shakeWithMCU() async {
    if (!isConnected) return false;

    // 1. 如果上一次握手还在进行中，先取消它
    if (_handshakeCompleter != null && !_handshakeCompleter!.isCompleted) {
      _handshakeCompleter!.complete(false);
    }

    // 2. 创建一个新的 Completer
    _handshakeCompleter = Completer<bool>();

    // 3. 发送数据
    try {
      print("发送握手包...");
      sendData(DebugProtocol.packHandshake());
    } catch (e) {
      return false;
    }

    // 4. 等待结果，设置超时时间 (比如 2 秒)
    // 这里并没有真正去"读"数据，而是等待 _onDataReceived 里调用 complete
    try {
      bool result = await _handshakeCompleter!.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          // 超时处理
          print("握手超时");
          return false;
        },
      );
      return result;
    } catch (e) {
      return false;
    }
  }

  // 4. 内部用的添加日志方法
  void _addLog(LogType type, String content) {
    final entry = LogEntry(type, content);

    // A. 推流给 UI (实时显示)
    _logCtrl.add(entry);

    // B. 分类存入历史 (防止切 Tab 丢失)
    if (type == LogType.info || type == LogType.error) {
      // 存入系统日志列表
      _sysLogHistory.add(entry);
      if (_sysLogHistory.length > _maxSysLogHistory) {
        _sysLogHistory.removeAt(0);
      }
    } else {
      // 存入裸数据列表
      _dataLogHistory.add(entry);
      if (_dataLogHistory.length > _maxDataLogHistory) {
        _dataLogHistory.removeAt(0);
      }
    }
  }

  // 4. 提供给 UI 的初始化获取方法：合并并按时间排序
  List<LogEntry> get combinedHistory {
    // 将两个列表合并
    final List<LogEntry> merged = [..._sysLogHistory, ..._dataLogHistory];
    // 重新按时间戳排序，保证 UI 显示顺序正确
    merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return merged;
  }

  void sendData(Uint8List data) {
    if (_port != null && _port!.isOpen) _port!.write(data);

    // -> 记录 TX 日志
    final hexStr = data
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
    _addLog(LogType.tx, hexStr);
  }

  void _onDataReceived(Uint8List newData) {
    if (newData.isEmpty) return;

    final hexStr = newData
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');

    //统计串口速率
    _totalRxBytes += newData.length;

    // _rawLogCtrl.add("[$timeStr] Rx: $hexStr");
    _addLog(LogType.rx, hexStr);
    _rxBuffer.addAll(newData);
    if (_rxBuffer.length > MAX_BUFFER_SIZE) _rxBuffer.clear();

    int parseIndex = 0;
    int bufferLen = _rxBuffer.length;

    while (parseIndex < bufferLen) {
      if (_rxBuffer[parseIndex] != 0xAA) {
        parseIndex++;
        continue;
      }
      if (bufferLen - parseIndex < 4) break;

      int vid = _rxBuffer[parseIndex + 1];
      int vrawType = _rxBuffer[parseIndex + 2]; // 包含频率位的原始 Type
      int vlen = _rxBuffer[parseIndex + 3];
      int packetLen = 6 + vlen;

      if (bufferLen - parseIndex < packetLen) break;

      List<int> fullPacket = _rxBuffer.sublist(parseIndex, parseIndex + packetLen);
      List<int> checkPayload = fullPacket.sublist(1, 4 + vlen);
      int crcRecv = (fullPacket[4 + vlen] << 8) | fullPacket[5 + vlen];
      int crcCalc = DebugProtocol.calcCrc(checkPayload);

      if (crcCalc == crcRecv) {
        Uint8List dataPart = Uint8List.fromList(fullPacket.sublist(4, 4 + vlen));
        // 传递 rawType 进去，在 process 里面拆解
        _processPacket(vid, vrawType, vlen, dataPart);
        parseIndex += packetLen;
      } else {
        parseIndex++;
      }
    }
    if (parseIndex > 0) _rxBuffer.removeRange(0, parseIndex);
  }

  void _processPacket(int vid, int rawType, int vlen, Uint8List dataPart) {
    // 握手包 (ID=0xFD)
    if (vid == 0xFD) {
      print("收到握手回复!");
      shakeHandSuccessful = true;
      notifyListeners();

      // 关键：如果此时有正在等待的 Completer，告诉它成功了！
      if (_handshakeCompleter != null && !_handshakeCompleter!.isCompleted) {
        _handshakeCompleter!.complete(true);
        _handshakeCompleter = null; // 用完置空
      }
      return;
    }

    if (vid == 0xFC) {
      int offset = 0;

      // 遍历解析整个 dataPart
      while (offset < vlen && offset < dataPart.length) {
        int id = dataPart[offset]; // 读取当前数据块的 ID
        offset += 1;

        // 安全检查：如果该 ID 还没注册，说明握手存在数据丢失，停止解析当前包
        if (!registry.containsKey(id)) {
          print("解析批量高频包错误: 遇到未注册的 ID $id");
          break;
        }

        final variable = registry[id]!;
        int type = variable.type;
        int varLen = _getVarLength(type); // 获取该变量应该占用的字节数

        // 防止数组越界
        if (offset + varLen > dataPart.length) break;

        final bd = ByteData.sublistView(dataPart, offset, offset + varLen);
        dynamic val = 0;

        // 根据类型解析数值
        if (varLen == 1)
          val = bd.getUint8(0);
        else if (varLen == 2)
          val = bd.getUint16(0, Endian.big);
        else if (varLen == 4) {
          val = (type == 6) ? bd.getFloat32(0, Endian.big) : bd.getUint32(0, Endian.big);
        }

        // 更新内存并在流中广播
        variable.value = val;
        _highFreqDataCtrl.add(MapEntry(id, val.toDouble()));

        // 步进到下一个变量
        offset += varLen;
      }
      return;
    }

    // 元数据注册 (ID=0xFE)
    // 注意：下位机回传的 Type 字节也应该包含频率位和静态位
    if (vid == 0xFE) {
      if (dataPart.length == 16) {
        int regId = dataPart[0];
        int regRawType = dataPart[1];

        int regAddr = ByteData.sublistView(dataPart, 2, 6).getUint32(0, Endian.big);
        String name = ascii
            .decode(dataPart.sublist(6, 16), allowInvalid: true)
            .split('\x00')
            .first;

        int realType = regRawType & DebugProtocol.maskType;
        bool isHigh = (regRawType & DebugProtocol.maskFreq) != 0;
        bool isStatic = (regRawType & DebugProtocol.maskStatic) != 0;

        bool isNew = !registry.containsKey(regId);
        RegisteredVar newVar = RegisteredVar(regId, name, realType, regAddr,
            isHighFreq: isHigh, isStatic: isStatic);

        if (isNew) {
          if (isHigh) {
            // 高频变量：直接追加到末尾
            registry[regId] = newVar;
          } else {
            // 低频/静态变量：找到现存第一个高频变量的位置，插到它前面
            List<int> keys = registry.keys.toList();
            int insertIndex = keys.indexWhere((k) => registry[k]!.isHighFreq);

            if (insertIndex == -1) {
              // 还没有高频变量，直接放最后
              registry[regId] = newVar;
            } else {
              // 插入并重建 Map 以保持顺序
              keys.insert(insertIndex, regId);
              final Map<int, RegisteredVar> tempMap = {};
              for (var k in keys) {
                tempMap[k] = k == regId ? newVar : registry[k]!;
              }
              registry.clear();
              registry.addAll(tempMap);
            }
          }
        } else {
          // 已存在的变量直接更新
          registry[regId] = newVar;
        }
        notifyListeners();
      }
      return;
    }

    // 日志 (ID=0xFF)
    if (vid == 0xFF) {
      try {
        // 1. ASCII 解码
        // allowInvalid: true 保证即使有乱码也不会崩
        String msg = ascii.decode(dataPart, allowInvalid: true);

        // 2. 去除 C 语言字符串末尾可能包含的 '\0' (Null Terminator)
        // 如果不去除，在界面上可能会显示奇怪的方框
        msg = msg.split('\x00').first;

        // 3. 推送到日志流，类型设为 info (对应 DebugConsole 的黄色)
        _addLog(LogType.info, msg);
      } catch (e) {
        // 如果解析失败，回退到显示 Hex，或者报错
        _addLog(LogType.error, "Log Decode Err: $e");
      }
      return;
    }

    // 普通变量值
    if (registry.containsKey(vid)) {
      dynamic val = 0;
      final bd = ByteData.sublistView(dataPart);
      int type = registry[vid]!.type;

      // 解析逻辑
      if (vlen == 1)
        val = bd.getUint8(0);
      else if (vlen == 2)
        val = bd.getUint16(0, Endian.big);
      else if (vlen == 4) {
        val = (type == 6) ? bd.getFloat32(0, Endian.big) : bd.getUint32(0, Endian.big);
      }

      final variable = registry[vid]!;
      variable.value = val; // 静默更新内存中的值

      if (variable.isHighFreq) {
        // --- 高频数据：只发流，不广播 ---
        _highFreqDataCtrl.add(MapEntry(vid, val.toDouble()));
      } else {
        // --- 低频数据：广播通知 UI 更新数值列表 ---
        // notifyListeners();
      }
    }
  }

  void reorderRegistry(int oldIndex, int newIndex) {
    // 1. 将现有的 Key 转为 List
    List<int> keys = registry.keys.toList();

    // 2. 调整 List 里的顺序
    final int item = keys.removeAt(oldIndex);
    keys.insert(newIndex, item);

    // 3. 创建一个新的临时 Map，按新顺序存放
    final Map<int, RegisteredVar> sortedMap = {};
    for (var key in keys) {
      sortedMap[key] = registry[key]!;
    }

    // 4. 清空原 Map 并重新填充（或者直接替换引用）
    registry.clear();
    registry.addAll(sortedMap);

    // 5. 通知 UI 刷新
    notifyListeners();
  }

  int _getVarLength(int type) {
    if (type == 0 || type == 1) return 1; // uint8, int8
    if (type == 2 || type == 3) return 2; // uint16, int16
    if (type >= 4 && type <= 6) return 4; // uint32, int32, float
    return 0;
  }

  void clearRegistry() {
    registry.clear();
    notifyListeners();
  }

  // 发送静态变量刷新请求
  void requestStaticRefresh(int varId) {
    sendData(DebugProtocol.packStaticRefreshCmd(varId));
  }

  // 只针对非静态变量的排序
  void reorderNonStaticVars(int oldIndex, int newIndex) {
    // 1. 分离静态和非静态变量
    List<int> staticKeys = [];
    List<int> nonStaticKeys = [];

    for (var key in registry.keys) {
      if (registry[key]!.isStatic) {
        staticKeys.add(key);
      } else {
        nonStaticKeys.add(key);
      }
    }

    // 2. 在非静态变量列表中调整顺序
    if (oldIndex >= 0 && oldIndex < nonStaticKeys.length &&
        newIndex >= 0 && newIndex < nonStaticKeys.length) {
      final int item = nonStaticKeys.removeAt(oldIndex);
      nonStaticKeys.insert(newIndex, item);
    }

    // 3. 重建 Map：先放非静态（保持新顺序），后放静态（保持原顺序）
    final Map<int, RegisteredVar> sortedMap = {};
    for (var key in nonStaticKeys) {
      sortedMap[key] = registry[key]!;
    }
    for (var key in staticKeys) {
      sortedMap[key] = registry[key]!;
    }

    // 4. 清空原 Map 并重新填充
    registry.clear();
    registry.addAll(sortedMap);

    // 5. 通知 UI 刷新
    notifyListeners();
  }

  @override
  void dispose() {
    _logCtrl.close();
    super.dispose();
  }
}
