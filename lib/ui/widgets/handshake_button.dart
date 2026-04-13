import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/device_controller.dart';

class HandshakeButton extends StatelessWidget {
  const HandshakeButton({super.key});

  @override
  Widget build(BuildContext context) {
    final isConnected = context.select<DeviceController, bool>((c) => c.isConnected);
    return ElevatedButton.icon(
      icon: const Icon(Icons.back_hand, size: 18),
      label: const Text("握手"),
      onPressed: isConnected
          ? () async {
              bool success = await context.read<DeviceController>().shakeWithMCU();
              if (context.mounted) {
                
              }
            }
          : null,
    );
  }
}
