import 'dart:math';
import 'device_model.dart';

class ThreatEngine {
  static double calculateRisk(DeviceModel d) {
    final timeScore = _timeScore(d.durationMinutes); // 0..30
    final seenScore = _seenScore(d.seenCount);       // 0..20
    final proximityScore = _proximityScore(d.avgRssi); // 0..30
    final stabilityScore = _stabilityScore(d.rssiVariance, d.rssiHistory.length); // 0..20

    final risk = timeScore + seenScore + proximityScore + stabilityScore;
    return risk.clamp(0, 100).toDouble();
  }

  /// 0..30 (30 dk'da tavan)
  static double _timeScore(int minutes) {
    final m = max(0, minutes);
    final x = min(m / 30.0, 1.0); // 0..1
    final curved = 1 - pow(1 - x, 2); // ease-out
    return 30.0 * curved;
  }

  /// 0..20
  /// Seen, "cihaz sürekli karşına çıkıyor" sinyali.
  /// 50 seen -> ~8, 150 -> ~14, 300+ -> 20
  static double _seenScore(int seen) {
    final s = max(0, seen);
    if (s >= 300) return 20;
    if (s >= 150) return 14;
    if (s >= 50) return 8;
    if (s >= 20) return 4;
    return 0;
  }

  /// 0..30
  static double _proximityScore(double avgRssi) {
    final r = avgRssi;
    // Daha agresif eşikler
    if (r >= -55) return 30;
    if (r >= -65) return 24;
    if (r >= -72) return 16;
    if (r >= -80) return 8;
    return 0;
  }

  /// 0..20
  /// variance düşük => stabil => risk artar
  static double _stabilityScore(double variance, int historyLen) {
    if (historyLen < 8) return 0; // erken karar verme

    if (variance <= 2) return 20;   // çok stabil
    if (variance <= 6) return 16;
    if (variance <= 12) return 10;
    if (variance <= 20) return 5;
    return 0;
  }
}
