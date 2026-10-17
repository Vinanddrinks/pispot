#!/bin/bash
# Render one now-playing frame locally (no Pi needed) with real lyrics/bio lookups.
#   tools/preview.sh OUT.png TITLE ARTIST ALBUM DURATION_MS POSITION_MS [COVER_URL] [WxH]
# Needs: python3-pygame python3-fonttools fonts-dejavu-core fonts-noto-cjk
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 6 ] || { sed -n 2,4p "$0"; exit 1; }
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
python3 - "$d" "$@" <<'PY'
import json, sys, time
d, out, name, artist, album, dur, pos = sys.argv[1:8]
cover = sys.argv[8] if len(sys.argv) > 8 else ""
json.dump({"id": name, "type": "Track", "name": name, "artists": [artist], "album": album,
           "covers": [cover] if cover else [], "duration_ms": int(dur)}, open(d + "/track.json", "w"))
json.dump({"playing": True, "position_ms": int(pos), "at": time.time()}, open(d + "/state.json", "w"))
PY
NP_DIR="$d" python3 -W ignore display/nowplaying.py --render "$1" "${8:-1920x1080}"
echo "wrote $1"
