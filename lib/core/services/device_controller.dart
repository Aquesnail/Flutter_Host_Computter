import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/log_entry.dart';
import '../models/registered_var.dart';
import 'device_core.dart';

class DeviceController extends ChangeNotifier {
  late final DeviceCore _core;

  DeviceController() {
    _core = DeviceCore(onChanged: _onCoreChanged);
  }

  void _onCoreChanged() {
    notifyListeners();
  }

  // === 状态字段代理 ===
  bool get isConnected => _core.isConnected;
  bool get shakeHandSuccessful => _core.shakeHandSuccessful;
  Map<int, RegisteredVar> get registry => _core.registry;

  String? get selectedPort => _core.selectedPort;
  int get selectedBaudRate => _core.selectedBaudRate;
  List<String> get availablePorts => _core.availablePorts;
  int get totalRxBytes => _core.totalRxBytes;
  bool get demoModeActive => _core.demoModeActive;

  // === Stream 代理 ===
  Stream<MapEntry<int, double>> get highFreqStream => _core.highFreqStream;
  Stream<LogEntry> get logStream => _core.logStream;

  // === 历史日志 ===
  List<LogEntry> get combinedHistory => _core.combinedHistory;

  // === Setter 代理 ===
  set selectedPort(String? v) => _core.selectedPort = v;
  set selectedBaudRate(int v) => _core.selectedBaudRate = v;

  // === 方法代理 ===
  void refreshPorts() => _core.refreshPorts();

  Future<bool> connectWithInternal() => _core.connectWithInternal();

  Future<bool> connect(String portName, int baudRate) =>
      _core.connect(portName, baudRate);

  void disconnect() => _core.disconnect();

  Future<bool> shakeWithMCU() => _core.shakeWithMCU();

  void sendData(Uint8List data) => _core.sendData(data);

  void reorderRegistry(int oldIndex, int newIndex) =>
      _core.reorderRegistry(oldIndex, newIndex);

  void reorderNonStaticVars(int oldIndex, int newIndex) =>
      _core.reorderNonStaticVars(oldIndex, newIndex);

  void clearRegistry() => _core.clearRegistry();

  void requestStaticRefresh(int varId) => _core.requestStaticRefresh(varId);

  void toggleDemoMode() => _core.toggleDemoMode();

  Future<String> saveStaticVarsToJson(String path) =>
      _core.saveStaticVarsToJson(path);

  Future<int> loadStaticVarsFromJson(String path) =>
      _core.loadStaticVarsFromJson(path);

  Future<void> writeAllStaticVarsToDevice() => _core.writeAllStaticVarsToDevice();

  void setAutoSavePath(String path) => _core.setAutoSavePath(path);

  Future<void> triggerAutoSave() => _core.triggerAutoSave();

  @override
  void dispose() {
    _core.dispose();
    super.dispose();
  }
}