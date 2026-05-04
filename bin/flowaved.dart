import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:ui_widget_test/core/services/device_core.dart';
import 'package:ui_widget_test/core/services/http_api.dart';

void main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port', help: 'Serial port name to connect on startup')
    ..addOption('baud', defaultsTo: '115200', help: 'Baud rate (default: 115200)')
    ..addFlag('help', abbr: 'h', help: 'Show usage', negatable: false);
  final results = parser.parse(args);

  if (results['help'] as bool) {
    _printUsage();
    exit(0);
  }

  final portName = results['port'] as String?;
  final core = DeviceCore();

  if (portName != null) {
    final ok = await core.connect(portName, int.parse(results['baud']));
    if (!ok) {
      print(jsonEncode({'status': 'error', 'message': 'Failed to connect to $portName'}));
      exit(1);
    }
    print(jsonEncode({'status': 'connected', 'port': portName}));
  }

  final api = HttpApi(core);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 9876);
  print(jsonEncode({'status': 'daemon_started', 'port': 9876, 'serial': portName}));

  ProcessSignal.sigint.watch().first.then((_) async {
    print(jsonEncode({'status': 'daemon_stopped'}));
    core.dispose();
    await server.close(force: true);
    exit(0);
  });

  await for (HttpRequest request in server) {
    api.handleRequest(request);
  }
}

void _printUsage() {
  print('flowaved - Debug protocol daemon');
  print('');
  print('Usage: flowaved [--port <serial_port>] [--baud <rate>]');
  print('');
  print('Options:');
  print('  --port <name>   Serial port to connect on startup (e.g. COM3)');
  print('  --baud <rate>   Baud rate (default: 115200)');
  print('  -h, --help      Show this help');
  print('');
  print('The daemon listens on http://127.0.0.1:9876');
  print('Use flowave CLI to send commands to the daemon.');
}
