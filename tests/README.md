# Tests

- `harness/` — the printer simulator, fake AI service, headless-browser scripts and the "matches stock OrcaSlicer"
  file check (`harness/scripts/compare-3mf.py`). See `harness/README.md`.
- Unit checks live next to the code: `pi-bridge/bridge/test/*_check.dart` (run by the build) and
  `pi-bridge/image/test/*_check.py`.
