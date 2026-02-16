import 'package:flutter/services.dart';

class BleBridge {
  static const MethodChannel _channel = MethodChannel('stalkguard_ble');

  static void startService() {
    _channel.invokeMethod("startService");
  }

  static void startScan() {
    _channel.invokeMethod("startScan");
  }

  static void stopScan() {
    _channel.invokeMethod("stopScan");
  }

  static Future<Map<dynamic, dynamic>> motionCheck({int seconds = 45}) async {
    final res = await _channel.invokeMethod("motionCheck", {"seconds": seconds});
    return (res as Map<dynamic, dynamic>);
  }

  static void listen({
    required Function(dynamic data) onDevice,
    Function(bool on)? onBtState,
  }) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == "onDevice") {
        onDevice(call.arguments);
      } else if (call.method == "onBtState") {
        final args = call.arguments as dynamic;
        final bool on = args != null && args["on"] == true;
        onBtState?.call(on);
      }
    });
  }
}
