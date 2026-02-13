import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'debug_protocol.dart';

// 数据模型更新
class RegisteredVar {
  final int id;
  final String name;
  final int type; // 纯类型 (0-6)
  final int addr;
  final bool isHighFreq; // 是否高频
  dynamic value;

  RegisteredVar(this.id, this.name, this.type, this.addr, {this.value = 0, this.isHighFreq = false});
}

class DeviceController extends ChangeNotifier {
  SerialPort? _port;
  SerialPortReader? _reader;
  bool isConnected = false;
  bool shakeHandSuccessful = false;
  final List<String> logs = [];
  final Map<int, RegisteredVar> registry = {}; 
 // final StreamController<String> _rawLogCtrl = StreamController<String>.broadcast();
  
 // Stream<String> get rawLogStream => _rawLogCtrl.stream;
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
  final List<LogEntry> _recentLogs = [];
  List<LogEntry> get recentLogs => List.unmodifiable(_recentLogs);

  String? _selectedPort;
  int _selectedBaudRate = 115200;
  List<String> _availablePorts = [];

  String? get selectedPort => _selectedPort;
  int get selectedBaudRate => _selectedBaudRate;
  List<String> get availablePorts => _availablePorts;
  
  //用于统计串口速率
  int _totalRxBytes = 0;
  int get totalRxBytes => _totalRxBytes;

  set selectedPort(String? v) {   //改变数值以后，调用这个方法，广播给监听这个类的各个函数
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

  // void disconnect() {
  //   _reader?.close();
  //   _port?.close();
  //   _port = null;
  //   isConnected = false;
  //   _rxBuffer.clear();
  //   registry.clear();
  //   notifyListeners();
  // }
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
    
    // 广播出去 (通知 UI)
    _logCtrl.add(entry); 
    
    // 存入缓存
    _recentLogs.add(entry);
    if (_recentLogs.length > 50) _recentLogs.removeAt(0);
  }

  void sendData(Uint8List data) {
    if (_port != null && _port!.isOpen) _port!.write(data);

    // -> 记录 TX 日志
    final hexStr = data.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
     _addLog(LogType.tx, hexStr);
  }

  void _onDataReceived(Uint8List newData) {
    if (newData.isEmpty) return;
    
    final hexStr = newData.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
    
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

    // 元数据注册 (ID=0xFE)
    // 注意：下位机回传的 Type 字节也应该包含频率位
    if (vid == 0xFE) {
      // 期望是 16 字节: ID(1) + RawType(1) + Addr(4) + Name(10)
      if (dataPart.length == 16) {
        int regId = dataPart[0];
        int regRawType = dataPart[1];
        
        // 【修改点】解析 4 字节地址
        int regAddr = ByteData.sublistView(dataPart, 2, 6).getUint32(0, Endian.big);
        String name = ascii.decode(dataPart.sublist(6, 16), allowInvalid: true).split('\x00').first;

        // 【修改点】拆解类型和频率
        int realType = regRawType & DebugProtocol.maskType;
        bool isHigh = (regRawType & DebugProtocol.maskFreq) != 0;

        registry[regId] = RegisteredVar(regId, name, realType, regAddr, isHighFreq: isHigh);
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
      if (vlen == 1) val = bd.getUint8(0);
      else if (vlen == 2) val = bd.getUint16(0, Endian.big);
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

  void dispose(){
    _logCtrl.close();
    super.dispose();
  }
}

enum LogType {rx,tx,info,error}

class LogEntry{
  final DateTime timestamp;
  final LogType type;
  final String content;

  LogEntry(this.type,this.content) : timestamp = DateTime.now();

  String get timeStr{
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return "$h:$m:$s.$ms";
  }
}