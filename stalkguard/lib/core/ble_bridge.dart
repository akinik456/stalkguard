import 'package:flutter/services.dart';

class BleBridge {
  static const MethodChannel _channel = MethodChannel('stalkguard_ble');

  static void startService() {
    _channel.invokeMethod("startService");
  }
  
  static void startScan() {
  _channel.invokeMethod("startScan");
}

static Future<void> notify(String title, String body) async {
  await _channel.invokeMethod("notify", {
    "title": title,
    "body": body,
  });
}



  static void listen(Function(dynamic) onDevice) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == "onDevice") {
        onDevice(call.arguments);
      }
    });
  }
}
