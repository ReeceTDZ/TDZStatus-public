#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
DEST="$HOME/Applications/TDZStatus.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto TDZStatus.app "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
