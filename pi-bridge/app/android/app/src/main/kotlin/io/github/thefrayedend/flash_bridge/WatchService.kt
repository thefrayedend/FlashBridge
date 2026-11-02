package io.github.thefrayedend.flash_bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Watches the board while the app is closed: the print's progress in a quiet notification (like the
 * Bambu Handy app), and alerts when a print finishes, pauses (also when the AI pauses it), fails or is
 * cancelled, when a print fails to start, and when a slice is done or fails. Between "Start print" and printing
 * the progress line shows the start stages (sending the file %, unpacking, starting; see StartStage). It reads the same /api/status and /api/slicer the web
 * page uses, every 10 s while something runs and every 30 s otherwise.
 */
class WatchService : Service() {
    companion object {
        const val PREFS = "flashbridge"
        const val CH_PROGRESS = "progress"
        const val CH_ALERTS = "alerts"
        private const val ONGOING_ID = 1

        fun start(ctx: Context) {
            val i = Intent(ctx, WatchService::class.java)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, WatchService::class.java))
        }

        fun board(ctx: Context): String = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("board", "") ?: ""
        fun enabled(ctx: Context): Boolean = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("watch", false)
    }

    @Volatile private var running = false
    private var worker: Thread? = null
    private var first = true
    private val jobState = HashMap<String, String>()
    private val aiPaused = HashMap<String, Boolean>()
    private val errorCode = HashMap<String, String>()
    private val sliceState = HashMap<String, String>()
    private val printErrorAt = HashMap<String, String>()
    private var nextAlertId = 100
    private var offlineSince = 0L
    private var offlineAlerted = false
    @Volatile private var lastOngoing: Notification? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Android needs startForeground on every start; while already running, keep the last line
        startInForeground(lastOngoing ?: ongoing("Flash Bridge", "Connecting to the board…", null))
        if (!running) {
            running = true
            first = true
            worker = Thread({ loop() }, "flashbridge-watch").also { it.start() }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        worker?.interrupt()
        nm()?.cancel(ONGOING_ID)
        super.onDestroy()
    }

    private fun nm(): NotificationManager? = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    private fun startInForeground(n: Notification) {
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ONGOING_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ONGOING_ID, n)
        }
    }

    // ------------------------------------------------------------------ polling
    private fun loop() {
        while (running) {
            val wait = try {
                poll()
            } catch (e: InterruptedException) {
                return
            } catch (e: Exception) {
                offline()
                30_000L
            }
            try {
                Thread.sleep(wait)
            } catch (e: InterruptedException) {
                return
            }
        }
    }

    private fun get(path: String): JSONObject {
        val base = board(this).trimEnd('/')
        if (base.isEmpty()) throw IllegalStateException("no board")
        val c = URL(base + path).openConnection() as HttpURLConnection
        c.connectTimeout = 5000
        c.readTimeout = 10000
        try {
            return JSONObject(c.inputStream.bufferedReader().use { it.readText() })
        } finally {
            c.disconnect()
        }
    }

    /** One round: reads the board, raises alerts for changes, updates the progress line. Returns the wait (ms). */
    private fun poll(): Long {
        val st = get("/api/status")
        offlineSince = 0L
        offlineAlerted = false
        val printers = st.optJSONArray("printers")
        var busy = false
        var line: String? = null
        var title = "Flash Bridge"
        var progress: Int? = null
        if (printers != null) {
            for (k in 0 until printers.length()) {
                val p = printers.getJSONObject(k)
                val id = p.optString("id")
                val name = p.optString("name", "Printer")
                val state = p.optString("jobState", "standby")
                val file = pretty(p.optString("jobFile"))
                val prev = jobState[id]
                val ai = p.optJSONObject("ai")
                val pausedByAi = ai?.optBoolean("pausedByAi", false) ?: false
                val err = p.optJSONObject("error")
                val code = err?.optString("code") ?: ""
                if (!first && prev != null && prev != state) {
                    when (state) {
                        "complete" -> alert("$name: print finished", file.ifEmpty { "Take the print off the plate." }, "printer")
                        "paused" -> if (pausedByAi) {
                            alert("$name: the AI paused the print", "It saw what looks like a failure ($file). Check the camera, then resume or stop.", "printer")
                        } else if (prev == "printing") {
                            alert("$name: print paused", file, "printer")
                        }
                        "cancelled" -> if (prev == "printing" || prev == "paused") alert("$name: print cancelled", file, "printer")
                        "error" -> alert("$name: printer error", err?.optString("title")?.ifEmpty { null } ?: "The printer reported an error.", "printer")
                    }
                }
                // a new error code while printing (filament runout and the like)
                if (!first && code.isNotEmpty() && code != (errorCode[id] ?: "") && state != "error") {
                    alert("$name: ${err?.optString("title")?.ifEmpty { null } ?: "printer message"}", err?.optString("fix") ?: "", "printer")
                }
                // the AI paused it while the state stayed "paused" (it was paused already for another reason)
                if (!first && pausedByAi && aiPaused[id] != true && prev == "paused" && state == "paused") {
                    alert("$name: the AI paused the print", "It saw what looks like a failure. Check the camera.", "printer")
                }
                // a print that failed after the board had already answered (big files keep sending in the
                // background); "at" tells a new failure from one already seen. Errors from before the app was
                // watching are not announced (same as the web page).
                val pe = p.optJSONObject("printError")
                if (pe != null) {
                    val at = pe.optString("at")
                    if (!first && at != (printErrorAt[id] ?: "")) {
                        alert("$name: the print did not start", pe.optString("message").ifEmpty { "The printer refused the file." }, "printer")
                    }
                    printErrorAt[id] = at
                }
                jobState[id] = state
                aiPaused[id] = pausedByAi
                errorCode[id] = code
                if (state == "printing" || state == "paused") {
                    busy = true
                    if (line == null) {
                        val pct = (p.optDouble("progress", 0.0) * 100).toInt().coerceIn(0, 100)
                        val left = p.optLong("remaining", 0)
                        val layer = p.optInt("layer", 0)
                        val layers = p.optInt("layers", 0)
                        title = if (state == "paused") "$name · paused" else "$name · $pct%"
                        line = listOfNotNull(
                            file.ifEmpty { null },
                            if (layers > 0) "layer $layer/$layers" else null,
                            if (left > 0 && state == "printing") "${time(left)} left" else null,
                        ).joinToString(" · ")
                        progress = pct
                    }
                }
                // from Start print until the printer says printing: sending → unpacking → starting
                val starting = p.optJSONObject("starting")
                val stage = StartStage.line(
                    name, state, p.optString("machineState"), p.optString("uploadStatus"),
                    starting?.optString("file"), starting?.optString("at"), System.currentTimeMillis(),
                )
                if (stage != null) {
                    busy = true
                    if (line == null) {
                        title = stage.title
                        line = stage.text
                        progress = stage.progress
                    }
                }
            }
        }
        // slices on the board
        try {
            val jobs = get("/api/slicer").optJSONObject("jobs")
            if (jobs != null) {
                val keys = jobs.keys()
                while (keys.hasNext()) {
                    val plate = keys.next()
                    val j = jobs.getJSONObject(plate)
                    val s = j.optString("state")
                    val prev = sliceState[plate]
                    if (!first && prev == "slicing" && s != prev) {
                        val name = pretty(j.optString("name"))
                        when (s) {
                            "done" -> alert("Plate $plate sliced", listOfNotNull(name.ifEmpty { null }, j.optJSONObject("stats")?.optString("time")?.ifEmpty { null }).joinToString(" · "), "preview")
                            "error" -> alert("Slicing plate $plate failed", j.optString("error").ifEmpty { j.optString("message") }, "slicer")
                        }
                    }
                    if (s == "slicing") {
                        busy = true
                        if (line == null) {
                            title = "Slicing plate $plate"
                            line = j.optString("message")
                            progress = j.optInt("percent", 0)
                        }
                    }
                    sliceState[plate] = s
                }
            }
        } catch (e: Exception) {
            // no slicer on this board
        }
        first = false
        if (line == null) {
            val names = (0 until (printers?.length() ?: 0)).joinToString(", ") { printers!!.getJSONObject(it).optString("name") }
            line = if (names.isEmpty()) "Connected to the board" else "$names · ready"
        }
        notifyOngoing(ongoing(title, line, progress))
        return if (busy) 10_000L else 30_000L
    }

    private fun offline() {
        val now = System.currentTimeMillis()
        if (offlineSince == 0L) offlineSince = now
        notifyOngoing(ongoing("Flash Bridge", "Can't reach the board", null))
        // say it once when a print was running and the board has been gone for 3 minutes
        val wasPrinting = jobState.values.any { it == "printing" }
        if (!offlineAlerted && wasPrinting && now - offlineSince > 180_000L) {
            offlineAlerted = true
            alert("Lost contact with the board", "A print was running. Check the board's power and Wi-Fi.", "printer")
        }
    }

    // ------------------------------------------------------------------ notifications
    private fun createChannels() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = nm() ?: return
        nm.createNotificationChannel(NotificationChannel(CH_PROGRESS, "Print progress", NotificationManager.IMPORTANCE_LOW).apply {
            description = "The running print or slice, always up to date"
            setShowBadge(false)
        })
        nm.createNotificationChannel(NotificationChannel(CH_ALERTS, "Print alerts", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Print finished, paused, failed; slice done"
        })
    }

    private fun openApp(target: String, code: Int): PendingIntent {
        val i = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("open", target)
        }
        return PendingIntent.getActivity(this, code, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun builder(channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel) else @Suppress("DEPRECATION") Notification.Builder(this)

    private fun ongoing(title: String, text: String, progress: Int?): Notification {
        val b = builder(CH_PROGRESS)
            .setSmallIcon(R.drawable.ic_stat_bolt)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openApp("printer", 1))
        if (progress != null) {
            if (progress < 0) b.setProgress(0, 0, true) else b.setProgress(100, progress, false) // -1: moving bar
        }
        return b.build()
    }

    private fun notifyOngoing(n: Notification) {
        if (!running) return // stopped while a request was still open: don't bring the notification back
        lastOngoing = n
        nm()?.notify(ONGOING_ID, n)
    }

    private fun alert(title: String, text: String, target: String) {
        if (!running) return
        val id = nextAlertId++
        val n = builder(CH_ALERTS)
            .setSmallIcon(R.drawable.ic_stat_bolt)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(openApp(target, id))
            .build()
        nm()?.notify(id, n)
    }

    private fun pretty(file: String): String =
        file.substringAfterLast('/').replace(Regex("""\.(gcode\.3mf|gcode|3mf|g)$""", RegexOption.IGNORE_CASE), "")

    private fun time(s: Long): String {
        val h = s / 3600
        val m = (s % 3600) / 60
        return if (h > 0) "${h}h ${m}m" else "${m}m"
    }
}
