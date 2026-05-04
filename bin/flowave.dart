import 'dart:convert';
import 'package:args/args.dart';
import 'package:ui_widget_test/core/services/device_core.dart';

ArgParser _createParser() {
  return ArgParser()
    ..addOption('port', help: 'Serial port name')
    ..addOption('baud', help: 'Baud rate', defaultsTo: '115200');
}

Future<void> runFlowave(List<String> args) async {
  final parser = _createParser();
  ArgResults argResults;

  if (args.isEmpty) {
    _printUsage(parser);
    return;
  }

  final command = args.first;
  final commandArgs = args.length > 1 ? args.sublist(1) : <String>[];

  try {
    argResults = parser.parse(commandArgs);
  } catch (e) {
    print(jsonEncode({
      'status': 'error',
      'message': 'Invalid arguments: $e',
    }));
    return;
  }

  final portOption = argResults['port'] as String?;
  final baudOption = int.tryParse(argResults['baud'] as String? ?? '115200') ?? 115200;

  final core = DeviceCore();

  switch (command) {
    case 'list-ports':
      core.refreshPorts();
      print(jsonEncode(core.availablePorts));
      return;

    case 'connect':
      if (portOption == null) {
        print(jsonEncode({
          'status': 'error',
          'message': 'Missing --port option',
        }));
        return;
      }

      final success = await core.connect(portOption, baudOption);
      if (success) {
        print(jsonEncode({'status': 'connected'}));
      } else {
        print(jsonEncode({
          'status': 'error',
          'message': 'Failed to connect',
        }));
      }
      return;

    case 'disconnect':
      core.disconnect();
      print(jsonEncode({'status': 'disconnected'}));
      return;

    case 'handshake':
      if (!core.isConnected) {
        print(jsonEncode({
          'status': 'error',
          'message': 'Not connected',
        }));
        return;
      }

      final success = await core.shakeWithMCU();
      print(jsonEncode({'success': success}));
      return;

    case 'help':
    case '--help':
    case '-h':
      _printUsage(parser);
      return;

    default:
      print(jsonEncode({
        'status': 'error',
        'message': 'Unknown command: $command',
      }));
      return;
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
  print('Options:');
  print('  --port <name>        Serial port name');
  print('  --baud <rate>        Baud rate (default: 115200)');
}

void main(List<String> args) {
  runFlowave(args);
}