#!/usr/bin/env python3
"""Black box checks for ffsys.py: tail of the readings file across the rotated copy, "previous boot
ended" from the bridge's start markers, the CPU/throttle reading, and the journald settings text
matching the file in rootfs.     python3 image/test/blackbox_check.py"""
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.path.dirname(HERE)
fails = 0


def check(name, ok, detail=""):
    global fails
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  -> {detail}"))
    if not ok:
        fails += 1


spec = importlib.util.spec_from_file_location("ffsys", os.path.join(IMG, "rootfs/usr/local/lib/ffbridge/ffsys.py"))
ffsys = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ffsys)

tmp = tempfile.mkdtemp(prefix="ffb-bb")
log = os.path.join(tmp, "blackbox.log")
ffsys.BLACKBOX_LOG = log
with open(log + ".1", "w") as f:
    f.write("\n".join(f"2026-11-04T10:00:{i:02d} up={i}s temp=40.0C" for i in range(60)) + "\n")
with open(log, "w") as f:
    f.write("2026-11-04T10:01:00 up=60s temp=41.0C\n")
    f.write("2026-11-04T10:01:30 up=90s temp=42.0C\n")
    f.write("=== bridge start 2026-11-04T10:05:00 (previous entry: 2026-11-04T10:01:30) ===\n")
    f.write("2026-11-04T10:05:00 up=12s temp=35.0C\n")
    f.write("2026-11-04T10:05:30 up=42s temp=36.0C\n")

tail = ffsys.blackbox_tail(120)
check("tail joins the rotated copy and the current file", len(tail) == 65 and tail[-1].startswith("2026-11-04T10:05:30") and tail[0].startswith("2026-11-04T10:00:00"), (len(tail), tail[:1], tail[-1:]))
check("tail of 3 is the last three lines", ffsys.blackbox_tail(3)[0].startswith("=== bridge start"))
check("previous boot ended = the last reading before the last start marker", ffsys.previous_boot_end(ffsys.blackbox_tail(5000)) == "2026-11-04T10:01:30", ffsys.previous_boot_end(ffsys.blackbox_tail(5000)))
check("no marker -> unknown", ffsys.previous_boot_end(["2026-11-04T10:00:00 up=1s"]) is None)
check("two markers in a row (start right after a start) -> the one with a reading before it",
      ffsys.previous_boot_end(["2026-11-04T09:00:00 up=5s", "=== bridge start a ===", "=== bridge start b ===", "2026-11-04T09:01:00 up=5s"]) == "2026-11-04T09:00:00")
os.remove(log)
os.remove(log + ".1")
check("no files -> empty tail, unknown end", ffsys.blackbox_tail() == [] and ffsys.previous_boot_end([]) is None)

st = ffsys.cpu_state()
check("cpu_state answers a dict without raising", isinstance(st, dict), st)
if "cpu_mhz" in st:
    check("cpu_mhz looks like cur/max pairs", all("of" in p for p in st["cpu_mhz"].split("/")), st["cpu_mhz"])
    check("throttled is a bool", isinstance(st["throttled"], bool))
else:
    print("     (no cpufreq on this computer: skipping the clock checks)")

conf = open(os.path.join(IMG, "rootfs/etc/systemd/journald.conf.d/ffbridge.conf")).read()
check("journald settings in rootfs == what blackbox_setup writes", conf == ffsys.JOURNALD_TEXT)
check("journald keeps 200 MB, persistent, synced every 30 s", "Storage=persistent" in conf and "SystemMaxUse=200M" in conf and "SyncIntervalSec=30s" in conf)
check("fstab line binds the SD-card folder onto /var/log/journal, after the RAM-log services, before the journal flush",
      ffsys.fstab_line().startswith(f"{ffsys.JOURNAL_DIR} /var/log/journal none bind,nofail") and "x-systemd.before=systemd-journal-flush.service" in ffsys.fstab_line() and "armbian-ramlog" in ffsys.fstab_line())

# blackbox_setup against a fake root: records the commands instead of running them
calls = []
mounted = {"on": False}
def fake_run(cmd, check=False, timeout=60, input_text=None):
    import subprocess
    calls.append(cmd)
    out = ""
    if cmd[0] == "findmnt" and "-o" in cmd and cmd[cmd.index("-o") + 1] == "TARGET":
        out = ffsys.JOURNAL_MOUNT if mounted["on"] else ""
    elif cmd[0] == "findmnt":
        out = "/dev/mmcblk0p1[/var/lib/ffbridge-sys/journal] ext4" if mounted["on"] else "zram1 ext4"
    elif cmd[0] == "mount":
        mounted["on"] = True
    elif cmd[0] == "journalctl":
        out = "Archived and active journals take up 16.0M in the file system."
    return subprocess.CompletedProcess(cmd, 0, out, "")
root = tempfile.mkdtemp(prefix="ffb-root")
ffsys.run = fake_run
ffsys.JOURNAL_DIR = os.path.join(root, "var/lib/ffbridge-sys/journal")
ffsys.JOURNAL_MOUNT = os.path.join(root, "var/log/journal")
ffsys.JOURNALD_CONF = os.path.join(root, "etc/systemd/journald.conf.d/ffbridge.conf")
ffsys.FSTAB_PATH = os.path.join(root, "etc/fstab")
os.makedirs(os.path.dirname(ffsys.FSTAB_PATH))
with open(ffsys.FSTAB_PATH, "w") as f:
    f.write("UUID=abc / ext4 defaults 0 1\nLABEL=FFBRIDGE /ffsetup vfat defaults,nofail 0 0\n")
r = ffsys.blackbox_setup()
check("first run: ok", r.get("ok") is True, r)
check("first run: journal folder made, settings written, mounted, journald NOT restarted (froze the bridge)",
      os.path.isdir(ffsys.JOURNAL_DIR) and open(ffsys.JOURNALD_CONF).read() == ffsys.JOURNALD_TEXT
      and any(c[0] == "mount" and c[1] == "--bind" for c in calls) and not any(c[:3] == ["systemctl", "restart", "systemd-journald"] for c in calls), (r, calls))
fstab = open(ffsys.FSTAB_PATH).read()
check("first run: fstab line added once, old lines kept", fstab.count(ffsys.JOURNAL_MOUNT) == 1 and fstab.startswith("UUID=abc") and fstab.endswith("\n"), fstab)
check("message says what was done", "fstab line added" in r["message"] and "next start" in r["message"], r["message"])
calls.clear()
r2 = ffsys.blackbox_setup()
check("second run: nothing to do, no mount, no restart", r2.get("ok") is True and not any(c[0] == "mount" for c in calls) and not any(c[0] == "systemctl" for c in calls) and "already" in r2["message"], (r2, calls))
check("second run: fstab unchanged", open(ffsys.FSTAB_PATH).read() == fstab)

print("all good" if fails == 0 else f"{fails} FAILED")
sys.exit(1 if fails else 0)
