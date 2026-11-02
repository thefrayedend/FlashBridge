// Checks StartStage (the notification's start stages) on a PC: ci/check-start-stage.sh
import io.github.thefrayedend.flash_bridge.StartStage

var failed = 0
fun check(what: String, got: Any?, want: Any?) {
    if (got == want) println("ok   $what") else { println("FAIL $what\n     got:  $got\n     want: $want"); failed++ }
}

fun main() {
    val at = "2026-11-02T04:35:12.123456Z"
    val t0 = StartStage.isoUtcMs(at)!!
    check("parse ISO with microseconds", t0 % 1000, 123L)
    check("parse ISO without fraction", StartStage.isoUtcMs("1970-01-01T00:01:00Z"), 60_000L)
    check("bad date", StartStage.isoUtcMs("2026-11-02T04:35:12"), null)

    check("idle printer: no line", StartStage.line("C5", "standby", "ready", "", null, null, t0), null)
    check("printing: no line (progress line handles it)",
        StartStage.line("C5", "printing", "printing", "", "a.gcode.3mf", at, t0), null)

    check("sending with %",
        StartStage.line("Creator 5", "standby", "ready", "Uploading helmet.gcode.3mf to printer: 42%", "helmet.gcode.3mf", at, t0 + 95_000),
        StartStage.Line("Creator 5 · sending the file 42%", "helmet · 1m since Start print", 42))
    check("sending, no % yet",
        StartStage.line("C5", "complete", "completed", "Uploading helmet.gcode.3mf to printer...", "helmet.gcode.3mf", at, t0 + 5_000),
        StartStage.Line("C5 · sending the file", "helmet · 5s since Start print", -1))
    check("unpacking",
        StartStage.line("C5", "standby", "unzipping", "", "dir/helmet.gcode.3mf", at, t0 + 3_725_000),
        StartStage.Line("C5 · unpacking the file", "helmet · 1h 2m since Start print", -1))
    check("unpacking without a start from the board (started on the printer screen)",
        StartStage.line("C5", "standby", "unzipping", "", null, null, t0),
        StartStage.Line("C5 · unpacking the file", "Big files take several minutes, then it heats up", -1))
    check("sent, waiting for the printer",
        StartStage.line("C5", "standby", "busy", "", "x.gcode", at, t0 + 61_000),
        StartStage.Line("C5 · starting the print", "x · 1m since Start print", -1))
    check("clock behind the board: no negative time",
        StartStage.line("C5", "standby", "ready", "", "x.gcode", at, t0 - 10_000)?.text, "x · 0s since Start print")
    check("bad date: no time shown",
        StartStage.line("C5", "standby", "ready", "", "x.gcode", "soon", t0)?.text, "x")

    if (failed > 0) { println("$failed check(s) failed"); kotlin.system.exitProcess(1) }
    println("All start-stage checks passed.")
}
