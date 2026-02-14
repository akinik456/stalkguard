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
import android.os.Handler
import android.os.IBinder
import android.os.Looper
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

    // --- WDT (akıllı watchdog) ---
    private val watchdogHandler = Handler(Looper.getMainLooper())
    private var watchdogRunning = false
    private var lastScanMs: Long = 0L
    private var isScanning: Boolean = false

    private val WATCHDOG_CHECK_MS = 30_000L      // 30 sn'de bir kontrol
    private val SCAN_STALE_MS = 2 * 60_000L      // 2 dk sonuç yoksa reset

    private val watchdogRunnable = object : Runnable {
        override fun run() {
            if (!watchdogRunning || !isScanning) return

            val now = System.currentTimeMillis()
            val stale = (now - lastScanMs) > SCAN_STALE_MS
            if (stale) {
                // Scan takıldıysa resetle
                try { scanner.stopScan(scanCallback) } catch (_: Exception) {}
                try { startScanningInternal() } catch (_: Exception) {}
                markScanSeen()
            }

            watchdogHandler.postDelayed(this, WATCHDOG_CHECK_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        startForegroundNotification()
        setupBleScanner()
        attachToUiEngineIfAvailable()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "START_SCAN" -> {
                attachToUiEngineIfAvailable()
                startScanning()
            }
            "STOP_SCAN" -> {
                stopScanning()
            }
            else -> {
                // sadece servis ayağa kalktı
            }
        }
        return START_STICKY
    }

    private fun attachToUiEngineIfAvailable() {
        val engine: FlutterEngine? = FlutterEngineCache.getInstance().get(ENGINE_ID)
        if (engine != null) {
            channel = MethodChannel(engine.dartExecutor.binaryMessenger, "stalkguard_ble")
        }
    }

    private fun startForegroundNotification() {
        val manager = getSystemService(NotificationManager::class.java)

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                notifChannelId,
                "StalkGuard Service",
                NotificationManager.IMPORTANCE_LOW
            )
            manager.createNotificationChannel(channel)
        }

        // sadece "StalkGuard Aktif"
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

    private fun markScanSeen() {
        lastScanMs = System.currentTimeMillis()
    }

    private fun startWatchdogIfNeeded() {
        if (watchdogRunning) return
        watchdogRunning = true
        markScanSeen()
        watchdogHandler.postDelayed(watchdogRunnable, WATCHDOG_CHECK_MS)
    }

    private fun stopWatchdog() {
        watchdogRunning = false
        watchdogHandler.removeCallbacks(watchdogRunnable)
    }

    private fun startScanning() {
        if (isScanning) return
        startScanningInternal()
        isScanning = true
        markScanSeen()
        startWatchdogIfNeeded()
    }

    private fun startScanningInternal() {
        val hasScanPerm = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.BLUETOOTH_SCAN
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasScanPerm) return

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        // Not: startScan çağrısı başarısız olursa exception atabilir; yutuyoruz
        try {
            scanner.startScan(null, settings, scanCallback)
        } catch (_: Exception) {}
    }

    private fun stopScanning() {
        if (!isScanning) return
        isScanning = false
        stopWatchdog()
        try { scanner.stopScan(scanCallback) } catch (_: Exception) {}
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            // her sonuç geldiğinde "scan yaşıyor" işaretle
            markScanSeen()

            val device = result.device
            val id = device.address ?: return
            val name = device.name ?: "Unknown"
            val rssi = result.rssi

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
        stopScanning()
        stopWatchdog()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
