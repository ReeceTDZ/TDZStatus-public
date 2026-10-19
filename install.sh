#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
DEST="$HOME/Applications/TDZStatus.app"
mkdir -p "$HOME/Applications"
if pgrep -x TDZStatus >/dev/null 2>&1; then
    osascript -e 'tell application id "com.reecedove.tdzstatus" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do
        if ! pgrep -x TDZStatus >/dev/null 2>&1; then break; fi
        sleep 0.25
    done
    if pgrep -x TDZStatus >/dev/null 2>&1; then
        pkill -TERM -x TDZStatus || true
    fi
fi
rm -rf "$DEST"
ditto TDZStatus.app "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
