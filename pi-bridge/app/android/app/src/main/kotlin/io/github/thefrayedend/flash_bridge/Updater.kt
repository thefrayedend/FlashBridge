package io.github.thefrayedend.flash_bridge

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.widget.Toast
import java.io.File

/**
 * Installs a newer Flash Bridge APK the app downloaded itself (the release "latest-app" on GitHub).
 * Android 12+: once the app was the one that installed the current version, updates need no tap at
 * all (USER_ACTION_NOT_REQUIRED); otherwise Android shows its own "Update" screen.
 */
object Updater {
    const val ACTION = "io.github.thefrayedend.flash_bridge.INSTALL_RESULT"

    fun install(ctx: Context, apk: File) {
        val installer = ctx.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(ctx.packageName)
        if (Build.VERSION.SDK_INT >= 31) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("flash-bridge.apk", 0, apk.length()).use { out ->
                apk.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            val i = Intent(ctx, InstallReceiver::class.java).setAction(ACTION)
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_UPDATE_CURRENT
            session.commit(PendingIntent.getBroadcast(ctx, id, i, flags).intentSender)
        }
    }
}

/** Android's answer to an install: shows its confirmation screen when it wants one, or the error. */
class InstallReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -999)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirm != null) {
                    confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    try {
                        ctx.startActivity(confirm)
                    } catch (e: Exception) {
                        Toast.makeText(ctx, "Flash Bridge update ready: open the app to install it.", Toast.LENGTH_LONG).show()
                    }
                }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                // the new version replaces this process; BootReceiver (MY_PACKAGE_REPLACED) restarts the watch
            }
            else -> {
                val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "unknown reason"
                Toast.makeText(ctx, "Flash Bridge update failed: $msg", Toast.LENGTH_LONG).show()
            }
        }
    }
}
