package com.stalkguard.stalkguard

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class BleForegroundService : Service() {

    private lateinit var scanner: BluetoothLeScanner

    private val notifId = 1
    private val notifChannelId = "stalkguard_channel"

    private val ENGINE_ID = "stalkguard_ui_engine"
    private var channel: MethodChannel? = null

    override fun onCreate() {
        super.onCreate()
        startForegroundNotification()
        setupBleScanner()
        attachToUiEngineIfAvailable()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "START_SCAN") {
            attachToUiEngineIfAvailable() // garanti olsun
            startScanning()
        }
        return START_STICKY
    }

    private fun attachToUiEngineIfAvailable() {
        val engine: FlutterEngine? = FlutterEngineCache.getInstance().get(ENGINE_ID)
        if (engine != null) {
            channel = MethodChannel(engine.dartExecutor.binaryMessenger, "stalkguard_ble")
        }
        // engine yoksa: UI açılınca cache gelir; bu V3.0 debug aşaması için yeterli
    }

    private fun startForegroundNotification() {
        val manager = getSystemService(NotificationManager::class.java)

        // Channel oluştur (Android 8+ için zorunlu)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                notifChannelId,
                "StalkGuard Service",
                NotificationManager.IMPORTANCE_LOW
            )
            manager.createNotificationChannel(channel)
        }

        val notification = NotificationCompat.Builder(this, notifChannelId)
            .setContentTitle("StalkGuard Aktif")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()

        startForeground(notifId, notification)
    }

    private fun setupBleScanner() {
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter: BluetoothAdapter = manager.adapter
        scanner = adapter.bluetoothLeScanner
    }

    private fun startScanning() {
        val hasScanPerm = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.BLUETOOTH_SCAN
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasScanPerm) return

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        scanner.startScan(null, settings, scanCallback)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val id = device.address ?: return
            val name = device.name ?: "Unknown"
            val rssi = result.rssi

            // Flutter UI'ya gönder
            val data = hashMapOf(
                "id" to id,
                "name" to name,
                "rssi" to rssi
            )
            channel?.invokeMethod("onDevice", data)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try { scanner.stopScan(scanCallback) } catch (_: Exception) {}
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
