import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:ui_widget_test/core/services/device_core.dart';
import 'package:ui_widget_test/debug_protocol.dart';

ArgParser _createParser() {
  return ArgParser()
    ..addOption('port', help: 'Serial port name')
    ..addOption('baud', help: 'Baud rate', defaultsTo: '115200')
    ..addOption('highfreq', help: 'Enable high frequency mode', defaultsTo: 'false')
    ..addOption('static', help: 'Mark as static variable', defaultsTo: 'false')
    ..addOption('window', help: 'Window size for stats', defaultsTo: '100')
    ..addOption('timeout', help: 'Timeout in seconds', defaultsTo: '0')
    ..addOption('duration', help: 'Duration in seconds', defaultsTo: '4')
    ..addOption('width', help: 'Plot width', defaultsTo: '80')
    ..addOption('height', help: 'Plot height', defaultsTo: '10');
}

Future<void> runFlowave(List<String> args) async {
  final parser = _createParser();

  if (args.isEmpty) {
    _printUsage(parser);
    return;
  }

  final command = args.first;
  final commandArgs = args.length > 1 ? args.sublist(1) : <String>[];

  ArgResults argResults;
  try {
    argResults = parser.parse(commandArgs);
  } catch (e) {
    print(jsonEncode({'status': 'error', 'message': 'Invalid arguments: $e'}));
    return;
  }

  final portOption = argResults['port'] as String?;
  final baudOption = int.tryParse(argResults['baud'] as String? ?? '115200') ?? 115200;

  final core = DeviceCore();

  switch (command) {
    case 'list-ports':
      core.refreshPorts();
      print(jsonEncode(core.availablePorts));
      exit(0);

    case 'connect':
      if (portOption == null) {
        print(jsonEncode({'status': 'error', 'message': 'Missing --port option'}));
        exit(1);
      }
      final success = await core.connect(portOption, baudOption);
      if (success) {
        print(jsonEncode({'status': 'connected'}));
        exit(0);
      } else {
        print(jsonEncode({'status': 'error', 'message': 'Failed to connect'}));
        exit(1);
      }

    case 'disconnect':
      core.disconnect();
      print(jsonEncode({'status': 'disconnected'}));
      exit(0);

    case 'handshake':
      if (!core.isConnected) {
        print(jsonEncode({'status': 'error', 'message': 'Not connected'}));
        exit(1);
      }
      final success = await core.shakeWithMCU();
      print(jsonEncode({'success': success}));
      exit(0);

    // ========== 变量操作命令 ==========
    case 'register':
      await _handleRegister(core, commandArgs, argResults);
      exit(0);

    case 'write':
      await _handleWrite(core, commandArgs);
      exit(0);

    case 'refresh':
      await _handleRefresh(core, commandArgs);
      exit(0);

    case 'refresh-all':
      await _handleRefreshAll(core);
      exit(0);

    case 'list-vars':
      _handleListVars(core);
      exit(0);

    case 'save-static':
      await _handleSaveStatic(core, commandArgs);
      exit(0);

    case 'load-static':
      await _handleLoadStatic(core, commandArgs);
      exit(0);

    case 'write-all-static':
      await _handleWriteAllStatic(core);
      exit(0);

    case 'text':
      await _handleText(core, commandArgs);
      exit(0);

    // ========== 监控与流式输出 ==========
    case 'monitor':
      await _handleMonitor(core, argResults);
      return;

    // ========== AI 友好命令 ==========
    case 'stats':
      await _handleStats(core, commandArgs, argResults);
      exit(0);

    case 'plot':
      await _handlePlot(core, commandArgs, argResults);
      exit(0);

    case 'help':
    case '--help':
    case '-h':
      _printUsage(parser);
      exit(0);

    default:
      print(jsonEncode({'status': 'error', 'message': 'Unknown command: $command'}));
      return;
  }
}

// ========== 变量操作命令实现 ==========

Future<void> _handleRegister(DeviceCore core, List<String> args, ArgResults opts) async {
  if (args.length < 3) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: register <addr hex> <name> <type>'}));
    return;
  }
  final addrStr = args[0];
  final name = args[1];
  final type = int.tryParse(args[2]);
  if (type == null || type < 0 || type > 6) {
    print(jsonEncode({'status': 'error', 'message': 'type must be 0-6'}));
    return;
  }
  final addr = int.tryParse(addrStr.replaceFirst('0x', ''), radix: 16);
  if (addr == null) {
    print(jsonEncode({'status': 'error', 'message': 'Invalid address'}));
    return;
  }
  final isHighFreq = (opts['highfreq'] as String?) == 'true';
  final isStatic = (opts['static'] as String?) == 'true';

  core.sendData(DebugProtocol.packRegisterCmd(addr, name, type, isHighFreq: isHighFreq, isStatic: isStatic));
  print(jsonEncode({'status': 'ok', 'addr': '0x${addr.toRadixString(16).toUpperCase()}', 'name': name, 'type': type, 'isHighFreq': isHighFreq, 'isStatic': isStatic}));
}

Future<void> _handleWrite(DeviceCore core, List<String> args) async {
  if (args.length < 3) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: write <varId> <value> <type>'}));
    return;
  }
  final varId = int.tryParse(args[0]);
  final type = int.tryParse(args[2]);
  if (varId == null || type == null) {
    print(jsonEncode({'status': 'error', 'message': 'Invalid varId or type'}));
    return;
  }
  dynamic value;
  final varLen = _getVarLength(type);
  if (type == 6) {
    value = double.tryParse(args[1]) ?? 0.0;
  } else if (type <= 1) {
    value = int.tryParse(args[1]) ?? 0;
  } else if (type <= 3) {
    value = int.tryParse(args[1]) ?? 0;
  } else {
    value = int.tryParse(args[1]) ?? 0;
  }

  core.sendData(DebugProtocol.packWriteCmd(varId, varLen, value, type));
  print(jsonEncode({'status': 'ok', 'varId': varId, 'value': value, 'type': type}));
}

Future<void> _handleRefresh(DeviceCore core, List<String> args) async {
  if (args.isEmpty) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: refresh <varId>'}));
    return;
  }
  final varId = int.tryParse(args[0]);
  if (varId == null) {
    print(jsonEncode({'status': 'error', 'message': 'Invalid varId'}));
    return;
  }
  core.requestStaticRefresh(varId);
  print(jsonEncode({'status': 'ok', 'varId': varId}));
}

Future<void> _handleRefreshAll(DeviceCore core) async {
  final staticVars = core.registry.values.where((v) => v.isStatic).toList();
  for (final v in staticVars) {
    core.requestStaticRefresh(v.id);
  }
  print(jsonEncode({'status': 'ok', 'count': staticVars.length}));
}

void _handleListVars(DeviceCore core) {
  final vars = core.registry.values.map((v) => {
    'id': v.id,
    'name': v.name,
    'type': v.type,
    'addr': '0x${v.addr.toRadixString(16).toUpperCase()}',
    'value': v.value,
    'isHighFreq': v.isHighFreq,
    'isStatic': v.isStatic,
  }).toList();
  print(jsonEncode(vars));
}

Future<void> _handleSaveStatic(DeviceCore core, List<String> args) async {
  if (args.isEmpty) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: save-static <path>'}));
    return;
  }
  try {
    await core.saveStaticVarsToJson(args[0]);
    print(jsonEncode({'status': 'ok', 'path': args[0]}));
  } catch (e) {
    print(jsonEncode({'status': 'error', 'message': '$e'}));
  }
}

Future<void> _handleLoadStatic(DeviceCore core, List<String> args) async {
  if (args.isEmpty) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: load-static <path>'}));
    return;
  }
  try {
    final count = await core.loadStaticVarsFromJson(args[0]);
    print(jsonEncode({'status': 'ok', 'count': count, 'path': args[0]}));
  } catch (e) {
    print(jsonEncode({'status': 'error', 'message': '$e'}));
  }
}

Future<void> _handleWriteAllStatic(DeviceCore core) async {
  try {
    await core.writeAllStaticVarsToDevice();
    print(jsonEncode({'status': 'ok'}));
  } catch (e) {
    print(jsonEncode({'status': 'error', 'message': '$e'}));
  }
}

Future<void> _handleText(DeviceCore core, List<String> args) async {
  if (args.isEmpty) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: text <message>'}));
    return;
  }
  core.sendData(DebugProtocol.packTextCmd(args.join(' ')));
  print(jsonEncode({'status': 'ok'}));
}

// ========== 监控命令实现 ==========

Future<void> _handleMonitor(DeviceCore core, ArgResults opts) async {
  final watchHighFreq = opts['highfreq'] == 'true';
  final watchLog = opts['log'] == 'true';
  final timeout = int.tryParse(opts['timeout'] as String? ?? '0') ?? 0;

  if (!watchHighFreq && !watchLog) {
    print(jsonEncode({'status': 'error', 'message': 'Use --highfreq and/or --log'}));
    return;
  }

  StreamSubscription? highFreqSub;
  StreamSubscription? logSub;
  final done = Completer<void>();

  if (watchHighFreq) {
    highFreqSub = core.highFreqStream.listen((entry) {
      print(jsonEncode({
        'type': 'highfreq',
        'varId': entry.key,
        'value': entry.value,
        'timestamp': DateTime.now().toIso8601String(),
      }));
    });
  }

  if (watchLog) {
    logSub = core.logStream.listen((entry) {
      print(jsonEncode({
        'type': 'log',
        'content': entry.content,
        'logType': entry.type.name,
        'timestamp': entry.timestamp.toIso8601String(),
      }));
    });
  }

  // 处理超时
  if (timeout > 0) {
    Future.delayed(Duration(seconds: timeout), () {
      if (!done.isCompleted) done.complete();
    });
  }

  // 处理 SIGINT
  ProcessSignal.sigint.watch().first.then((_) {
    if (!done.isCompleted) done.complete();
  });

  await done.future;
  await highFreqSub?.cancel();
  await logSub?.cancel();
  core.dispose();
}

// ========== AI 友好命令实现 ==========

Future<void> _handleStats(DeviceCore core, List<String> args, ArgResults opts) async {
  if (args.isEmpty) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: stats <varId>'}));
    return;
  }
  final varId = int.tryParse(args[0]);
  if (varId == null) {
    print(jsonEncode({'status': 'error', 'message': 'Invalid varId'}));
    return;
  }
  final windowSize = int.tryParse(opts['window'] as String? ?? '100') ?? 100;
  final duration = int.tryParse(opts['duration'] as String? ?? '4') ?? 4;

  // 订阅一段时间收集数据
  final values = <double>[];
  final sub = core.highFreqStream.listen((entry) {
    if (entry.key == varId) {
      values.add(entry.value);
    }
  });

  await Future.delayed(Duration(seconds: duration));
  await sub.cancel();

  if (values.isEmpty) {
    // 尝试从 registry 获取当前值
    final v = core.registry[varId];
    if (v != null) {
      print(jsonEncode({
        'status': 'ok',
        'varId': varId,
        'value': v.value,
        'note': 'static value from registry',
      }));
    } else {
      print(jsonEncode({'status': 'error', 'message': 'No data collected'}));
    }
    return;
  }

  // 取最近的 window 个值
  final recent = values.length > windowSize ? values.sublist(values.length - windowSize) : values;
  final stats = _calculateStats(recent);
  print(jsonEncode({
    'status': 'ok',
    'varId': varId,
    'count': recent.length,
    'min': stats['min'],
    'max': stats['max'],
    'mean': stats['mean'],
    'std': stats['std'],
    'trend': stats['trend'],
  }));
}

Future<void> _handlePlot(DeviceCore core, List<String> args, ArgResults opts) async {
  if (args.isEmpty) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: plot <varId>'}));
    return;
  }
  final varId = int.tryParse(args[0]);
  if (varId == null) {
    print(jsonEncode({'status': 'error', 'message': 'Invalid varId'}));
    return;
  }
  final width = int.tryParse(opts['width'] as String? ?? '80') ?? 80;
  final duration = int.tryParse(opts['duration'] as String? ?? '4') ?? 4;

  // 订阅一段时间收集数据
  final values = <double>[];
  final sub = core.highFreqStream.listen((entry) {
    if (entry.key == varId) {
      values.add(entry.value);
    }
  });

  await Future.delayed(Duration(seconds: duration));
  await sub.cancel();

  if (values.isEmpty) {
    print(jsonEncode({'status': 'error', 'message': 'No data collected'}));
    return;
  }

  // 取最近的 width 个值
  final recent = values.length > width ? values.sublist(values.length - width) : values;
  final stats = _calculateStats(recent);

  // 绘制 ASCII 图表
  _printAsciiPlot(recent, stats);

  print(jsonEncode({
    'min': stats['min'],
    'max': stats['max'],
    'avg': stats['mean'],
  }));
}

// ========== 辅助函数 ==========

int _getVarLength(int type) {
  if (type == 0 || type == 1) return 1;
  if (type == 2 || type == 3) return 2;
  if (type >= 4 && type <= 6) return 4;
  return 0;
}

Map<String, double> _calculateStats(List<double> data) {
  if (data.isEmpty) {
    return {'min': 0.0, 'max': 0.0, 'mean': 0.0, 'std': 0.0, 'trend': 0.0};
  }
  double min = data.first, max = data.first, sum = 0.0;
  for (final v in data) {
    if (v < min) min = v;
    if (v > max) max = v;
    sum += v;
  }
  final mean = sum / data.length;

  // 标准差
  double varSum = 0.0;
  for (final v in data) {
    final diff = v - mean;
    varSum += diff * diff;
  }
  final std = (varSum / data.length).abs();

  // 线性回归斜率 (trend)
  double trend = 0.0;
  if (data.length > 1) {
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
    for (int i = 0; i < data.length; i++) {
      sumX += i;
      sumY += data[i];
      sumXY += i * data[i];
      sumX2 += i * i;
    }
    final denom = data.length * sumX2 - sumX * sumX;
    if (denom != 0) {
      trend = (data.length * sumXY - sumX * sumY) / denom;
    }
  }

  return {'min': min, 'max': max, 'mean': mean, 'std': std, 'trend': trend};
}

void _printAsciiPlot(List<double> data, Map<String, double> stats) {
  final min = stats['min']!;
  final max = stats['max']!;
  final range = max - min;
  if (range == 0) {
    print('|${'─' * 78}| ${min.toStringAsFixed(2)} (flat line)');
    return;
  }

  final width = 78;
  final height = 10;
  final lines = List.generate(height, (_) => List.filled(width, ' '));

  // 绘制波形
  for (int i = 0; i < data.length; i++) {
    final x = (i * width / data.length).clamp(0, width - 1).toInt();
    final y = ((max - data[i]) / range * (height - 1)).clamp(0, height - 1).toInt();
    lines[y][x] = '●';
  }

  // 输出
  for (final line in lines) {
    print('|${line.join('')}|');
  }
}

void _printUsage(ArgParser parser) {
  print('Usage: flowave <command> [options]');
  print('');
  print('Commands:');
  print('  list-ports              List available serial ports');
  print('  connect --port <name>   Connect to serial port');
  print('  disconnect            Disconnect from serial port');
  print('  handshake            Perform handshake with device');
  print('');
  print('  register <addr> <name> <type>  Register a variable');
  print('  write <varId> <value> <type>    Write variable value');
  print('  refresh <varId>              Refresh static variable');
  print('  refresh-all                  Refresh all static variables');
  print('  list-vars                    List all registered variables');
  print('  save-static <path>           Save static variables to JSON');
  print('  load-static <path>            Load static variables from JSON');
  print('  write-all-static              Write all static variables to device');
  print('  text <message>                Send text message to device');
  print('');
  print('  monitor [--highfreq] [--log] [--timeout <sec>]  Monitor streams');
  print('  stats <varId> [--window N] [--duration N]       Calculate statistics');
  print('  plot <varId> [--width N]                        Plot ASCII waveform');
  print('');
  print('Options:');
  print('  --port <name>        Serial port name');
  print('  --baud <rate>        Baud rate (default: 115200)');
  print('  --highfreq          Enable high frequency mode');
  print('  --static            Mark as static variable');
}

void main(List<String> args) {
  runFlowave(args);
}