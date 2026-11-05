# Test harness — test FlashBridge without a printer

Lives in the repo at `tests/harness/` (STATUS task 3). Scripts take paths as arguments; nothing depends on where the repo is.

Runs the real bridge (this repo) against a simulated Creator 5 Pro and a fake AI service, and drives the web page in headless Chromium. Proven working from a fresh clone on 2026-11-01.

**It does not prove the real printer accepts a file** — the simulator accepts anything. For that, use `scripts/compare-3mf.py` against `C:\FlashBridge\reference\`.

## What's here

| Path | What |
|---|---|
| `up.sh` / `down.sh` | Start / stop the stack. |
| `sim/c5sim.dart` (+ `sim_assets.dart`) | Creator 5 Pro simulator: HTTP API on :8898 (serial `SNC5TEST01`, check code `12345678`, 4 slots), MJPEG camera on :8080. Prints `UPLOAD …`/`PRINT …`/`CONTROL …` lines to its log. |
| `seed/` | Starting settings for a fresh data folder (one printer pointing at the simulator, slicer printer model). |
| `models/vase.3mf` | Test model (a 200k-triangle vase, single colour; slices in ~1–2 min). |
| `scripts/e2e.js` | Slicer page → load vase → Preview (slices with the real engine) → checks the AI service pauses during slicing and resumes. Optional 3rd arg `kill`: kills the engine mid-slice like the OOM killer. |
| `scripts/sendprint.js` | Slices the vase, opens Print…, presses Start print, checks the page switches to the camera view and the board logged the print. Screenshot: `$FB_OUT/sendprint.png`. |
| `scripts/stages.js` | Starts a print of an existing board file and samples the home card at 3/9/17/24/34 s (sending → unpacking → printing). Pair with the simulator's slow mode (below). |
| `scripts/compare-3mf.py` | Compares a FlashBridge `.gcode.3mf` with a stock OrcaSlicer one, item by item (the "matches stock Orca" check: 0 differences required). |
| `scripts/stall_test.py` | Opens camera-stream connections that never read and watches the bridge's memory: proves a slow viewer cannot make the bridge grow (2026-11-04). `python3 -I scripts/stall_test.py http://localhost:8088 3 60`. |

## Setting up (in your cloud workspace)

1. Code: `git clone --depth 1 https://github.com/thefrayedend/FlashBridge.git /tmp/fb` — the harness is in it at `/tmp/fb/tests/harness`.
2. (nothing to copy)
3. Dart SDK 3.x at `/opt/dart-sdk` (check `dart --version`; the scripts add `/opt/dart-sdk/bin` to PATH). If missing, install the Linux x64 SDK zip from the official Dart archive (storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-x64-release.zip). If that host is blocked, report it to the Coordinator — don't hunt for mirrors.
4. Node with Playwright (`require('playwright')`). If `chromium.launch()` complains about a missing browser, set `CHROMIUM=/opt/pw-browsers/chromium` (or wherever the installed Chromium is) — don't run `playwright install`.
5. Slicer engine (only for slicing tests): the x86_64 build of our fork from https://github.com/thefrayedend/slicer-cli/releases (tag `slicer-cli/v0.1.0-dev-19-ffb1`, file `slicer-cli-v0.1.0-dev-19-ffb1-linux-x86_64.tar.gz`: https://github.com/thefrayedend/slicer-cli/releases/download/slicer-cli/v0.1.0-dev-19-ffb1/slicer-cli-v0.1.0-dev-19-ffb1-linux-x86_64.tar.gz). Unpack it; the folder with `bin/slicer_cli-orcaslicer` is your `<engine-dir>`.
6. Python 3 (for the fake AI service and compare-3mf.py).

## Running

```
bash up.sh /tmp/fb <engine-dir> /tmp/fbtest     # starts everything; the web page is http://localhost:8088
                                               # SIM_CAM_MS=10 bash up.sh ...  → a fast (100 fps) simulated camera for load tests
cd <harness> && NODE_PATH=$(npm root -g) node scripts/sendprint.js <harness>
NODE_PATH=$(npm root -g) node scripts/e2e.js <harness>
python3 -I scripts/compare-3mf.py /tmp/fbtest/data/printers/*/gcodes/<file>.gcode.3mf <reference.gcode.3mf>
bash down.sh
```

`up.sh` fetches the slicer page's 3D libraries the first time (`pi-bridge/slicer/fetch-web-vendor.sh` — the build does the same; they are not stored in the repo). Logs: `/tmp/fbtest/{sim,ai,bridge}.log`. Data folder: `/tmp/fbtest/data` (delete it for a clean start).

Between print tests, end the simulated print: `curl -X POST localhost:8088/api/printers/<id>/control -H 'Content-Type: application/json' -d '{"action":"cancel"}'`, then `{"action":"clear"}`.

## Simulator test hooks

Add these to a copy of `c5sim.dart` when needed (keep the original; don't leave hooks in):
- Slow upload + unpacking stage: in `/uploadGcode`, wait 12 s before reading, set `st['status'] = 'unzipping'` and start the print 10 s later.
- Refusals: return `{'code': 1, 'message': 'Storage full'}` from `/uploadGcode` or `{'code': 1, 'message': 'File is damaged'}` from `/printGcode`.
- Status override: a `simStatus_cmd` case in `/control` that sets `st['status']`.
- Hang-up mid-upload: see `pi-bridge/bridge/test/upload_hangup_check.dart` (a raw-socket fake printer).

## Stopping processes safely

Use `down.sh`. Never `pkill -f <pattern>` with a pattern that also appears in your own command line — it kills your own shell. `down.sh` uses `pgrep -f '[p]ibridge.dart'` (the bracket trick) and separate steps.
