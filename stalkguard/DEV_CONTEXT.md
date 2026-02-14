# StalkGuard DEV CONTEXT

## Current Version
v0.3.0-beta (git tag)

## Goal
Android için gizli BLE tracker tespiti (noname BLE advertising cihazlar dahil).
Kullanıcıya risk bazlı uyarı + cihaz listesi.

## Platform / Test
- Device: Xiaomi M2003J15SC
- Android: 12
- flutter run ile debug

## Key Architecture
- Flutter UI (lib/)
- Native Kotlin Foreground Service: BleForegroundService
- Flutter <-> Kotlin bridge: MethodChannel "stalkguard_ble"
- MainActivity içinde FlutterEngineCache fix yapıldı (ENGINE_ID = "stalkguard_ui_engine")

## What Works
- BLE tarama: liste doluyor
- Risk bildirimi çalışıyor (flutter_local_notifications)
- Foreground bildirim sade: sadece "StalkGuard Aktif" (contentText kaldırıldı)
- Cihaz listesi risk skoruna göre (yüksek risk üstte) sıralanacak/aktif

## Important Implementation Notes
- Android 12: notification permission popup yok; Permission.notification OK hesabına dahil edilmez
- flutter_local_notifications API: initialize(initSettings) positional; show(...) 4 positional (named kullanınca build patlıyor)
- Notification channel id: "stalkguard_alerts_v2"
- Risk alert: threshold >= 70, cooldown 10 dakika, trusted cihazlar alert almaz
- Trusted cihazlar SharedPreferences key: trusted_ids_v1

## Modified Files (high signal)
- lib/main.dart
- lib/core/ble_bridge.dart
- android/app/src/main/AndroidManifest.xml
- android/app/src/main/kotlin/com/stalkguard/stalkguard/MainActivity.kt
- android/app/src/main/kotlin/com/stalkguard/stalkguard/BleForegroundService.kt

## Next TODO
- False positive azaltma
- Pil tüketimi optimizasyonu (scan mode / batch / duty cycle)
- Tracker “takip ediyor” korelasyonu (hareket + RSSI trend)
- UI: risk filtre / detay ekranı
