import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'device_core.dart';
import '../models/log_entry.dart';
import '../../debug_protocol.dart';

class HttpApi {
  final DeviceCore _core;
  Future _lock = Future.value();

  HttpApi(this._core);

  Future<T> _synchronized<T>(Future<T> Function() fn) {
    final prev = _lock;
    final next = Completer<void>();
    _lock = next.future;
    return prev.then((_) async {
      try {
        return await fn();
      } finally {
        next.complete();
      }
    });
  }

  Future<void> handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      final method = request.method;
      await _route(method, path, request);
    } catch (e) {
      try {
        _respondJson(request.response, 500, {'status': 'error', 'message': '$e'});
      } catch (_) {}
    }
  }

  Future<void> _route(String method, String path, HttpRequest request) async {
    switch ('$method $path') {
      case 'GET /ping':
        _respondJson(request.response, 200, {'status': 'ok', 'message': 'pong'});
        break;
      case 'GET /list-ports':
        _handleListPorts(request);
        break;
      case 'POST /connect':
        await _synchronized(() => _handleConnect(request));
        break;
      case 'POST /disconnect':
        await _synchronized(() => _handleDisconnect(request));
        break;
      case 'POST /handshake':
        await _synchronized(() => _handleHandshake(request));
        break;
      case 'POST /register':
        await _synchronized(() => _handleRegister(request));
        break;
      case 'POST /write':
        await _synchronized(() => _handleWrite(request));
        break;
      case 'POST /refresh':
        await _synchronized(() => _handleRefresh(request));
        break;
      case 'POST /refresh-all':
        await _synchronized(() => _handleRefreshAll(request));
        break;
      case 'GET /list-vars':
        _handleListVars(request);
        break;
      case 'POST /save-static':
        await _synchronized(() => _handleSaveStatic(request));
        break;
      case 'POST /load-static':
        await _synchronized(() => _handleLoadStatic(request));
        break;
      case 'POST /write-all-static':
        await _synchronized(() => _handleWriteAllStatic(request));
        break;
      case 'POST /text':
        await _synchronized(() => _handleText(request));
        break;
      case 'GET /monitor/highfreq':
        await _handleSseHighFreq(request);
        break;
      case 'GET /monitor/logs':
        await _handleSseLogs(request);
        break;
      case 'GET /stats':
        await _handleStats(request);
        break;
      case 'GET /plot':
        await _handlePlot(request);
        break;
      case 'POST /demo/start':
        await _synchronized(() => _handleDemoStart(request));
        break;
      case 'POST /demo/stop':
        await _synchronized(() => _handleDemoStop(request));
        break;
      case 'POST /shutdown':
        await _handleShutdown(request);
        break;
      default:
        _respondJson(request.response, 404, {'status': 'error', 'message': 'Not found: $method $path'});
    }
  }

  // ========== 端点实现 ==========

  void _handleListPorts(HttpRequest request) {
    _core.refreshPorts();
    _respondJson(request.response, 200, {'status': 'ok', 'ports': _core.availablePorts});
  }

  Future<void> _handleConnect(HttpRequest request) async {
    final body = await _readBody(request);
    final port = body['port'] as String?;
    final baud = (body['baud'] as int?) ?? 115200;
    if (port == null) {
      _respondJson(request.response, 400, {'status': 'error', 'message': 'Missing port'});
      return;
    }
    final ok = await _core.connect(port, baud);
    _respondJson(request.response, ok ? 200 : 500, {'status': ok ? 'connected' : 'error', 'message': ok ? null : 'Failed to connect'});
  }

  Future<void> _handleDisconnect(HttpRequest request) async {
    _core.disconnect();
    _respondJson(request.response, 200, {'status': 'disconnected'});
  }

  Future<void> _handleHandshake(HttpRequest request) async {
    if (!_core.isConnected) {
      _respondJson(request.response, 400, {'status': 'error', 'message': 'Not connected'});
      return;
    }
    final ok = await _core.shakeWithMCU();
    _respondJson(request.response, 200, {'status': 'ok', 'success': ok});
  }

  Future<void> _handleRegister(HttpRequest request) async {
    final body = await _readBody(request);
    final addr = body['addr'] as int?;
    final name = body['name'] as String?;
    final type = body['type'] as int?;
    final isHighFreq = (body['isHighFreq'] as bool?) ?? false;
    final isStatic = (body['isStatic'] as bool?) ?? false;
    if (addr == null || name == null || type == null) {
      _respondJson(request.response, 400, {'status': 'error', 'message': 'Missing addr/name/type'});
      return;
    }
    _core.sendData(DebugProtocol.packRegisterCmd(addr, name, type, isHighFreq: isHighFreq, isStatic: isStatic));
    _respondJson(request.response, 200, {'status': 'ok', 'addr': '0x${addr.toRadixString(16).toUpperCase()}', 'name': name, 'type': type, 'isHighFreq': isHighFreq, 'isStatic': isStatic});
  }

  Future<void> _handleWrite(HttpRequest request) async {
    final body = await _readBody(request);
    final varId = body['varId'] as int?;
    final value = body['value'];
    final type = body['type'] as int?;
    if (varId == null || value == null || type == null) {
      _respondJson(request.response, 400, {'status': 'error', 'message': 'Missing varId/value/type'});
      return;
    }
    final varLen = _getVarLength(type);
    _core.sendData(DebugProtocol.packWriteCmd(varId, varLen, value, type));
    _respondJson(request.response, 200, {'status': 'ok', 'varId': varId, 'value': value, 'type': type});
  }

  Future<void> _handleRefresh(HttpRequest request) async {
    final body = await _readBody(request);
    final varId = body['varId'] as int?;
    if (varId == null) {
      _respondJson(request.response, 400, {'status': 'error', 'message': 'Missing varId'});
      return;
    }
    _core.requestStaticRefresh(varId);
    _respondJson(request.response, 200, {'status': 'ok', 'varId': varId});
  }

  Future<void> _handleRefreshAll(HttpRequest request) async {
    final staticVars = _core.registry.values.where((v) => v.isStatic).toList();
    for (final v in staticVars) {
      _core.requestStaticRefresh(v.id);
    }
    _respondJson(request.response, 200, {'status': 'ok', 'count': staticVars.length});
  }

  void _handleListVars(HttpRequest request) {
    final vars = _core.registry.values.map((v) => {
      'id': v.id,
      'name': v.name,
      'type': v.type,
      'addr': '0x${v.addr.toRadixString(16).toUpperCase()}',
      'value': v.value,
      'isHighFreq': v.isHighFreq,
      'isStatic': v.isStatic,
    }).toList();
    _respondJson(request.response, 200, vars);
  }

  Future<void> _handleSaveStatic(HttpRequest request) async {
    final body = await _readBody(request);
    final path = body['path'] as String?;
    if (path == null) {
      _respondJson(request.response, 400, {'status': 'error', 'message': 'Missing path'});
      return;
    }
    try {
      await _core.saveStaticVarsToJson(path);
      _respondJson(request.response, 200, {'status': 'ok', 'path': path});
    } catch (e) {
      _respondJson(request.response, 500, {'status': 'error', 'message': '$e'});
    }
  }

  Future<void> _handleLoadStatic(HttpRequest request) async {
    final body = await _readBody(request);
    final path = body['path'] as String?;
    if (path == null) {
      _respondJson(request.response, 400, {'status': 'error', 'message': 'Missing path'});
      return;
    }
    try {
      final count = await _core.loadStaticVarsFromJson(path);
      _respondJson(request.response, 200, {'status': 'ok', 'count': count, 'path': path});
    } catch (e) {
      _respondJson(request.response, 500, {'status': 'error', 'message': '$e'});
    }
  }

  Future<void> _handleWriteAllStatic(HttpRequest request) async {
    try {
      await _core.writeAllStaticVarsToDevice();
      _respondJson(request.response, 200, {'status': 'ok'});
    } catch (e) {
      _respondJson(request.response, 500, {'status': 'error', 'message': '$e'});
    }
  }

  Future<void> _handleText(HttpRequest request) async {
    final body = await _readBody(request);
    final message = body['message'] as String?;
    if (message == null) {
      _respondJson(request.response, 400, {'status': 'error', 'message': 'Missing message'});
      return;
    }
    _core.sendData(DebugProtocol.packTextCmd(message));
    _respondJson(request.response, 200, {'status': 'ok'});
  }

  Future<void> _handleDemoStart(HttpRequest request) async {
    if (!_core.demoModeActive) {
      _core.toggleDemoMode();
    }
    _respondJson(request.response, 200, {'status': 'ok', 'demoModeActive': _core.demoModeActive});
  }

  Future<void> _handleDemoStop(HttpRequest request) async {
    if (_core.demoModeActive) {
      _core.toggleDemoMode();
    }
    _respondJson(request.response, 200, {'status': 'ok', 'demoModeActive': _core.demoModeActive});
  }

  Future<void> _handleShutdown(HttpRequest request) async {
    _respondJson(request.response, 200, {'status': 'ok', 'message': 'shutting down'});
    await request.response.close();
    _core.dispose();
    exit(0);
  }

  // ========== SSE 端点 ==========

  Future<void> _handleSseHighFreq(HttpRequest request) async {
    final timeout = int.tryParse(request.uri.queryParameters['timeout'] ?? '0') ?? 0;
    final response = request.response;
    response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
    response.headers.set('Cache-Control', 'no-cache');
    response.headers.set('Connection', 'keep-alive');
    response.headers.set('Access-Control-Allow-Origin', '*');

    late final StreamSubscription<MapEntry<int, double>> sub;
    sub = _core.highFreqStream.listen((entry) {
      try {
        response.write('data: ${jsonEncode({'type': 'highfreq', 'varId': entry.key, 'value': entry.value, 'timestamp': DateTime.now().toIso8601String()})}\n\n');
      } catch (_) {
        sub.cancel();
      }
    });

    Timer? timeoutTimer;
    if (timeout > 0) {
      timeoutTimer = Timer(Duration(seconds: timeout), () {
        sub.cancel();
      });
    }

    await response.done;
    sub.cancel();
    timeoutTimer?.cancel();
  }

  Future<void> _handleSseLogs(HttpRequest request) async {
    final timeout = int.tryParse(request.uri.queryParameters['timeout'] ?? '0') ?? 0;
    final response = request.response;
    response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
    response.headers.set('Cache-Control', 'no-cache');
    response.headers.set('Connection', 'keep-alive');
    response.headers.set('Access-Control-Allow-Origin', '*');

    late final StreamSubscription<LogEntry> sub;
    sub = _core.logStream.listen((entry) {
      try {
        response.write('data: ${jsonEncode({'type': 'log', 'content': entry.content, 'logType': entry.type.name, 'timestamp': entry.timestamp.toIso8601String()})}\n\n');
      } catch (_) {
        sub.cancel();
      }
    });

    Timer? timeoutTimer;
    if (timeout > 0) {
      timeoutTimer = Timer(Duration(seconds: timeout), () {
        sub.cancel();
      });
    }

    await response.done;
    sub.cancel();
    timeoutTimer?.cancel();
  }

  // ========== 统计分析 ==========

  Future<void> _handleStats(HttpRequest request) async {
    final varId = int.tryParse(request.uri.queryParameters['varId'] ?? '');
    final windowSize = int.tryParse(request.uri.queryParameters['window'] ?? '100') ?? 100;
    final duration = int.tryParse(request.uri.queryParameters['duration'] ?? '4') ?? 4;
    if (varId == null) {
      _respondJson(request.response, 400, {'status': 'error', 'message': 'Missing varId'});
      return;
    }

    final values = <double>[];
    final sub = _core.highFreqStream.listen((entry) {
      if (entry.key == varId) {
        values.add(entry.value);
      }
    });

    await Future.delayed(Duration(seconds: duration));
    sub.cancel();

    if (values.isEmpty) {
      final v = _core.registry[varId];
      if (v != null) {
        _respondJson(request.response, 200, {'status': 'ok', 'varId': varId, 'value': v.value, 'note': 'static value from registry'});
      } else {
        _respondJson(request.response, 200, {'status': 'error', 'message': 'No data collected'});
      }
      return;
    }

    final recent = values.length > windowSize ? values.sublist(values.length - windowSize) : values;
    final stats = _calculateStats(recent);
    _respondJson(request.response, 200, {
      'status': 'ok',
      'varId': varId,
      'count': recent.length,
      'min': stats['min'],
      'max': stats['max'],
      'mean': stats['mean'],
      'std': stats['std'],
      'trend': stats['trend'],
    });
  }

  Future<void> _handlePlot(HttpRequest request) async {
    final varId = int.tryParse(request.uri.queryParameters['varId'] ?? '');
    final width = int.tryParse(request.uri.queryParameters['width'] ?? '80') ?? 80;
    final duration = int.tryParse(request.uri.queryParameters['duration'] ?? '4') ?? 4;
    if (varId == null) {
      _respondJson(request.response, 400, {'status': 'error', 'message': 'Missing varId'});
      return;
    }

    final values = <double>[];
    final sub = _core.highFreqStream.listen((entry) {
      if (entry.key == varId) {
        values.add(entry.value);
      }
    });

    await Future.delayed(Duration(seconds: duration));
    sub.cancel();

    if (values.isEmpty) {
      _respondJson(request.response, 200, {'status': 'error', 'message': 'No data collected'});
      return;
    }

    final recent = values.length > width ? values.sublist(values.length - width) : values;
    final stats = _calculateStats(recent);

    // Render ASCII plot as text
    final plotStr = _renderAsciiPlot(recent, stats);
    _respondJson(request.response, 200, {
      'plot': plotStr,
      'min': stats['min'],
      'max': stats['max'],
      'avg': stats['mean'],
    });
  }

  // ========== 辅助函数 ==========

  void _respondJson(HttpResponse response, int status, dynamic data) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    response.close();
  }

  Future<Map<String, dynamic>> _readBody(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    if (body.isEmpty) return {};
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

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

    double varSum = 0.0;
    for (final v in data) {
      final diff = v - mean;
      varSum += diff * diff;
    }
    final std = sqrt(varSum / data.length);

    double trend = 0.0;
    if (data.length > 1) {
      double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
      for (int i = 0; i < data.length; i++) {
        sumX += i.toDouble();
        sumY += data[i];
        sumXY += i * data[i];
        sumX2 += i * i.toDouble();
      }
      final denom = data.length * sumX2 - sumX * sumX;
      if (denom != 0) {
        trend = (data.length * sumXY - sumX * sumY) / denom;
      }
    }

    return {'min': min, 'max': max, 'mean': mean, 'std': std, 'trend': trend};
  }

  String _renderAsciiPlot(List<double> data, Map<String, double> stats) {
    final min = stats['min']!;
    final max = stats['max']!;
    final range = max - min;
    if (range == 0) {
      return '|${'─' * 78}| ${min.toStringAsFixed(2)} (flat line)';
    }

    const plotWidth = 78;
    const plotHeight = 10;
    final lines = List.generate(plotHeight, (_) => List.filled(plotWidth, ' '));

    for (int i = 0; i < data.length; i++) {
      final x = (i * plotWidth / data.length).clamp(0, plotWidth - 1).toInt();
      final y = ((max - data[i]) / range * (plotHeight - 1)).clamp(0, plotHeight - 1).toInt();
      lines[y][x] = '●';
    }

    final buf = StringBuffer();
    for (final line in lines) {
      buf.writeln('|${line.join('')}|');
    }
    return buf.toString();
  }
}
