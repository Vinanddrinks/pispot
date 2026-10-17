#!/bin/bash
# Grab what the speaker's screen is currently showing.
#   tools/screenshot.sh [user@host] [out.png]
set -euo pipefail
HOST="${1:-pi@pispot.local}"
OUT="${2:-nowplaying-shot.png}"
ssh "$HOST" 'sudo systemctl kill -s USR1 nowplaying && sleep 2'
scp -q "$HOST":/run/nowplaying-shot.png "$OUT"
echo "wrote $OUT"
