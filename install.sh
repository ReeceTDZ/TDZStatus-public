#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
DEST="$HOME/Applications/TDZStatus Public.app"
mkdir -p "$HOME/Applications"
if pgrep -x TDZStatusPublic >/dev/null 2>&1; then
    osascript -e 'tell application id "com.reecedove.tdzstatus.public" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do
        if ! pgrep -x TDZStatusPublic >/dev/null 2>&1; then break; fi
        sleep 0.25
    done
    if pgrep -x TDZStatusPublic >/dev/null 2>&1; then
        echo "Quit TDZStatus Public before installing." >&2
        exit 1
    fi
fi
rm -rf "$DEST"
ditto "TDZStatus Public.app" "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
