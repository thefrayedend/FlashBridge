package io.github.thefrayedend.flash_bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Starts watching the board again after the phone restarts (or the app is updated), if it was on. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val a = intent.action ?: return
        if (a != Intent.ACTION_BOOT_COMPLETED && a != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (WatchService.enabled(context) && WatchService.board(context).isNotEmpty()) {
            try {
                WatchService.start(context)
            } catch (e: Exception) {
                // Android may refuse a background start; the app starts it next time it opens
            }
        }
    }
}
