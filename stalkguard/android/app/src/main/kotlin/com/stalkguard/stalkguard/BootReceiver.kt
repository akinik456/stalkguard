package com.stalkguard.stalkguard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action == Intent.ACTION_BOOT_COMPLETED || action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            val i = Intent(context, BleForegroundService::class.java)
            i.action = "START_SCAN"
            ContextCompat.startForegroundService(context, i)
        }
    }
}
