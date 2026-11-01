package io.github.thefrayedend.flash_bridge

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The app's one screen (Flutter draws it). This side does what only Android can:
 * files and links other apps send here (Open with / Share), the background watch (notifications),
 * opening links in the phone's browser, and the Wi-Fi multicast lock the board search needs.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val pending = ArrayList<Map<String, String>>()
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "flashbridge/app")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences(WatchService.PREFS, Context.MODE_PRIVATE)
            when (call.method) {
                "takeIncoming" -> {
                    result.success(ArrayList(pending))
                    pending.clear()
                }
                "getSettings" -> result.success(
                    mapOf(
                        "board" to (prefs.getString("board", "") ?: ""),
                        "host" to (prefs.getString("host", "creator5.local") ?: "creator5.local"),
                        "watch" to prefs.getBoolean("watch", false),
                    )
                )
                "setSettings" -> {
                    val e = prefs.edit()
                    call.argument<String>("board")?.let { e.putString("board", it) }
                    call.argument<String>("host")?.let { e.putString("host", it) }
                    call.argument<Boolean>("watch")?.let { e.putBoolean("watch", it) }
                    e.apply()
                    applyWatch(prefs.getBoolean("watch", false), prefs.getString("board", "") ?: "")
                    result.success(true)
                }
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
                        result.success(false)
                    } else {
                        result.success(true)
                    }
                }
                "openExternal" -> {
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url"))).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "multicastLock" -> {
                    try {
                        if (call.argument<Boolean>("on") == true) {
                            if (multicastLock == null) {
                                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                                multicastLock = wm.createMulticastLock("flashbridge").apply { setReferenceCounted(false); acquire() }
                            }
                        } else {
                            multicastLock?.release()
                            multicastLock = null
                        }
                    } catch (e: Exception) {
                        // no Wi-Fi: the search simply finds nothing
                    }
                    result.success(true)
                }
                "cacheDir" -> result.success(cacheDir.absolutePath)
                "appVersion" -> result.success(
                    try {
                        packageManager.getPackageInfo(packageName, 0).versionName ?: ""
                    } catch (e: Exception) {
                        ""
                    }
                )
                else -> result.notImplemented()
            }
        }
        handleIntent(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = getSharedPreferences(WatchService.PREFS, Context.MODE_PRIVATE)
        applyWatch(prefs.getBoolean("watch", false), prefs.getString("board", "") ?: "")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    override fun onDestroy() {
        multicastLock?.release()
        multicastLock = null
        super.onDestroy()
    }

    private fun applyWatch(on: Boolean, board: String) {
        try {
            if (on && board.isNotEmpty()) WatchService.start(this) else WatchService.stop(this)
        } catch (e: Exception) {
            // Android refused to start it now; it starts with the next app launch
        }
    }

    private fun deliver(item: Map<String, String>) {
        runOnUiThread {
            pending.add(item)
            channel?.invokeMethod("incoming", null)
        }
    }

    /** Files (Open with / Share), shared links, and taps on our own notifications. */
    private fun handleIntent(i: Intent?) {
        if (i == null) return
        i.getStringExtra("open")?.let {
            i.removeExtra("open")
            deliver(mapOf("open" to it))
        }
        val uris = ArrayList<Uri>()
        when (i.action) {
            Intent.ACTION_VIEW -> i.data?.let { uris.add(it) }
            Intent.ACTION_SEND -> {
                val u = if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (u != null) uris.add(u) else {
                    val text = i.getStringExtra(Intent.EXTRA_TEXT) ?: ""
                    Regex("""https?://\S+""").find(text)?.let { deliver(mapOf("url" to it.value)) }
                    i.action = Intent.ACTION_MAIN
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val list = if (Build.VERSION.SDK_INT >= 33) i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") i.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                list?.let { uris.addAll(it) }
            }
        }
        if (uris.isEmpty()) return
        // the same intent must not deliver its files twice (rotation, coming back to the app)
        i.action = Intent.ACTION_MAIN
        i.data = null
        Thread {
            for (u in uris) {
                if (u.scheme == "http" || u.scheme == "https") {
                    deliver(mapOf("url" to u.toString()))
                    continue
                }
                try {
                    val name = displayName(u)
                    val dir = File(cacheDir, "incoming").apply { mkdirs() }
                    val f = File(dir, "${System.currentTimeMillis()}-$name")
                    contentResolver.openInputStream(u)?.use { input -> f.outputStream().use { input.copyTo(it) } }
                    deliver(mapOf("path" to f.absolutePath, "name" to name))
                } catch (e: Exception) {
                    deliver(mapOf("error" to "Could not read the file: ${e.message}"))
                }
            }
        }.start()
    }

    private fun displayName(u: Uri): String {
        var name: String? = null
        if (u.scheme == "content") {
            try {
                contentResolver.query(u, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) name = c.getString(0)
                }
            } catch (e: Exception) {
            }
        }
        if (name.isNullOrBlank()) name = u.lastPathSegment?.substringAfterLast('/')
        return (name ?: "model").replace(Regex("""[\\/:*?"<>|]"""), "_")
    }
}
