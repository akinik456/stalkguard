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
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
    private lateinit var btManager: BluetoothManager
    private lateinit var adapter: BluetoothAdapter

    private val notifId = 1
    private val notifChannelId = "stalkguard_channel"

    private val ENGINE_ID = "stalkguard_ui_engine"
    private var channel: MethodChannel? = null

    // --- WDT (smart watchdog) ---
    private val watchdogHandler = Handler(Looper.getMainLooper())
    private var watchdogRunning = false
    private var lastScanMs: Long = 0L

    // user intent: scan ON/OFF
    private var scanWanted: Boolean = false

    // bt state
    private var btOn: Boolean = true
    private var btReceiverRegistered: Boolean = false

    private val WATCHDOG_CHECK_MS = 30_000L      // check every 30s
    private val SCAN_STALE_MS = 2 * 60_000L      // if no results for 2 min => restart scan (only if BT ON)

    private val watchdogRunnable = object : Runnable {
        override fun run() {
            if (!watchdogRunning || !scanWanted) return

            // if BT is OFF, do nothing (no pointless resets)
            if (!isBluetoothReady()) {
                watchdogHandler.postDelayed(this, WATCHDOG_CHECK_MS)
                return
            }

            val now = System.currentTimeMillis()
            val stale = (now - lastScanMs) > SCAN_STALE_MS
            if (stale) {
                try { scanner.stopScan(scanCallback) } catch (_: Exception) {}
                try { startScanInternal() } catch (_: Exception) {}
                markScanSeen()
            }

            watchdogHandler.postDelayed(this, WATCHDOG_CHECK_MS)
        }
    }

    // --- BT state receiver ---
    private val btStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return

            val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            btOn = (state == BluetoothAdapter.STATE_ON)

            // notify Flutter UI if available
            channel?.invokeMethod("onBtState", hashMapOf("on" to btOn))

            // update foreground notification text
            updateForegroundStatus()
        }
    }

    override fun onCreate() {
        super.onCreate()
        setupBleScanner()

        // initial bt state
        btOn = isBluetoothReady()

        startForegroundNotification()
        attachToUiEngineIfAvailable()

        registerBtReceiverIfNeeded()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "START_SCAN" -> {
                attachToUiEngineIfAvailable()
                startScanning()
                updateForegroundStatus() // Active/Passive + BT ON/OFF
            }
            "STOP_SCAN" -> {
                stopScanning()
                updateForegroundStatus()
            }
            else -> {
                // service started
                updateForegroundStatus()
            }
        }
        return START_STICKY
    }

    private fun attachToUiEngineIfAvailable() {
        val engine: FlutterEngine? = FlutterEngineCache.getInstance().get(ENGINE_ID)
        if (engine != null) {
            channel = MethodChannel(engine.dartExecutor.binaryMessenger, "stalkguard_ble")

            // send current BT state once UI attaches
            channel?.invokeMethod("onBtState", hashMapOf("on" to btOn))
        }
    }

    private fun registerBtReceiverIfNeeded() {
        if (btReceiverRegistered) return
        try {
            registerReceiver(btStateReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
            btReceiverRegistered = true
        } catch (_: Exception) {}
    }

    private fun startForegroundNotification() {
        val manager = getSystemService(NotificationManager::class.java)

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                notifChannelId,
                "StalkGuard Service",
                NotificationManager.IMPORTANCE_LOW
            )
            manager.createNotificationChannel(ch)
        }

        val notification = NotificationCompat.Builder(this, notifChannelId)
            .setContentTitle(buildForegroundTitle())
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()

        startForeground(notifId, notification)
    }

    private fun buildForegroundTitle(): String {
        val scanText = if (scanWanted) "Active" else "Passive"
        val btText = if (btOn) "Bluetooth ON" else "Bluetooth OFF"
        return "StalkGuard $scanText • $btText"
    }

    private fun updateForegroundStatus() {
        val notification = NotificationCompat.Builder(this, notifChannelId)
            .setContentTitle(buildForegroundTitle())
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()

        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(notifId, notification)
    }

    private fun setupBleScanner() {
        btManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        adapter = btManager.adapter
        scanner = adapter.bluetoothLeScanner
    }

    private fun isBluetoothReady(): Boolean {
        return try {
            adapter.isEnabled && adapter.bluetoothLeScanner != null
        } catch (_: Exception) {
            false
        }
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
        scanWanted = true
        startWatchdogIfNeeded()

        val hasScanPerm = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.BLUETOOTH_SCAN
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasScanPerm) return

        // BT OFF => just wait, WDT will keep checking
        if (!isBluetoothReady()) return

        startScanInternal()
        markScanSeen()
    }

    private fun startScanInternal() {
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        try {
            scanner.startScan(null, settings, scanCallback)
        } catch (_: Exception) {}
    }

    private fun stopScanning() {
        scanWanted = false
        stopWatchdog()
        try { scanner.stopScan(scanCallback) } catch (_: Exception) {}
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
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

        if (btReceiverRegistered) {
            try { unregisterReceiver(btStateReceiver) } catch (_: Exception) {}
            btReceiverRegistered = false
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
