#!/bin/bash
# Regenerate the README screenshots in docs/screenshots/ (no Pi needed).
# Everything shown is free to publish:
#   - "Monkeys Spinning Monkeys" by Kevin MacLeod (incompetech.com), CC BY 4.0.
#     Instrumental, so the panel shows his Wikipedia summary (CC BY-SA 4.0).
#   - 「さくらさくら」 (Sakura Sakura), traditional Japanese song, 1888 lyrics,
#     public domain; demo timings below.
#   - Cover art is drawn here, not taken from any release.
# Needs: python3-pygame python3-fonttools fonts-dejavu-core fonts-noto-cjk
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=docs/screenshots
SIZE=${SIZE:-1280x720}
mkdir -p "$OUT"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- cover art -----------------------------------------------------------
SDL_VIDEODRIVER=dummy PYGAME_HIDE_SUPPORT_PROMPT=1 python3 -W ignore - "$tmp" <<'PY'
import math, random, sys
import pygame
d = sys.argv[1]
pygame.display.init()
N = 640


def gradient(top, bottom):
    s = pygame.Surface((N, N))
    for y in range(N):
        t = y / (N - 1)
        s.fill([int(a + (b - a) * t) for a, b in zip(top, bottom)], (0, y, N, 1))
    return s


# Monkeys Spinning Monkeys: spinning rings of circles on a warm gradient
s = gradient((255, 196, 61), (233, 84, 32))
c = N / 2
for ring in range(7):
    r = 40 + ring * 38
    n = 6 + ring * 4
    for k in range(n):
        a = 2 * math.pi * k / n + ring * 0.45
        x, y = c + r * math.cos(a), c + r * math.sin(a)
        size = 14 + ring * 2
        col = (90, 40, 20) if (k + ring) % 2 else (255, 240, 200)
        pygame.draw.circle(s, col, (int(x), int(y)), size)
pygame.draw.circle(s, (90, 40, 20), (int(c), int(c)), 26)
pygame.draw.circle(s, (255, 240, 200), (int(c), int(c)), 12)
pygame.image.save(s, f"{d}/monkeys.png")

# Sakura Sakura: night sky, moon and five-petal blossoms
random.seed(7)
s = gradient((32, 36, 78), (224, 120, 160))
pygame.draw.circle(s, (255, 244, 220), (470, 160), 70)


def blossom(x, y, r, col):
    for k in range(5):
        a = 2 * math.pi * k / 5 - math.pi / 2
        pygame.draw.circle(s, col, (int(x + r * 0.55 * math.cos(a)), int(y + r * 0.55 * math.sin(a))), int(r * 0.5))
    pygame.draw.circle(s, (240, 90, 130), (int(x), int(y)), int(r * 0.22))


for _ in range(26):
    blossom(random.randint(20, N - 20), random.randint(300, N - 10), random.randint(22, 46),
            random.choice([(255, 214, 228), (255, 190, 210), (250, 230, 238)]))
pygame.image.save(s, f"{d}/sakura.png")
PY

# --- demo lyrics (public domain, 1888 version) ---------------------------
cat > "$tmp/sakura.lrc" <<'EOF'
[00:04.00]さくら さくら
[00:10.00]弥生の空は
[00:16.00]見わたす限り
[00:22.00]霞か雲か
[00:28.00]匂いぞ出ずる
[00:34.00]いざや いざや
[00:40.00]見にゆかん
[00:48.00]Sakura, sakura
[00:54.00]Across the spring sky
[01:00.00]As far as the eye can see
[01:06.00]Is it mist, or clouds?
[01:12.00]Fragrant in the air
[01:18.00]Come now, come now
[01:24.00]Let's go and see
EOF

# --- a speaker config for the status line --------------------------------
cat > "$tmp/conf" <<'EOF'
LIBRESPOT_NAME="Living Room"
LIBRESPOT_BITRATE=320
LIBRESPOT_FORMAT=S32
EOF
export RASPOTIFY_CONF="$tmp/conf"

render() { # out title artist album dur_ms pos_ms cover [lrc]
  local np="$tmp/np-$RANDOM"
  mkdir -p "$np"
  python3 - "$np" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import json, sys, time
d, name, artist, album, dur, pos, cover = sys.argv[1:8]
json.dump({"id": name, "type": "Track", "name": name, "artists": [artist], "album": album,
           "covers": [cover], "duration_ms": int(dur)}, open(d + "/track.json", "w"))
json.dump({"playing": True, "position_ms": int(pos), "at": time.time()}, open(d + "/state.json", "w"))
PY
  NP_DIR="$np" NP_LYRICS="${8:-}" NP_LYRICS_SOURCE="PUBLIC DOMAIN" python3 -W ignore display/nowplaying.py --render "$1" "$SIZE"
  echo "wrote $1"
}

render "$OUT/artist-bio.png" "Monkeys Spinning Monkeys" "Kevin MacLeod" "Royalty Free" \
  123000 52000 "file://$tmp/monkeys.png"
render "$OUT/synced-lyrics.png" "さくらさくら (Sakura Sakura)" "Traditional" "Japanese Folk Songs" \
  92000 23500 "file://$tmp/sakura.png" "$tmp/sakura.lrc"
NP_DIR="$tmp/empty" python3 -W ignore display/nowplaying.py --render "$OUT/idle.png" "$SIZE"
echo "wrote $OUT/idle.png"
