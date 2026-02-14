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

  static void listen(Function(dynamic) onDevice) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == "onDevice") {
        onDevice(call.arguments);
      }
    });
  }
}
