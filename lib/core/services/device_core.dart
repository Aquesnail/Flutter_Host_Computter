import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import '../../debug_protocol.dart';
import '../models/log_entry.dart';
import '../models/registered_var.dart';

class DeviceCore {
  SerialPort? _port;
  SerialPortReader? _reader;
  bool isConnected = false;
  bool shakeHandSuccessful = false;
  final Map<int, RegisteredVar> registry = {};

  bool _waitingForHandshake = false;  // handshake 等待标志
  Completer<bool>? _handshakeCompleter;
  final _highFreqDataCtrl = StreamController<MapEntry<int, double>>.broadcast();
  final _logCtrl = StreamController<LogEntry>.broadcast();
  Stream<MapEntry<int, double>> get highFreqStream => _highFreqDataCtrl.stream;
  Stream<LogEntry> get logStream => _logCtrl.stream;

  final List<int> _rxBuffer = [];
  static const int MAX_BUFFER_SIZE = 1024 * 1024;

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

  int _totalRxBytes = 0;
  int get totalRxBytes => _totalRxBytes;

  bool _demoModeActive = false;
  bool get demoModeActive => _demoModeActive;
  Timer? _demoTimer;
  double _demoTime = 0;
  int _demoTick = 0;

  void Function()? onChanged;

  DeviceCore({this.onChanged});

  void _notify() {
    onChanged?.call();
  }

  set selectedPort(String? v) {
    _selectedPort = v;
    _notify();
  }

  set selectedBaudRate(int v) {
    _selectedBaudRate = v;
    _notify();
  }

  void refreshPorts() {
    _availablePorts = SerialPort.availablePorts;
    _notify();
  }

  Future<bool> connectWithInternal() async {
    if (_selectedPort == null) return false;
    return await connect(_selectedPort!, _selectedBaudRate);
  }

  Future<bool> connect(String portName, int baudRate) async {
    try {
      disconnect();

      _port = SerialPort(portName);

      if (!_port!.openReadWrite()) {
        print("打开串口失败: ${SerialPort.lastError}");
        return false;
      }

      SerialPortConfig config = _port!.config;
      config.baudRate = baudRate;
      _port!.config = config;

      _reader = SerialPortReader(_port!);
      _reader!.stream.listen(
        (data) => _onDataReceived(data),
        onError: (e) {
          disconnect();
          print("串口读取错误: $e");
        },
        onDone: () => disconnect(),
      );

      isConnected = true;
      shakeHandSuccessful = false;
      _notify();

      return true;
    } catch (e) {
      print("Connect Exception: $e");
      return false;
    }
  }

  void disconnect() {
    if (_handshakeCompleter != null && !_handshakeCompleter!.isCompleted) {
      _handshakeCompleter!.complete(false);
      _handshakeCompleter = null;
    }

    _reader?.close();
    _port?.close();
    _port = null;
    isConnected = false;
    shakeHandSuccessful = false;
    _notify();
  }

  Future<bool> shakeWithMCU() async {
    if (!isConnected) return false;

    if (_handshakeCompleter != null && !_handshakeCompleter!.isCompleted) {
      _handshakeCompleter!.complete(false);
    }

    _handshakeCompleter = Completer<bool>();
    _waitingForHandshake = true;

    try {
      print("发送握手包...");
      sendData(DebugProtocol.packHandshake());
    } catch (e) {
      _waitingForHandshake = false;
      return false;
    }

    try {
      bool result = await _handshakeCompleter!.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          print("握手超时");
          _waitingForHandshake = false;
          return false;
        },
      );
      _waitingForHandshake = false;
      return result;
    } catch (e) {
      return false;
    }
  }

  void _addLog(LogType type, String content) {
    final entry = LogEntry(type, content);

    _logCtrl.add(entry);

    if (type == LogType.info || type == LogType.error) {
      _sysLogHistory.add(entry);
      if (_sysLogHistory.length > _maxSysLogHistory) {
        _sysLogHistory.removeAt(0);
      }
    } else {
      _dataLogHistory.add(entry);
      if (_dataLogHistory.length > _maxDataLogHistory) {
        _dataLogHistory.removeAt(0);
      }
    }
  }

  List<LogEntry> get combinedHistory {
    final List<LogEntry> merged = [..._sysLogHistory, ..._dataLogHistory];
    merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return merged;
  }

  void sendData(Uint8List data) {
    if (_port != null && _port!.isOpen) _port!.write(data);

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

    _totalRxBytes += newData.length;

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
      int vrawType = _rxBuffer[parseIndex + 2];
      int vlen = _rxBuffer[parseIndex + 3];
      int packetLen = 6 + vlen;

      if (bufferLen - parseIndex < packetLen) break;

      List<int> fullPacket = _rxBuffer.sublist(parseIndex, parseIndex + packetLen);
      List<int> checkPayload = fullPacket.sublist(1, 4 + vlen);
      int crcRecv = (fullPacket[4 + vlen] << 8) | fullPacket[5 + vlen];
      int crcCalc = DebugProtocol.calcCrc(checkPayload);

      if (crcCalc == crcRecv) {
        Uint8List dataPart = Uint8List.fromList(fullPacket.sublist(4, 4 + vlen));
        _processPacket(vid, vrawType, vlen, dataPart);
        parseIndex += packetLen;
      } else {
        parseIndex++;
      }
    }
    if (parseIndex > 0) _rxBuffer.removeRange(0, parseIndex);
  }

  void _processPacket(int vid, int rawType, int vlen, Uint8List dataPart) {
    // 等待握手时只处理握手响应
    if (_waitingForHandshake) {
      if (vid == 0xFD) {
        print("收到握手回复!");
        shakeHandSuccessful = true;
        _waitingForHandshake = false;
        _notify();

        if (_handshakeCompleter != null && !_handshakeCompleter!.isCompleted) {
          _handshakeCompleter!.complete(true);
          _handshakeCompleter = null;
        }
      }
      // 忽略其他所有包
      return;
    }

    if (vid == 0xFD) {
      print("收到握手回复!");
      shakeHandSuccessful = true;
      _notify();

      if (_handshakeCompleter != null && !_handshakeCompleter!.isCompleted) {
        _handshakeCompleter!.complete(true);
        _handshakeCompleter = null;
      }
      return;
    }

    if (vid == 0xFC) {
      int offset = 0;

      while (offset < vlen && offset < dataPart.length) {
        int id = dataPart[offset];
        offset += 1;

        if (!registry.containsKey(id)) {
          print("解析批量高频包错误: 遇到未注册的 ID $id");
          break;
        }

        final variable = registry[id]!;
        int type = variable.type;
        int varLen = _getVarLength(type);

        if (offset + varLen > dataPart.length) break;

        final bd = ByteData.sublistView(dataPart, offset, offset + varLen);
        dynamic val = 0;

        if (varLen == 1)
          val = bd.getUint8(0);
        else if (varLen == 2)
          val = bd.getUint16(0, Endian.big);
        else if (varLen == 4) {
          val = (type == 6) ? bd.getFloat32(0, Endian.big) : bd.getUint32(0, Endian.big);
        }

        variable.value = val;
        _highFreqDataCtrl.add(MapEntry(id, val.toDouble()));

        offset += varLen;
      }
      return;
    }

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
            registry[regId] = newVar;
          } else {
            List<int> keys = registry.keys.toList();
            int insertIndex = keys.indexWhere((k) => registry[k]!.isHighFreq);

            if (insertIndex == -1) {
              registry[regId] = newVar;
            } else {
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
          registry[regId] = newVar;
        }
        _notify();
      }
      return;
    }

    if (vid == 0xFF) {
      try {
        String msg = ascii.decode(dataPart, allowInvalid: true);
        msg = msg.split('\x00').first;
        _addLog(LogType.info, msg);
      } catch (e) {
        _addLog(LogType.error, "Log Decode Err: $e");
      }
      return;
    }

    if (registry.containsKey(vid)) {
      dynamic val = 0;
      final bd = ByteData.sublistView(dataPart);
      int type = registry[vid]!.type;

      if (vlen == 1)
        val = bd.getUint8(0);
      else if (vlen == 2)
        val = bd.getUint16(0, Endian.big);
      else if (vlen == 4) {
        val = (type == 6) ? bd.getFloat32(0, Endian.big) : bd.getUint32(0, Endian.big);
      }

      final variable = registry[vid]!;
      variable.value = val;

      if (variable.isHighFreq) {
        _highFreqDataCtrl.add(MapEntry(vid, val.toDouble()));
      } else {
        // 低频数据不触发 UI 刷新，由 UI 自行轮询
      }
    }
  }

  void reorderRegistry(int oldIndex, int newIndex) {
    List<int> keys = registry.keys.toList();

    final int item = keys.removeAt(oldIndex);
    keys.insert(newIndex, item);

    final Map<int, RegisteredVar> sortedMap = {};
    for (var key in keys) {
      sortedMap[key] = registry[key]!;
    }

    registry.clear();
    registry.addAll(sortedMap);

    _notify();
  }

  int _getVarLength(int type) {
    if (type == 0 || type == 1) return 1;
    if (type == 2 || type == 3) return 2;
    if (type >= 4 && type <= 6) return 4;
    return 0;
  }

  void clearRegistry() {
    registry.clear();
    _notify();
  }

  void toggleDemoMode() {
    if (_demoModeActive) {
      _stopDemoData();
    } else {
      _startDemoData();
    }
  }

  void _startDemoData() {
    _stopDemoData();
    _demoTime = 0;
    _demoTick = 0;

    registry[1] = RegisteredVar(1, "sine", 6, 0x20001000, isHighFreq: true);
    registry[2] = RegisteredVar(2, "cosine", 6, 0x20001004, isHighFreq: true);
    registry[3] = RegisteredVar(3, "saw", 6, 0x20001008, isHighFreq: true);

    registry[10] = RegisteredVar(10, "pitch", 6, 0x20001100, isHighFreq: true);
    registry[11] = RegisteredVar(11, "roll", 6, 0x20001104, isHighFreq: true);
    registry[12] = RegisteredVar(12, "yaw", 6, 0x20001108, isHighFreq: true);

    registry[4] = RegisteredVar(4, "counter", 2, 0x20002000);
    registry[5] = RegisteredVar(5, "temp", 3, 0x20002002);

    registry[6] = RegisteredVar(6, "version", 4, 0x20003000, isStatic: true);
    registry[7] = RegisteredVar(7, "threshold", 6, 0x20003004, isStatic: true);
    registry[6]!.value = 0x00010203;
    registry[7]!.value = 3.14159;

    _demoModeActive = true;
    _notify();

    _demoTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      _demoTime += 0.02;
      _demoTick++;

      final sine = sin(_demoTime * 2) * 100.0;
      final cosine = cos(_demoTime * 2) * 100.0;
      final saw = ((_demoTime % 2.0) - 1.0) * 50.0;

      registry[1]!.value = sine;
      registry[2]!.value = cosine;
      registry[3]!.value = saw;

      _highFreqDataCtrl.add(MapEntry(1, sine));
      _highFreqDataCtrl.add(MapEntry(2, cosine));
      _highFreqDataCtrl.add(MapEntry(3, saw));

      final pitch = sin(_demoTime) * 30.0;
      final roll = sin(_demoTime * 0.7) * 45.0;
      final yaw = (_demoTime * 10.0) % 360.0;

      registry[10]!.value = pitch;
      registry[11]!.value = roll;
      registry[12]!.value = yaw;

      _highFreqDataCtrl.add(MapEntry(10, pitch));
      _highFreqDataCtrl.add(MapEntry(11, roll));
      _highFreqDataCtrl.add(MapEntry(12, yaw));

      if (_demoTick % 25 == 0) {
        final counter = (_demoTick ~/ 25) % 65536;
        final temp = (25 + sin(_demoTime / 10) * 5).toInt();

        registry[4]!.value = counter;
        registry[5]!.value = temp;

        if (_demoTick % 100 == 0) {
          _addLog(LogType.info, "Demo: tick=$_demoTick, temp=$temp");
        }

        _notify();
      }
    });
  }

  void _stopDemoData() {
    _demoTimer?.cancel();
    _demoTimer = null;
    _demoModeActive = false;
    registry.clear();
    _notify();
  }

  void requestStaticRefresh(int varId) {
    sendData(DebugProtocol.packStaticRefreshCmd(varId));
  }

  static const String _jsonVersion = "1.0";

  Future<String> saveStaticVarsToJson(String path) async {
    final staticVars = registry.values.where((v) => v.isStatic).toList();
    if (staticVars.isEmpty) {
      throw Exception("没有静态变量可导出");
    }

    final varsList = staticVars.map((v) => {
      "id": v.id,
      "name": v.name,
      "type": v.type,
      "addr": v.addr,
      "value": v.value,
    }).toList();

    final json = {
      "version": _jsonVersion,
      "timestamp": DateTime.now().toIso8601String(),
      "vars": varsList,
    };

    final jsonStr = const JsonEncoder.withIndent("  ").convert(json);
    await File(path).writeAsString(jsonStr);
    return jsonStr;
  }

  Future<int> loadStaticVarsFromJson(String path) async {
    final jsonStr = await File(path).readAsString();
    final json = jsonDecode(jsonStr) as Map<String, dynamic>;

    final varsList = json["vars"] as List<dynamic>;
    int loadedCount = 0;

    for (final item in varsList) {
      final id = item["id"] as int;
      final name = item["name"] as String;
      final type = item["type"] as int;
      final addr = item["addr"] as int;
      final value = item["value"];

      if (registry.containsKey(id)) {
        registry[id] = RegisteredVar(id, name, type, addr, isStatic: true)..value = value;
        loadedCount++;
      } else {
        registry[id] = RegisteredVar(id, name, type, addr, isStatic: true)..value = value;
        loadedCount++;
      }
    }

    _notify();
    return loadedCount;
  }

  Future<void> writeAllStaticVarsToDevice() async {
    final staticVars = registry.values.where((v) => v.isStatic).toList();

    for (final v in staticVars) {
      final len = _getVarLength(v.type);
      sendData(DebugProtocol.packWriteCmd(v.id, len, v.value, v.type));
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  String? _autoSavePath;
  Timer? _autoSaveDebounce;

  void setAutoSavePath(String path) {
    _autoSavePath = path;
  }

  Future<void> triggerAutoSave() async {
    if (_autoSavePath == null) return;

    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        await saveStaticVarsToJson(_autoSavePath!);
        print("自动保存静态变量: $_autoSavePath");
      } catch (e) {
        print("自动保存失败: $e");
      }
    });
  }

  void reorderNonStaticVars(int oldIndex, int newIndex) {
    List<int> staticKeys = [];
    List<int> nonStaticKeys = [];

    for (var key in registry.keys) {
      if (registry[key]!.isStatic) {
        staticKeys.add(key);
      } else {
        nonStaticKeys.add(key);
      }
    }

    if (oldIndex >= 0 && oldIndex < nonStaticKeys.length &&
        newIndex >= 0 && newIndex < nonStaticKeys.length) {
      final int item = nonStaticKeys.removeAt(oldIndex);
      nonStaticKeys.insert(newIndex, item);
    }

    final Map<int, RegisteredVar> sortedMap = {};
    for (var key in nonStaticKeys) {
      sortedMap[key] = registry[key]!;
    }
    for (var key in staticKeys) {
      sortedMap[key] = registry[key]!;
    }

    registry.clear();
    registry.addAll(sortedMap);

    _notify();
  }

  void dispose() {
    _demoTimer?.cancel();
    _logCtrl.close();
    _highFreqDataCtrl.close();
  }
}