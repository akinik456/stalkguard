import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'core/ble_bridge.dart';
import 'core/device_model.dart';
import 'core/threat_engine.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const StalkGuardApp());
}

class StalkGuardApp extends StatelessWidget {
  const StalkGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HomePage(),
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

  String permStatus = "İzin bekleniyor...";

  // Notifications
  final FlutterLocalNotificationsPlugin _notifs = FlutterLocalNotificationsPlugin();
  static const String _alertChannelId = "stalkguard_alerts_v2";
  final Map<String, DateTime> _lastAlertAtById = {};
  static const Duration _alertCooldown = Duration(minutes: 2); // test için hızlı

  Timer? _cleanupTimer;

  bool _scanning = true; // kurulumdan sonra default tarasın

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

      _deviceMap.removeWhere((_, d) {
        final stale = now.difference(d.lastSeen).inSeconds > 60; // 1 dk
        if (stale) changed = true
        ;
        return stale;
      });

      if (changed && mounted) {
        setState(() {
          _sortDevicesByRiskDesc();
        });
      }
    });
  }

  Future<void> _initNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    // senin sürüm: initialize positional
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

  void _sortDevicesByRiskDesc() {
    devices = _deviceMap.values.toList()
      ..sort((a, b) {
        final riskA = ThreatEngine.calculateRisk(a);
        final riskB = ThreatEngine.calculateRisk(b);
        return riskB.compareTo(riskA);
      });
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

    // senin sürüm: show 4 positional
    await _notifs.show(
      d.id.hashCode,
      "StalkGuard: Şüpheli cihaz",
      "${d.name} | Risk: ${risk.toInt()}% | RSSI(avg): ${d.avgRssi.toStringAsFixed(0)}",
      details,
    );
  }

  void _maybeAlert(DeviceModel d, double risk) {
    if (_trusted.contains(d.id)) return;

    final now = DateTime.now();

    // hızlı test: 2 dk beraberlik
    final ageSec = now.difference(d.firstSeen).inSeconds;
    if (ageSec < 120) return;

    if (d.seenCount < 12) return;
    if (d.rssiHistory.length < 10) return;

    if (d.avgRssi < -78) return;

    if (risk < 75) return;

    final last = _lastAlertAtById[d.id];
    if (last != null && now.difference(last) < _alertCooldown) return;

    _lastAlertAtById[d.id] = now;
    _showAlert(d, risk);
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

  Future<void> _init() async {
    await _loadTrusted();
    await _initNotifications();

    final ok = await _ensurePermissions();
    setState(() => permStatus = ok ? "İzinler OK" : "İzinler eksik");

    if (ok) {
      BleBridge.startService();
      if (_scanning) BleBridge.startScan();
    } else {
      setState(() => _scanning = false);
    }

    BleBridge.listen((data) {
      final String id = (data["id"] ?? "").toString();
      if (id.isEmpty) return;

      final String name = (data["name"] ?? "Unknown").toString();
      final int rssi = (data["rssi"] is int)
          ? data["rssi"]
          : int.tryParse(data["rssi"].toString()) ?? -127;

      final now = DateTime.now();

      DeviceModel updated;

      setState(() {
        if (_deviceMap.containsKey(id)) {
          final ex = _deviceMap[id]!;

          final newHist = List<int>.from(ex.rssiHistory);
          newHist.add(rssi);
          if (newHist.length > 20) newHist.removeAt(0);

          updated = DeviceModel(
            id: ex.id,
            name: (ex.name == "Unknown" && name != "Unknown") ? name : ex.name,
            rssi: rssi,
            lastSeen: now,
            seenCount: ex.seenCount + 1,
            firstSeen: ex.firstSeen,
            rssiHistory: newHist,
          );

          _deviceMap[id] = updated;
        } else {
          updated = DeviceModel(
            id: id,
            name: name,
            rssi: rssi,
            lastSeen: now,
            seenCount: 1,
            rssiHistory: [rssi],
          );

          _deviceMap[id] = updated;
        }

        _sortDevicesByRiskDesc();
      });

      final risk = ThreatEngine.calculateRisk(_deviceMap[id]!);
      _maybeAlert(_deviceMap[id]!, risk);
    });
  }

  Future<bool> _ensurePermissions() async {
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    final loc = await Permission.locationWhenInUse.request();
    await Permission.notification.request();
    return scan.isGranted && connect.isGranted && loc.isGranted;
  }

  void _toggleScan() {
    setState(() => _scanning = !_scanning);
    if (_scanning) {
      BleBridge.startScan();
    } else {
      BleBridge.stopScan();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("StalkGuard V3"),
      ),
      body: Column(
        children: [
          ListTile(
            title: Text(permStatus),
            subtitle: Text(_scanning ? "Tarama: AÇIK" : "Tarama: KAPALI"),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: _toggleScan,
                  child: Text(_scanning ? "Durdur" : "Başlat"),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () async {
                    final ok = await _ensurePermissions();
                    setState(() => permStatus = ok ? "İzinler OK" : "İzinler eksik");
                    if (ok && _scanning) BleBridge.startScan();
                  },
                  child: const Text("İzinleri Yenile"),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: devices.isEmpty
                ? const Center(child: Text("Henüz cihaz yok"))
                : ListView.builder(
                    itemCount: devices.length,
                    itemBuilder: (context, index) {
                      final d = devices[index];
                      final bool isTrusted = _trusted.contains(d.id);

                      final riskRaw = ThreatEngine.calculateRisk(d);
                      final risk = isTrusted ? 0 : riskRaw;

                      return ListTile(
                        title: Text(d.name),
                        subtitle: Text(
                          "RSSI: ${d.rssi} | Seen: ${d.seenCount} | Var: ${d.rssiVariance.toStringAsFixed(1)} | Risk: ${risk.toInt()}%${isTrusted ? " (trusted)" : ""}",
                        ),
                        trailing: IconButton(
                          icon: Icon(isTrusted ? Icons.verified_user : Icons.shield_outlined),
                          onPressed: () => _toggleTrusted(d.id),
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
