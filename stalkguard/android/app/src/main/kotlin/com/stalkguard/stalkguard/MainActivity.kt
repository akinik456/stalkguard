package com.stalkguard.stalkguard

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "stalkguard_ble"
    private val ENGINE_ID = "stalkguard_ui_engine"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        startBleService(null)
                        result.success(true)
                    }
                    "startScan" -> {
                        startBleService("START_SCAN")
                        result.success(true)
                    }
                    "stopScan" -> {
                        startBleService("STOP_SCAN")
                        result.success(true)
                    }
                    "motionCheck" -> {
                        val secondsArg = call.argument<Int>("seconds") ?: 45
                        val seconds = secondsArg.coerceIn(15, 90)
                        motionCheck(seconds, result)
                    }
                    "notify" -> {
                        // no-op (Flutter local notifications handles alerts)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startBleService(action: String?) {
        val intent = Intent(this, BleForegroundService::class.java)
        if (action != null) intent.action = action

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    // Collect updates for N seconds and compute distance(first,last).
    private fun motionCheck(seconds: Int, result: MethodChannel.Result) {
        val fineGranted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!fineGranted) {
            result.success(hashMapOf("ok" to false, "reason" to "NO_PERMISSION"))
            return
        }

        val locEnabled = try {
            val mode = Settings.Secure.getInt(contentResolver, Settings.Secure.LOCATION_MODE)
            mode != Settings.Secure.LOCATION_MODE_OFF
        } catch (_: Exception) {
            true
        }

        if (!locEnabled) {
            result.success(hashMapOf("ok" to false, "reason" to "LOCATION_OFF"))
            return
        }

        val fused = LocationServices.getFusedLocationProviderClient(this)
        val locations = ArrayList<Location>(64)

        val request = LocationRequest.Builder(
            Priority.PRIORITY_HIGH_ACCURACY,
            1000L // 1s
        )
            .setMinUpdateIntervalMillis(800L)
            .setWaitForAccurateLocation(false)
            .build()

        val callback = object : LocationCallback() {
            override fun onLocationResult(lr: LocationResult) {
                for (l in lr.locations) {
                    val acc = l.accuracy
                    if (acc.isNaN() || acc <= 0f) continue
                    if (acc > 50f) continue // filter very bad fixes
                    locations.add(l)
                }
            }
        }

        try {
            fused.requestLocationUpdates(request, callback, Looper.getMainLooper())
        } catch (_: Exception) {
            result.success(hashMapOf("ok" to false, "reason" to "REQUEST_FAILED"))
            return
        }

        Handler(Looper.getMainLooper()).postDelayed({
            try { fused.removeLocationUpdates(callback) } catch (_: Exception) {}

            if (locations.size < 2) {
                // Not enough good fixes
                result.success(hashMapOf("ok" to false, "reason" to "NO_FIX", "fixes" to locations.size))
                return@postDelayed
            }

            val first = locations.first()
            val last = locations.last()

            val distM = first.distanceTo(last).toDouble()
            val speedMps = distM / seconds.toDouble()

            result.success(
                hashMapOf(
                    "ok" to true,
                    "seconds" to seconds,
                    "meters" to distM,
                    "speed_mps" to speedMps,
                    "fixes" to locations.size,
                    "acc_first" to first.accuracy,
                    "acc_last" to last.accuracy
                )
            )
        }, seconds * 1000L)
    }
}
