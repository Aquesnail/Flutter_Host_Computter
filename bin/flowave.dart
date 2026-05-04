import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:http/http.dart' as http;

const _baseUrl = 'http://127.0.0.1:9876';

Future<void> _get(String path, {Map<String, String>? query}) async {
  final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);
  try {
    final response = await http.get(uri);
    print(response.body);
    exit(response.statusCode == 200 ? 0 : 1);
  } catch (e) {
    if (e is SocketException) {
      print(jsonEncode({'status': 'error', 'message': 'Cannot connect to daemon. Start flowaved first.'}));
    } else {
      print(jsonEncode({'status': 'error', 'message': '$e'}));
    }
    exit(1);
  }
}

Future<void> _post(String path, Map<String, dynamic> body) async {
  final uri = Uri.parse('$_baseUrl$path');
  try {
    final response = await http.post(uri,
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json'});
    print(response.body);
    exit(response.statusCode == 200 ? 0 : 1);
  } catch (e) {
    if (e is SocketException) {
      print(jsonEncode({'status': 'error', 'message': 'Cannot connect to daemon. Start flowaved first.'}));
    } else {
      print(jsonEncode({'status': 'error', 'message': '$e'}));
    }
    exit(1);
  }
}

Future<void> _sse(String path, {Map<String, String>? query}) async {
  final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);
  try {
    final client = http.Client();
    final request = http.Request('GET', uri);
    final streamedResponse = await client.send(request);
    final stream = streamedResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in stream) {
      if (line.startsWith('data: ')) {
        print(line.substring(6));
      }
    }
    client.close();
    exit(0);
  } catch (e) {
    if (e is SocketException) {
      print(jsonEncode({'status': 'error', 'message': 'Cannot connect to daemon. Start flowaved first.'}));
    } else {
      print(jsonEncode({'status': 'error', 'message': '$e'}));
    }
    exit(1);
  }
}

void main(List<String> args) {
  if (args.isEmpty || args.first == 'help' || args.first == '--help' || args.first == '-h') {
    _printUsage();
    return;
  }

  final command = args.first;
  final commandArgs = args.length > 1 ? args.sublist(1) : <String>[];

  final parser = ArgParser()
    ..addOption('baud', defaultsTo: '115200')
    ..addFlag('highfreq', defaultsTo: false)
    ..addFlag('log', defaultsTo: false)
    ..addFlag('static', defaultsTo: false)
    ..addOption('timeout', defaultsTo: '0')
    ..addOption('window', defaultsTo: '100')
    ..addOption('duration', defaultsTo: '4')
    ..addOption('width', defaultsTo: '80');

  ArgResults argResults;
  try {
    argResults = parser.parse(commandArgs);
  } catch (e) {
    print(jsonEncode({'status': 'error', 'message': 'Invalid arguments: $e'}));
    exit(1);
  }

  switch (command) {
    // ========== 连接管理 ==========
    case 'ping':
      _get('/ping');
      break;

    case 'list-ports':
      _get('/list-ports');
      break;

    case 'connect':
      final port = commandArgs.isNotEmpty ? commandArgs[0] : null;
      if (port == null) {
        print(jsonEncode({'status': 'error', 'message': 'Usage: connect <port> [--baud <rate>]'}));
        exit(1);
      }
      _post('/connect', {'port': port, 'baud': int.tryParse(argResults['baud']) ?? 115200});
      break;

    case 'disconnect':
      _post('/disconnect', {});
      break;

    case 'handshake':
      _post('/handshake', {});
      break;

    // ========== 变量操作 ==========
    case 'register':
      _handleRegister(commandArgs, argResults);
      break;

    case 'write':
      _handleWrite(commandArgs);
      break;

    case 'refresh':
      _handleRefresh(commandArgs);
      break;

    case 'refresh-all':
      _post('/refresh-all', {});
      break;

    case 'list-vars':
      _get('/list-vars');
      break;

    case 'save-static':
      if (commandArgs.isEmpty) {
        print(jsonEncode({'status': 'error', 'message': 'Usage: save-static <path>'}));
        exit(1);
      }
      _post('/save-static', {'path': commandArgs[0]});
      break;

    case 'load-static':
      if (commandArgs.isEmpty) {
        print(jsonEncode({'status': 'error', 'message': 'Usage: load-static <path>'}));
        exit(1);
      }
      _post('/load-static', {'path': commandArgs[0]});
      break;

    case 'write-all-static':
      _post('/write-all-static', {});
      break;

    case 'text':
      if (commandArgs.isEmpty) {
        print(jsonEncode({'status': 'error', 'message': 'Usage: text <message>'}));
        exit(1);
      }
      _post('/text', {'message': commandArgs.join(' ')});
      break;

    // ========== 监控 ==========
    case 'monitor':
      _handleMonitor(argResults);
      break;

    // ========== 统计分析 ==========
    case 'stats':
      _handleStats(commandArgs, argResults);
      break;

    case 'plot':
      _handlePlot(commandArgs, argResults);
      break;

    // ========== Demo ==========
    case 'demo':
      _handleDemo(commandArgs);
      break;

    case 'shutdown':
      _post('/shutdown', {});
      break;

    default:
      print(jsonEncode({'status': 'error', 'message': 'Unknown command: $command'}));
      _printUsage();
      exit(1);
  }
}

// ========== 命令处理 ==========

void _handleRegister(List<String> args, ArgResults opts) {
  if (args.length < 3) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: register <addr hex> <name> <type>'}));
    exit(1);
  }
  final addrStr = args[0];
  final name = args[1];
  final type = int.tryParse(args[2]);
  if (type == null || type < 0 || type > 6) {
    print(jsonEncode({'status': 'error', 'message': 'type must be 0-6'}));
    exit(1);
  }
  final addr = int.tryParse(addrStr.replaceFirst('0x', ''), radix: 16);
  if (addr == null) {
    print(jsonEncode({'status': 'error', 'message': 'Invalid address'}));
    exit(1);
  }
  _post('/register', {
    'addr': addr,
    'name': name,
    'type': type,
    'isHighFreq': opts['highfreq'] as bool,
    'isStatic': opts['static'] as bool,
  });
}

void _handleWrite(List<String> args) {
  if (args.length < 3) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: write <varId> <value> <type>'}));
    exit(1);
  }
  final varId = int.tryParse(args[0]);
  final type = int.tryParse(args[2]);
  if (varId == null || type == null) {
    print(jsonEncode({'status': 'error', 'message': 'Invalid varId or type'}));
    exit(1);
  }
  dynamic value;
  if (type == 6) {
    value = double.tryParse(args[1]) ?? 0.0;
  } else {
    value = int.tryParse(args[1]) ?? 0;
  }
  _post('/write', {'varId': varId, 'value': value, 'type': type});
}

void _handleRefresh(List<String> args) {
  if (args.isEmpty) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: refresh <varId>'}));
    exit(1);
  }
  final varId = int.tryParse(args[0]);
  if (varId == null) {
    print(jsonEncode({'status': 'error', 'message': 'Invalid varId'}));
    exit(1);
  }
  _post('/refresh', {'varId': varId});
}

void _handleMonitor(ArgResults opts) {
  final watchHighFreq = opts['highfreq'] as bool;
  final watchLog = opts['log'] as bool;
  final timeout = int.tryParse(opts['timeout']) ?? 0;

  if (!watchHighFreq && !watchLog) {
    print(jsonEncode({'status': 'error', 'message': 'Use --highfreq and/or --log'}));
    exit(1);
  }

  final query = <String, String>{};
  if (timeout > 0) query['timeout'] = timeout.toString();

  if (watchHighFreq && watchLog) {
    // Stream both concurrently
    Future.wait([
      _sseNoExit('/monitor/highfreq', query: query),
      _sseNoExit('/monitor/logs', query: query),
    ]);
    // Sleep until interrupted
    if (timeout > 0) {
      Future.delayed(Duration(seconds: timeout), () => exit(0));
    }
  } else if (watchHighFreq) {
    _sse('/monitor/highfreq', query: query);
  } else {
    _sse('/monitor/logs', query: query);
  }
}

Future<void> _sseNoExit(String path, {Map<String, String>? query}) async {
  final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);
  try {
    final client = http.Client();
    final request = http.Request('GET', uri);
    final streamedResponse = await client.send(request);
    final stream = streamedResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in stream) {
      if (line.startsWith('data: ')) {
        print(line.substring(6));
      }
    }
    client.close();
  } catch (e) {
    // ignore on parallel stream
  }
}

void _handleStats(List<String> args, ArgResults opts) {
  if (args.isEmpty) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: stats <varId>'}));
    exit(1);
  }
  final varId = int.tryParse(args[0]);
  if (varId == null) {
    print(jsonEncode({'status': 'error', 'message': 'Invalid varId'}));
    exit(1);
  }
  _get('/stats', query: {
    'varId': varId.toString(),
    'window': opts['window'],
    'duration': opts['duration'],
  });
}

void _handlePlot(List<String> args, ArgResults opts) {
  if (args.isEmpty) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: plot <varId>'}));
    exit(1);
  }
  final varId = int.tryParse(args[0]);
  if (varId == null) {
    print(jsonEncode({'status': 'error', 'message': 'Invalid varId'}));
    exit(1);
  }
  _get('/plot', query: {
    'varId': varId.toString(),
    'width': opts['width'],
    'duration': opts['duration'],
  });
}

void _handleDemo(List<String> args) {
  if (args.isEmpty || (args[0] != 'start' && args[0] != 'stop')) {
    print(jsonEncode({'status': 'error', 'message': 'Usage: demo start|stop'}));
    exit(1);
  }
  _post('/demo/${args[0]}', {});
}

void _printUsage() {
  print('flowave - Debug protocol CLI client');
  print('');
  print('Usage: flowave <command> [options]');
  print('');
  print('Connection:');
  print('  ping                  Check daemon connectivity');
  print('  list-ports            List available serial ports');
  print('  connect <port>        Connect to serial port (--baud <rate>)');
  print('  disconnect            Disconnect serial port');
  print('  handshake             Perform handshake with device');
  print('');
  print('Variables:');
  print('  register <addr> <name> <type>  Register a variable (--highfreq, --static)');
  print('  write <varId> <value> <type>   Write variable value');
  print('  refresh <varId>               Request static variable refresh');
  print('  refresh-all                   Refresh all static variables');
  print('  list-vars                     List all registered variables');
  print('  save-static <path>            Export static variables to JSON');
  print('  load-static <path>            Import static variables from JSON');
  print('  write-all-static              Write all static variables to device');
  print('  text <message>                Send text message to device');
  print('');
  print('Monitoring:');
  print('  monitor [--highfreq] [--log] [--timeout <sec>]  Monitor data streams');
  print('  stats <varId> [--window N] [--duration N]       Calculate statistics');
  print('  plot <varId> [--width N] [--duration N]         ASCII waveform plot');
  print('');
  print('Demo mode:');
  print('  demo start            Start demo data generation');
  print('  demo stop             Stop demo data generation');
  print('');
  print('Type values: 0=uint8 1=int8 2=uint16 3=int16 4=uint32 5=int32 6=float');
  print('');
  print('Prerequisite: flowaved daemon must be running on http://127.0.0.1:9876');
}
