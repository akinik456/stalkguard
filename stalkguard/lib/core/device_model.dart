class DeviceModel {
  final String id;
  final String name;

  final DateTime firstSeen;
  final DateTime lastSeen;

  final int rssi;
  final int seenCount;

  // Son N RSSI değeri
  final List<int> rssiHistory;

  DeviceModel({
    required this.id,
    required this.name,
    required this.rssi,
    required this.lastSeen,
    required this.seenCount,
    DateTime? firstSeen,
    List<int>? rssiHistory,
  })  : firstSeen = firstSeen ?? DateTime.now(),
        rssiHistory = rssiHistory ?? [rssi];

  int get durationMinutes => DateTime.now().difference(firstSeen).inMinutes;

  double get avgRssi {
    if (rssiHistory.isEmpty) return rssi.toDouble();
    final sum = rssiHistory.reduce((a, b) => a + b);
    return sum / rssiHistory.length;
  }

  double get rssiVariance {
    if (rssiHistory.length < 2) return 9999;
    final avg = avgRssi;
    double s = 0;
    for (final v in rssiHistory) {
      final d = (v - avg);
      s += d * d;
    }
    return s / rssiHistory.length;
  }
}
