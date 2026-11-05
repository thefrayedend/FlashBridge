#!/bin/bash
# Stops the test stack started by up.sh. (Uses a pattern trick so it never matches its own shell.)
for p in $(pgrep -f '[p]ibridge.dart') $(pgrep -f '[c]5sim.dart') $(pgrep -f '[f]ake_ai.py'); do kill "$p" 2>/dev/null; done
sleep 2; echo stopped
