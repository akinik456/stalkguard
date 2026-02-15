package com.stalkguard.stalkguard

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

// Google Play Services Location
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import android.location.Location

class MainActivity : FlutterActivity() {

    private val CHANNEL = "stalkguard_ble"
    private val ENGINE_ID = "stalkguard_ui_engine"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Cache engine so the Service can talk to UI via MethodChannel
        FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        startBleService()
                        result.success(true)
                    }

                    "startScan" -> {
                        startBleService(action = "START_SCAN")
                        result.success(true)
                    }

                    "stopScan" -> {
                        startBleService(action = "STOP_SCAN")
                        result.success(true)
                    }

                    // Optional legacy hook (you had it in BleBridge)
                    "notify" -> {
                        // You can ignore this (Flutter local notifications already used)
                        result.success(true)
                    }

                    "motionCheck" -> {
                        val secondsArg = call.argument<Int>("seconds") ?: 45
                        val seconds = secondsArg.coerceIn(15, 90)
                        motionCheck(seconds, result)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun startBleService(action: String? = null) {
        val intent = Intent(this, BleForegroundService::class.java)
        if (action != null) intent.action = action

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun motionCheck(seconds: Int, result: MethodChannel.Result) {
        // Permission check: FINE location required for location
        val fineGranted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!fineGranted) {
            result.success(
                hashMapOf(
                    "ok" to false,
                    "reason" to "NO_PERMISSION"
                )
            )
            return
        }

        // Is system location enabled?
        val locEnabled = try {
            val mode = Settings.Secure.getInt(
                contentResolver,
                Settings.Secure.LOCATION_MODE
            )
            mode != Settings.Secure.LOCATION_MODE_OFF
        } catch (_: Exception) {
            true
        }

        if (!locEnabled) {
            result.success(
                hashMapOf(
                    "ok" to false,
                    "reason" to "LOCATION_OFF"
                )
            )
            return
        }

        val fused = LocationServices.getFusedLocationProviderClient(this)

        fun getOne(cb: (Location?) -> Unit) {
            try {
                fused.getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, null)
                    .addOnSuccessListener { cb(it) }
                    .addOnFailureListener { cb(null) }
            } catch (_: Exception) {
                cb(null)
            }
        }

        getOne { l1 ->
            if (l1 == null) {
                result.success(
                    hashMapOf(
                        "ok" to false,
                        "reason" to "NO_FIX_1"
                    )
                )
                return@getOne
            }

            Handler(Looper.getMainLooper()).postDelayed({
                getOne { l2 ->
                    if (l2 == null) {
                        result.success(
                            hashMapOf(
                                "ok" to false,
                                "reason" to "NO_FIX_2"
                            )
                        )
                        return@getOne
                    }

                    val distM = l1.distanceTo(l2).toDouble()
                    val speedMps = distM / seconds.toDouble()

                    result.success(
                        hashMapOf(
                            "ok" to true,
                            "seconds" to seconds,
                            "meters" to distM,
                            "speed_mps" to speedMps
                        )
                    )
                }
            }, (seconds * 1000L))
        }
    }
}
