package io.github.thefrayedend.flash_bridge

import java.util.Calendar
import java.util.TimeZone

/**
 * The time between "Start print" and the printer saying "printing": the board sends the file (big files take
 * minutes), the printer unpacks it, then heats up. Same stages as the board's page (app.js, the job card):
 * `starting {file, at}` while the board has a start under way, `uploadStatus` while it is still sending
 * ("Uploading <name> to printer: 42%"), `machineState` "unzipping" while the printer unpacks.
 * Plain Kotlin (no Android) so it can be checked on a PC: see ci/check-start-stage.sh.
 */
object StartStage {
    /** One notification line. progress: 0–100, or -1 for a moving bar (we don't know how far along). */
    data class Line(val title: String, val text: String, val progress: Int)

    fun line(
        name: String,
        jobState: String,
        machineState: String,
        uploadStatus: String,
        startingFile: String?,
        startingAt: String?,
        nowMs: Long,
    ): Line? {
        if (jobState == "printing" || jobState == "paused") return null
        val unpacking = Regex("unzip", RegexOption.IGNORE_CASE).containsMatchIn(machineState)
        if (startingFile == null && !unpacking) return null
        val file = pretty(startingFile ?: "")
        val since = startingAt?.let { isoUtcMs(it) }?.let { at -> sinceText(((nowMs - at) / 1000).coerceAtLeast(0)) }
        val title: String
        val first: String?
        val progress: Int
        when {
            startingFile != null && uploadStatus.isNotEmpty() -> {
                val pct = Regex("""(\d{1,3})\s*%""").find(uploadStatus)?.groupValues?.get(1)?.toIntOrNull()?.coerceIn(0, 100)
                title = if (pct != null) "$name · sending the file $pct%" else "$name · sending the file"
                first = file.ifEmpty { null }
                progress = pct ?: -1
            }
            unpacking -> {
                title = "$name · unpacking the file"
                first = file.ifEmpty { null } ?: "Big files take several minutes, then it heats up"
                progress = -1
            }
            else -> {
                title = "$name · starting the print"
                first = file.ifEmpty { null } ?: "Waiting for the printer"
                progress = -1
            }
        }
        val text = listOfNotNull(first, since?.let { "$it since Start print" }).joinToString(" · ")
        return Line(title, text, progress)
    }

    /** "2026-11-02T04:35:12.123456Z" → ms since 1970, or null. Calendar, not java.time, so it runs on Android 5+. */
    fun isoUtcMs(s: String): Long? {
        val m = Regex("""^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z$""").find(s.trim()) ?: return null
        val g = m.groupValues
        val c = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        c.clear()
        c.set(g[1].toInt(), g[2].toInt() - 1, g[3].toInt(), g[4].toInt(), g[5].toInt(), g[6].toInt())
        val ms = if (g[7].isEmpty()) 0 else (g[7] + "00").substring(0, 3).toInt()
        return c.timeInMillis + ms
    }

    fun sinceText(secs: Long): String {
        if (secs < 60) return "${secs}s"
        val h = secs / 3600
        val m = (secs % 3600) / 60
        return if (h > 0) "${h}h ${m}m" else "${m}m"
    }

    fun pretty(file: String): String =
        file.substringAfterLast('/').replace(Regex("""\.(gcode\.3mf|gcode|3mf|g)$""", RegexOption.IGNORE_CASE), "")
}
