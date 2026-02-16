import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/ble_bridge.dart';
import 'core/device_model.dart';
import 'core/threat_engine.dart';
import 'l10n/strings.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const StalkGuardApp());
}

class StalkGuardApp extends StatelessWidget {
  const StalkGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          elevation: 0,
        ),
        dividerColor: const Color(0xFF2A2A2A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00B3FF),
          secondary: Color(0xFFFF5252),
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final Map<String, DeviceModel> _deviceMap = {};
  List<DeviceModel> devices = [];

  final Set<String> _trusted = {};
  static const String _trustedKey = "trusted_ids_v1";

  String permStatus = S.waitingPermissions;

  // Notifications
  final FlutterLocalNotificationsPlugin _notifs = FlutterLocalNotificationsPlugin();
  static const String _alertChannelId = "stalkguard_alerts_v2";
  final Map<String, DateTime> _lastAlertAtById = {};
  static const Duration _alertCooldown = Duration(minutes: 2);

  // Color hysteresis: 0=blue, 1=orange, 2=red
  final Map<String, int> _colorStateById = {};

  // lifecycle cleanup
  Timer? _cleanupTimer;

  // scanning state
  bool _scanning = true;
  bool? _btOn;

  // debug
  bool _debugOpen = false;

  // motion
  bool _motionChecking = false;
  Map<String, dynamic>? _lastMotion;
  DateTime? _lastMotionAt;
  static const Duration _motionCooldown = Duration(minutes: 3);

  @override
  void initState() {
    super.initState();
    _init();
    _startCleanupTimer();
  }

  @override
  void dispose() {
    _cleanupTimer?.cancel();
    super.dispose();
  }

  void _startCleanupTimer() {
    _cleanupTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final now = DateTime.now();
      bool changed = false;

      _deviceMap.removeWhere((id, d) {
        final stale = now.difference(d.lastSeen).inSeconds > 60;
        if (stale) changed = true;
        return stale;
      });

      _colorStateById.removeWhere((id, _) => !_deviceMap.containsKey(id));
      _lastAlertAtById.removeWhere((_, t) => now.difference(t).inMinutes > 120);

      if (changed && mounted) {
        setState(_sortDevicesByRiskDesc);
      }
    });
  }

  Future<void> _init() async {
    await _loadTrusted();
    await _initNotifications();

    final ok = await _ensurePermissions();
    setState(() => permStatus = ok ? S.permissionsOk : S.permissionsMissing);

    if (ok) {
      BleBridge.startService();
      if (_scanning) BleBridge.startScan();
    } else {
      setState(() => _scanning = false);
    }

    BleBridge.listen(
      onDevice: (data) {
        final String id = (data["id"] ?? "").toString();
        if (id.isEmpty) return;

        final String name = (data["name"] ?? "Unknown").toString();
        final int rssi = (data["rssi"] is int)
            ? data["rssi"]
            : int.tryParse(data["rssi"].toString()) ?? -127;

        final now = DateTime.now();

        setState(() {
          if (_deviceMap.containsKey(id)) {
            final ex = _deviceMap[id]!;

            final newHist = List<int>.from(ex.rssiHistory);
            newHist.add(rssi);
            if (newHist.length > 20) newHist.removeAt(0);

            _deviceMap[id] = DeviceModel(
              id: ex.id,
              name: (ex.name == "Unknown" && name != "Unknown") ? name : ex.name,
              rssi: rssi,
              lastSeen: now,
              seenCount: ex.seenCount + 1,
              firstSeen: ex.firstSeen,
              rssiHistory: newHist,
            );
          } else {
            _deviceMap[id] = DeviceModel(
              id: id,
              name: name,
              rssi: rssi,
              lastSeen: now,
              seenCount: 1,
              rssiHistory: [rssi],
            );
          }

          _sortDevicesByRiskDesc();
        });

        final dev = _deviceMap[id]!;
        final trusted = _trusted.contains(id);
        final risk = trusted ? 0.0 : ThreatEngine.calculateRisk(dev);

        _colorStateById[id] = _nextColorState(id, risk, isTrusted: trusted);

        // risk dropped => clear notification + allow red to drop later
        if (risk < 50 && _lastAlertAtById.containsKey(id)) {
          unawaited(_clearAlert(dev));
        }

        _maybeAlert(dev, risk);
        _maybeRunMotionCheck(risk);
      },
      onBtState: (on) {
        if (!mounted) return;
        setState(() => _btOn = on);
      },
    );
  }

  void _sortDevicesByRiskDesc() {
    devices = _deviceMap.values.toList()
      ..sort((a, b) {
        final riskA = ThreatEngine.calculateRisk(a);
        final riskB = ThreatEngine.calculateRisk(b);
        return riskB.compareTo(riskA);
      });
  }

  Future<void> _initNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _notifs.initialize(initSettings);

    const channel = AndroidNotificationChannel(
      _alertChannelId,
      'StalkGuard Alerts',
      description: 'High risk BLE tracking alerts',
      importance: Importance.max,
    );

    final androidPlugin =
        _notifs.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(channel);
  }

  Future<void> _showAlert(DeviceModel d, double risk) async {
    const androidDetails = AndroidNotificationDetails(
      _alertChannelId,
      'StalkGuard Alerts',
      channelDescription: 'High risk BLE tracking alerts',
      importance: Importance.max,
      priority: Priority.high,
      icon: 'ic_stat_alarm',
      color: Color(0xFFFF0000),
    );

    const details = NotificationDetails(android: androidDetails);

    await _notifs.show(
      d.id.hashCode,
      "Suspicious Bluetooth device",
      "${d.name} | Risk ${risk.toInt()}% | RSSI(avg) ${d.avgRssi.toStringAsFixed(0)}",
      details,
    );
  }

  Future<void> _clearAlert(DeviceModel d) async {
    try {
      await _notifs.cancel(d.id.hashCode);
    } catch (_) {}
    _lastAlertAtById.remove(d.id);
  }

  void _maybeAlert(DeviceModel d, double risk) {
    if (_trusted.contains(d.id)) return;

    final now = DateTime.now();

    final ageSec = now.difference(d.firstSeen).inSeconds;
    if (ageSec < 120) return;
    if (d.seenCount < 12) return;
    if (d.rssiHistory.length < 10) return;
    final motionOk = (_lastMotion?["ok"] == true);
	final meters = motionOk ? (((_lastMotion?["meters"] as num?) ?? 0).toDouble()) : 0.0;
	final movingConfirmed = motionOk && meters >= 20.0;

	final rssiGate = movingConfirmed ? -90.0 : -78.0;
	if (d.avgRssi < rssiGate) return;


    if (!(risk >= 75 && movingConfirmed)) return;

    final last = _lastAlertAtById[d.id];
    if (last != null && now.difference(last) < _alertCooldown) return;

    _lastAlertAtById[d.id] = now;
    _showAlert(d, risk);
  }

  // Hysteresis:
  // BLUE -> ORANGE: risk >= 60
  // ORANGE -> BLUE: risk < 55
  // ORANGE -> RED:  risk >= 75
  // RED -> ORANGE:  risk < 65
  int _nextColorState(String id, double risk, {required bool isTrusted}) {
    if (isTrusted) return 0;

    final int cur = _colorStateById[id] ?? 0;

    if (cur == 2) return (risk < 65) ? 1 : 2;

    if (cur == 1) {
      if (risk >= 75) return 2;
      if (risk < 55) return 0;
      return 1;
    }

    return (risk >= 60) ? 1 : 0;
  }

  Color _colorForState(int s, {required bool trusted}) {
    if (trusted) return const Color(0xFF4CAF50);
    if (s == 2) return const Color(0xFFFF3B30); // red
    if (s == 1) return const Color(0xFFFF9800); // orange
    return const Color(0xFF90A4AE); // safe
  }

  bool _showAlertBadgeNow(String id) {
    final last = _lastAlertAtById[id];
    if (last == null) return false;
    return DateTime.now().difference(last) < const Duration(minutes: 10);
  }

  Future<bool> _ensurePermissions() async {
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    final loc = await Permission.locationWhenInUse.request();
    await Permission.notification.request();
    return scan.isGranted && connect.isGranted && loc.isGranted;
  }

  Future<void> _loadTrusted() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_trustedKey) ?? [];
    _trusted
      ..clear()
      ..addAll(list);
  }

  Future<void> _saveTrusted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_trustedKey, _trusted.toList());
  }

  Future<void> _toggleTrusted(String id) async {
    setState(() {
      if (_trusted.contains(id)) {
        _trusted.remove(id);
      } else {
        _trusted.add(id);
      }
    });
    await _saveTrusted();
  }

  void _toggleScan() {
    setState(() => _scanning = !_scanning);
    if (_scanning) {
      BleBridge.startScan();
    } else {
      BleBridge.stopScan();
    }
  }

  bool _canRunMotionNow() {
    final last = _lastMotionAt;
    if (last == null) return true;
    return DateTime.now().difference(last) > _motionCooldown;
  }

  void _maybeRunMotionCheck(double risk) {
    if (!_scanning) return;
    if (_btOn != true) return;
    if (_motionChecking) return;
    if (!_canRunMotionNow()) return;
    if (risk < 75) return;

    setState(() {
      _motionChecking = true;
      _lastMotionAt = DateTime.now();
    });

    unawaited(() async {
      try {
        final res = await BleBridge.motionCheck(seconds: 45);
        if (!mounted) return;
        setState(() {
          _lastMotion = Map<String, dynamic>.from(res);
          _motionChecking = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _lastMotion = {"ok": false, "reason": "EXCEPTION"};
          _motionChecking = false;
        });
      }
    }());
  }

  Widget _buildDebugPanel() {
    final total = devices.length;
    final alerts = _lastAlertAtById.length;
    final high = devices.where((d) => ThreatEngine.calculateRisk(d) >= 75).length;

    final sorted = List<DeviceModel>.from(devices)
      ..sort((a, b) => ThreatEngine.calculateRisk(b).compareTo(ThreatEngine.calculateRisk(a)));
    final top = sorted.isNotEmpty ? sorted.first : null;

    final btText = (_btOn == null) ? "Bluetooth ?" : (_btOn! ? "Bluetooth ON" : "Bluetooth OFF");

    String motionLine;
    if (_motionChecking) {
      motionLine = "Motion: checking...";
    } else if (_lastMotion == null) {
      motionLine = "Motion: -";
    } else if (_lastMotion!["ok"] == true) {
      final meters = ((_lastMotion!["meters"] as num?) ?? 0).toDouble();
      final speedMps = ((_lastMotion!["speed_mps"] as num?) ?? 0).toDouble();
      final kmh = speedMps * 3.6;

      final fixes = _lastMotion!["fixes"];
      final accFirst = _lastMotion!["acc_first"];
      final accLast = _lastMotion!["acc_last"];

      String extra = "";
      if (fixes != null) extra += " • fixes:$fixes";
      if (accFirst is num && accLast is num) {
        extra += " • acc:${accFirst.toStringAsFixed(0)}/${accLast.toStringAsFixed(0)}";
      }

      motionLine = "Motion: ${meters.toStringAsFixed(1)}m • ${kmh.toStringAsFixed(1)} km/h$extra";
    } else {
      motionLine = "Motion: ${_lastMotion!["reason"]}";
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
  mainAxisAlignment: MainAxisAlignment.spaceBetween,
  children: [
    Text("DEBUG • $btText", style: const TextStyle(fontWeight: FontWeight.w700)),
    TextButton(
      onPressed: _motionChecking
          ? null
          : () async {
              setState(() {
                _motionChecking = true;
                _lastMotionAt = DateTime.now();
              });

              try {
                final res = await BleBridge.motionCheck(seconds: 45);
                if (!mounted) return;
                setState(() {
                  _lastMotion = Map<String, dynamic>.from(res);
                  _motionChecking = false;
                });
              } catch (_) {
                if (!mounted) return;
                setState(() {
                  _lastMotion = {"ok": false, "reason": "EXCEPTION"};
                  _motionChecking = false;
                });
              }
            },
      child: const Text("MOTION TEST"),
    ),
  ],
),

          const SizedBox(height: 8),
          Text("Devices: $total  •  High(>=75): $high  •  Alerts: $alerts",
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          Text(motionLine, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          if (top != null) ...[
            const Text("Top Risk Device",
                style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text("Name: ${top.name}", style: const TextStyle(color: Colors.white60)),
            Text("ID: ${top.id}", style: const TextStyle(color: Colors.white60, fontSize: 12)),
            Text("Risk: ${ThreatEngine.calculateRisk(top).toInt()}%",
                style: const TextStyle(color: Colors.white60)),
            Text("Avg RSSI: ${top.avgRssi.toStringAsFixed(1)}",
                style: const TextStyle(color: Colors.white60)),
            Text("Variance: ${top.rssiVariance.toStringAsFixed(2)}",
                style: const TextStyle(color: Colors.white60)),
            Text("Seen: ${top.seenCount}", style: const TextStyle(color: Colors.white60)),
            Text("Age: ${DateTime.now().difference(top.firstSeen).inSeconds}s",
                style: const TextStyle(color: Colors.white60)),
          ] else ...[
            const Text("No devices", style: TextStyle(color: Colors.white60)),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scanLine = _scanning
        ? ((_btOn == false) ? S.scanWaitingBtOff : S.scanActive)
        : S.scanPassive;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text(
          "StalkGuard",
          style: TextStyle(
            color: Color(0xFFB388FF),
            fontWeight: FontWeight.w800,
            letterSpacing: 1.3,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(_debugOpen ? Icons.bug_report : Icons.bug_report_outlined),
            onPressed: () => setState(() => _debugOpen = !_debugOpen),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: const Color(0xFF1E1E1E),
            child: ListTile(
              title: Text(permStatus, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(scanLine),
                  Text(
                    _btOn == null ? "Bluetooth: ?" : (_btOn! ? "Bluetooth: ON" : "Bluetooth: OFF"),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _scanning ? const Color(0xFFFF3B30) : const Color(0xFF00B3FF),
                    ),
                    onPressed: _toggleScan,
                    child: Text(_scanning ? S.stop : S.start),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () async {
                      final ok = await _ensurePermissions();
                      setState(() => permStatus = ok ? S.permissionsOk : S.permissionsMissing);
                      if (ok && _scanning) BleBridge.startScan();
                    },
                    child: const Text(S.refreshPermissions),
                  ),
                ],
              ),
            ),
          ),

          if (_debugOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _buildDebugPanel(),
            ),

          const Divider(height: 1),

          Expanded(
            child: devices.isEmpty
                ? const Center(child: Text(S.noDevices))
                : ListView.builder(
                    itemCount: devices.length,
                    itemBuilder: (context, index) {
                      final d = devices[index];
                      final bool isTrusted = _trusted.contains(d.id);

                      final riskRaw = ThreatEngine.calculateRisk(d);
                      final risk = isTrusted ? 0.0 : riskRaw;

                      final state = _colorStateById[d.id] ?? 0;
                      final c = _colorForState(state, trusted: isTrusted);

                      final showAlertBadge = _showAlertBadgeNow(d.id);

                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1A1A),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: c.withOpacity(0.25), width: 1),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Risk badge (left)
                            Container(
                              width: 64,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                              decoration: BoxDecoration(
                                color: c.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    "${risk.toInt()}%",
                                    style: TextStyle(
                                      color: c,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    S.risk,
                                    style: TextStyle(
                                      color: c.withOpacity(0.85),
                                      fontSize: 11,
                                      letterSpacing: 1.0,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),

                            // Right details
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    d.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: c,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    "RSSI ${d.rssi}  •  Seen ${d.seenCount}  •  Var ${d.rssiVariance.toStringAsFixed(1)}",
                                    style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(d.id, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                                  if (isTrusted) ...[
                                    const SizedBox(height: 6),
                                    const Text(
                                      S.trusted,
                                      style: TextStyle(
                                        color: Color(0xFF4CAF50),
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                  if (showAlertBadge) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      S.alertRecent,
                                      style: TextStyle(
                                        color: c,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),

                            IconButton(
                              icon: Icon(
                                isTrusted ? Icons.verified_user : Icons.shield_outlined,
                                color: isTrusted ? const Color(0xFF4CAF50) : Colors.white70,
                              ),
                              onPressed: () => _toggleTrusted(d.id),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
