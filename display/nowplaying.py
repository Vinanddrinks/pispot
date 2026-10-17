#!/usr/bin/python3
# Full-screen "now playing" display for the A206 Spotify Connect speaker.
# Reads state written by /usr/local/bin/nowplaying-event (librespot --onevent),
# shows cover art, synced lyrics (LRCLIB) or an artist bio (Wikipedia), and the
# track info under the progress bar.
#
#   nowplaying.py                         run on the Pi, draw to /dev/fb0
#   nowplaying.py --render out.png [WxH]  draw one frame from NP_DIR to a PNG
import io, json, os, re, signal, sys, threading, time, urllib.parse, urllib.request

os.environ["SDL_VIDEODRIVER"] = "dummy"  # render off-screen, push frames to /dev/fb0
os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
import pygame

NP_DIR = os.environ.get("NP_DIR", "/run/raspotify/np")
RASPOTIFY_CONF = os.environ.get("RASPOTIFY_CONF", "/etc/raspotify/conf")
UA = "A206-nowplaying/1.0 (Raspberry Pi Spotify Connect display)"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
# Fallback for Japanese / Chinese / Korean (fonts-noto-cjk); .ttc face 0 = JP
CJK = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
CJK_B = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
WHITE, DIM, FAINT, ACCENT = (245, 245, 245), (170, 170, 170), (110, 110, 115), (30, 215, 96)
LYRICS_LEAD_MS = 250  # show a lyric line slightly early to cover output latency
MUSIC_WORDS = ("singer", "band", "musician", "rapper", "composer", "group", "duo",
               "producer", "songwriter", "dj", "vocalist", "artist", "idol", "orchestra",
               "歌手", "バンド", "音楽", "ユニット", "作曲", "가수", "그룹", "乐队", "歌手")


def load(name):
    try:
        with open(os.path.join(NP_DIR, name + ".json")) as f:
            return json.load(f)
    except Exception:
        return {}


def player_conf():
    """Speaker name / bitrate / format as set by a206-config (re-read each frame
    is cheap: the file is tiny and lives in the page cache)."""
    c = {"LIBRESPOT_NAME": "A206", "LIBRESPOT_BITRATE": "320", "LIBRESPOT_FORMAT": "S16"}
    try:
        for line in open(RASPOTIFY_CONF):
            k, sep, v = line.strip().partition("=")
            if sep and not k.startswith("#"):
                c[k] = v.strip('"')
    except OSError:
        pass
    return c


def fmt(ms):
    s = max(0, int(ms // 1000))
    return f"{s // 60}:{s % 60:02d}"


def http_json(url, timeout=10):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


class Covers:
    """Downloads cover art in the background, keeps the last one."""

    def __init__(self):
        self.url, self.img = None, None

    def want(self, urls):
        url = urls[0] if urls else None
        if url == self.url:
            return
        self.url, self.img = url, None
        if url:
            threading.Thread(target=self._fetch, args=(url,), daemon=True).start()

    def _fetch(self, url):
        for _ in range(3):
            try:
                data = urllib.request.urlopen(url, timeout=10).read()
                img = pygame.image.load(io.BytesIO(data)).convert()
                if self.url == url:
                    self.img = img
                return
            except Exception:
                time.sleep(2)


def parse_lrc(text):
    """LRC → sorted [(ms, line)]; a line may carry several timestamps."""
    out = []
    for raw in text.splitlines():
        stamps = re.findall(r"\[(\d+):(\d+(?:\.\d+)?)\]", raw)
        line = re.sub(r"\[[^\]]*\]", "", raw).strip()
        for m, s in stamps:
            out.append((int((int(m) * 60 + float(s)) * 1000), line or "♪"))
    return sorted(out)


# Credit lines some uploads prepend ("作词 : …", "Lyrics by …")
CREDIT = re.compile(r"^\s*(作词|作詞|作曲|编曲|編曲|词|曲|Lyrics?( by)?|Composer|Composed by|Written by|"
                    r"Lời|Nhạc|작사|작곡|편곡)\s*[:：]", re.I)


def lrc_penalty(c, dur):
    """Lower is better: prefer clean, original-language uploads of the right length.
    Translated uploads interleave a second line under the same timestamp."""
    text = c.get("syncedLyrics") or c.get("plainLyrics") or ""
    lines = parse_lrc(text) if c.get("syncedLyrics") else [(0, l) for l in text.splitlines()]
    stamps = [ms for ms, _ in lines]
    dupes = len(stamps) - len(set(stamps)) if c.get("syncedLyrics") else 0
    credits = sum(1 for _, l in lines if CREDIT.match(l))
    return dupes * 3 + credits * 2 + text.count("→") * 3 + abs((c.get("duration") or dur) - dur) / 5


def has_cjk(text):
    return any("぀" <= c <= "鿿" or "가" <= c <= "힯" for c in text)


class Info:
    """Per-track side panel content: synced lyrics, plain lyrics or artist bio."""

    def __init__(self):
        self.key, self.data = None, None
        self._cache = {}

    def want(self, track):
        key = track.get("id") or track.get("name")
        if key == self.key:
            return
        self.key = key
        self.data = self._cache.get(key)
        if self.data is None:
            threading.Thread(target=self._fetch, args=(key, dict(track)), daemon=True).start()

    def _fetch(self, key, track):
        data = None
        try:
            data = self._lyrics(track)
        except Exception:
            pass
        if not data:
            try:
                data = self._bio((track.get("artists") or [""])[0])
            except Exception:
                pass
        data = data or {"kind": "none"}
        self._cache[key] = data
        if self.key == key:
            self.data = data

    def _lyrics(self, track):
        name, artist = track.get("name", ""), (track.get("artists") or [""])[0]
        if not name or not artist:
            return None
        dur = track.get("duration_ms", 0) / 1000
        q = {"track_name": name, "artist_name": artist}
        cands = []
        try:
            exact = dict(q, album_name=track.get("album", ""), duration=round(dur))
            cands.append(http_json("https://lrclib.net/api/get?" + urllib.parse.urlencode(exact)))
        except Exception:
            pass
        try:
            cands += http_json("https://lrclib.net/api/search?" + urllib.parse.urlencode(q))
        except Exception:
            pass
        if dur:
            cands = [c for c in cands if abs((c.get("duration") or dur) - dur) <= 5] or cands
        if any(c.get("instrumental") for c in cands[:1]):
            return None  # let the artist bio take the panel
        synced = [c for c in cands if c.get("syncedLyrics")]
        if synced:
            best = min(synced, key=lambda c: lrc_penalty(c, dur))
            lines = [(ms, l) for ms, l in parse_lrc(best["syncedLyrics"]) if not CREDIT.match(l)]
            if lines:
                return {"kind": "synced", "lines": lines}
        plain = [c for c in cands if c.get("plainLyrics")]
        if plain:
            best = min(plain, key=lambda c: lrc_penalty(c, dur))
            text = "\n".join(l for l in best["plainLyrics"].splitlines() if not CREDIT.match(l.strip()))
            return {"kind": "plain", "text": text.strip()}
        return None

    def _bio(self, artist):
        if not artist:
            return None
        langs = ["ja", "en"] if has_cjk(artist) else ["en"]
        for lang in langs:
            base = f"https://{lang}.wikipedia.org"
            titles = [artist]
            try:
                s = http_json(base + "/w/api.php?" + urllib.parse.urlencode({
                    "action": "query", "list": "search", "format": "json", "srlimit": 5,
                    "srsearch": artist if lang == "ja" else f"{artist} musician OR band OR singer"}))
                titles += [r["title"] for r in s["query"]["search"]]
            except Exception:
                pass
            for t in titles:
                try:
                    p = http_json(base + "/api/rest_v1/page/summary/" + urllib.parse.quote(t.replace(" ", "_")))
                except Exception:
                    continue
                desc = (p.get("description") or "") + " " + (p.get("extract") or "")[:300]
                if p.get("type") == "standard" and p.get("extract") and \
                        any(w in desc.lower() for w in MUSIC_WORDS):
                    return {"kind": "bio", "title": p.get("title", artist), "text": p["extract"]}
        return None


class MFont:
    """pygame Font with per-character fallback (DejaVu first, then CJK)."""
    _cmaps = {}

    def __init__(self, paths, size):
        paths = [p for p in paths if os.path.exists(p)]
        self.fonts = [pygame.font.Font(p, size) for p in paths]
        # Real glyph coverage (pygame reports metrics even for missing glyphs);
        # the last font is the catch-all, so its table isn't needed
        self.cover = [self._cmap(p) for p in paths[:-1]]
        self._cache = {}

    @classmethod
    def _cmap(cls, path):
        if path not in cls._cmaps:
            from fontTools.ttLib import TTFont
            cls._cmaps[path] = set(TTFont(path, fontNumber=0, lazy=True).getBestCmap())
        return cls._cmaps[path]

    def _runs(self, text):
        runs = []
        for ch in text:
            idx = len(self.fonts) - 1
            for i, cov in enumerate(self.cover):
                if ch.isspace() or ord(ch) in cov:
                    idx = i
                    break
            if runs and runs[-1][0] == idx:
                runs[-1][1] += ch
            else:
                runs.append([idx, ch])
        return [(self.fonts[i], t) for i, t in runs]

    def size(self, text):
        runs = self._runs(text) or [(self.fonts[0], "")]
        w = sum(f.size(t)[0] for f, t in runs)
        asc = max(f.get_ascent() for f, _ in runs)
        desc = max(-f.get_descent() for f, _ in runs)
        return w, asc + desc

    def linesize(self):
        return max(f.get_linesize() for f in self.fonts)

    def render(self, text, aa, color):
        key = (text, color)
        if key in self._cache:
            return self._cache[key]
        runs = self._runs(text) or [(self.fonts[0], "")]
        asc = max(f.get_ascent() for f, _ in runs)
        surf = pygame.Surface(self.size(text), pygame.SRCALPHA)
        x = 0
        for f, t in runs:
            r = f.render(t, aa, color)
            surf.blit(r, (x, asc - f.get_ascent()))
            x += r.get_width()
        if len(self._cache) > 400:
            self._cache.clear()
        self._cache[key] = surf
        return surf


def fit(font, text, width):
    if font.size(text)[0] <= width:
        return text
    while text and font.size(text + "…")[0] > width:
        text = text[:-1]
    return text + "…"


def wrap(font, text, width):
    """Word-wrap; CJK characters may break anywhere, over-long words are split."""
    out = []
    for para in text.split("\n"):
        tokens = re.findall(r"[぀-ヿ㐀-鿿가-힯＀-￯]|\S+\s*|\s+", para)
        line = ""
        for tok in tokens:
            if font.size(line + tok)[0] <= width:
                line += tok
                continue
            if line.strip():
                out.append(line.rstrip())
            line = tok.lstrip()
            while font.size(line)[0] > width and len(line) > 1:
                cut = len(line)
                while cut > 1 and font.size(line[:cut])[0] > width:
                    cut -= 1
                out.append(line[:cut])
                line = line[cut:]
        out.append(line.rstrip())
    return out


def blurred(img, size):
    small = pygame.transform.smoothscale(img, (24, 24))
    big = pygame.transform.smoothscale(small, size)
    shade = pygame.Surface(size)
    shade.set_alpha(160)
    big.blit(shade, (0, 0))
    return big


class Display:
    def __init__(self, W, H):
        self.W, self.H = W, H
        self.screen = pygame.Surface((W, H))
        u = self.u = H / 100
        self.f_title = MFont((FONT_B, CJK_B), int(5.6 * u))
        self.f_artist = MFont((FONT, CJK), int(3.6 * u))
        self.f_small = MFont((FONT, CJK), int(2.4 * u))
        self.f_lyric = MFont((FONT, CJK), int(3.3 * u))
        self.f_lyric_now = MFont((FONT_B, CJK_B), int(3.9 * u))
        self.f_bio = MFont((FONT, CJK), int(2.7 * u))
        self.f_clock = MFont((FONT_B, CJK_B), int(18 * u))
        self.covers, self.info = Covers(), Info()
        self._bg = self._cover = (None, None)
        self._wrapped = (None, None)

    def frame(self, now):
        """Draw one frame; returns the fps the caller should run at."""
        S, W, H, u = self.screen, self.W, self.H, self.u
        track, state, vol = load("track"), load("state"), load("volume")
        active = bool(track) and not state.get("stopped") and (
            state.get("playing") or now - state.get("at", 0) < 600)

        pc = player_conf()
        speaker = pc["LIBRESPOT_NAME"]
        S.fill((12, 12, 14))
        if not active:
            t = self.f_clock.render(time.strftime("%H:%M", time.localtime(now)), True, WHITE)
            S.blit(t, t.get_rect(center=(W // 2, H * 0.42)))
            s = self.f_artist.render(f"{speaker}  ·  Spotify Connect", True, ACCENT)
            S.blit(s, s.get_rect(center=(W // 2, H * 0.62)))
            s = self.f_small.render("Select this speaker in the Spotify app", True, DIM)
            S.blit(s, s.get_rect(center=(W // 2, H * 0.70)))
            return 1

        self.covers.want(track.get("covers", []))
        self.info.want(track)
        art = self.covers.img

        # Layout: cover top-left, lyrics/bio panel to its right,
        # progress bar across, then title and artist · album underneath
        mx = int(W * 0.055)
        top = int(9 * u)
        side = int(min(H * 0.55, W * 0.36))
        if art is not None:
            if self._bg[0] is not art:
                self._bg = (art, blurred(art, (W, H)))
                self._cover = (art, pygame.transform.smoothscale(art, (side, side)))
            S.blit(self._bg[1], (0, 0))
            S.blit(self._cover[1], (mx, top))
        else:
            pygame.draw.rect(S, (40, 40, 44), (mx, top, side, side))

        dur = track.get("duration_ms", 0)
        pos = state.get("position_ms", 0)
        if state.get("playing"):
            pos += (now - state.get("at", now)) * 1000
        pos = min(pos, dur) if dur else pos

        px = mx + side + int(W * 0.04)
        self.panel(pygame.Rect(px, top, W - mx - px, side), track, pos, dur)

        bx, bw, bh = mx, W - 2 * mx, max(4, int(0.7 * u))
        by = top + side + int(4.5 * u)
        pygame.draw.rect(S, (90, 90, 95), (bx, by, bw, bh), border_radius=bh)
        if dur:
            pygame.draw.rect(S, WHITE, (bx, by, int(bw * pos / dur), bh), border_radius=bh)
        for text, anchor, x in ((fmt(pos), "topleft", bx), (fmt(dur), "topright", bx + bw)):
            s = self.f_small.render(text, True, DIM)
            S.blit(s, s.get_rect(**{anchor: (x, by + bh + int(u))}))

        y = by + bh + int(5 * u)
        title = self.f_title.render(fit(self.f_title, track.get("name", ""), bw), True, WHITE)
        S.blit(title, (bx, y))
        y += title.get_height() + int(0.8 * u)
        sub = ", ".join(a for a in track.get("artists", []) if a)
        if track.get("album"):
            sub += ("  ·  " if sub else "") + track["album"]
        s = self.f_artist.render(fit(self.f_artist, sub, bw), True, DIM)
        S.blit(s, (bx, y))

        status = ("▶ " if state.get("playing") else "❚❚ ") + \
            f"{speaker}  ·  {pc['LIBRESPOT_BITRATE']} kbps  ·  {pc['LIBRESPOT_FORMAT']}"
        if vol and now - vol.get("at", 0) < 4:
            status += f"  ·  volume {vol.get('volume', 0)}%"
        s = self.f_small.render(status, True, ACCENT)
        S.blit(s, (mx, int(3 * u)))
        synced = (self.info.data or {}).get("kind") == "synced"
        return 8 if synced and state.get("playing") else 4

    def panel(self, r, track, pos, dur):
        S, u = self.screen, self.u
        data = self.info.data
        kind = (data or {}).get("kind")
        head = {"synced": "LYRICS", "plain": "LYRICS", "bio": "ABOUT THE ARTIST"}.get(kind)
        if data is None:
            head = "LOOKING UP LYRICS…"
        if head:
            s = self.f_small.render(head, True, ACCENT)
            S.blit(s, (r.x, r.y))
        body = pygame.Rect(r.x, r.y + int(4.5 * u), r.w, r.h - int(4.5 * u))
        prev_clip = S.get_clip()
        S.set_clip(body)

        if kind == "synced":
            lines = data["lines"]
            t = pos + LYRICS_LEAD_MS
            cur = max((i for i, (ms, _) in enumerate(lines) if ms <= t), default=-1)
            gap = int(1.4 * u)
            # current line sits at 40% of the panel; draw outward from it
            anchor = body.y + int(body.h * 0.40)
            blocks = {}

            def block(i):
                if i not in blocks:
                    f = self.f_lyric_now if i == cur else self.f_lyric
                    col = WHITE if i == cur else (DIM if i > cur else FAINT)
                    blocks[i] = [f.render(l, True, col) for l in wrap(f, lines[i][1], body.w)]
                return blocks[i]

            def height(i):
                return sum(s.get_height() for s in block(i)) + gap

            if cur < 0:  # before the first line: show the upcoming ones
                y, i = anchor, 0
            else:
                y, i = anchor, cur
            # only whole lines: stop before one would be cut by the panel edge
            while i < len(lines) and y + height(i) - gap <= body.bottom:
                for s in block(i):
                    S.blit(s, (body.x, y))
                    y += s.get_height()
                y += gap
                i += 1
            y, i = anchor, (cur if cur >= 0 else 0) - 1
            while i >= 0 and y - height(i) >= body.y:
                y -= height(i)
                yy = y
                for s in block(i):
                    S.blit(s, (body.x, yy))
                    yy += s.get_height()
                i -= 1
        elif kind in ("plain", "bio"):
            f = self.f_bio if kind == "bio" else self.f_lyric
            text = data["text"]
            if kind == "bio":
                t = self.f_artist.render(fit(self.f_artist, data["title"], body.w), True, WHITE)
                S.blit(t, (body.x, body.y))
                body = pygame.Rect(body.x, body.y + t.get_height() + int(1.5 * u),
                                   body.w, body.h - t.get_height() - int(1.5 * u))
                S.set_clip(body)
            if self._wrapped[0] != (text, body.w, kind):
                self._wrapped = ((text, body.w, kind), wrap(f, text, body.w))
            wl = self._wrapped[1]
            lh = f.linesize()
            total = len(wl) * lh
            # unsynced lyrics scroll with song progress; a bio is cut to fit
            off = 0
            if kind == "plain" and total > body.h and dur:
                off = int((total - body.h) * min(1, max(0, (pos - 15000) / max(1, dur - 30000))))
            elif kind == "bio" and total > body.h:
                keep = body.h // lh
                wl = wl[:keep - 1] + [fit(f, wl[keep - 1] + "…", body.w)] if keep else []
            y = body.y - off
            for line in wl:
                if body.y - lh <= y <= body.bottom:
                    S.blit(f.render(line, True, WHITE if kind == "bio" else DIM), (body.x, y))
                y += lh
        S.set_clip(prev_clip)


def main():
    pygame.display.init()
    pygame.font.init()
    pygame.display.set_mode((1, 1))

    if len(sys.argv) > 2 and sys.argv[1] == "--render":
        W, H = map(int, (sys.argv[3] if len(sys.argv) > 3 else "1920x1080").split("x"))
        d = Display(W, H)
        d.frame(time.time())
        for _ in range(150):  # wait up to 15 s for cover + lyrics/bio
            if d.covers.img is not None and d.info.data is not None:
                break
            time.sleep(0.1)
        d.frame(time.time())
        pygame.image.save(d.screen, sys.argv[2])
        return

    W, H = (int(x) for x in open("/sys/class/graphics/fb0/virtual_size").read().split(","))
    bpp = int(open("/sys/class/graphics/fb0/bits_per_pixel").read())
    d = Display(W, H)
    out = pygame.Surface((W, H), 0, bpp)  # 16 bpp = RGB565, matches vc4drmfb
    fb = open("/dev/fb0", "r+b", buffering=0)
    try:
        with open("/sys/class/graphics/fbcon/cursor_blink", "w") as f:
            f.write("0")
    except OSError:
        pass
    shot = []  # `systemctl kill -s USR1 nowplaying` saves /run/nowplaying-shot.png
    signal.signal(signal.SIGUSR1, lambda *a: shot.append(1))
    clock = pygame.time.Clock()
    while True:
        fps = d.frame(time.time())
        out.blit(d.screen, (0, 0))
        fb.seek(0)
        fb.write(out.get_buffer().raw)
        if shot:
            shot.clear()
            pygame.image.save(d.screen, "/run/nowplaying-shot.png")
        clock.tick(fps)


if __name__ == "__main__":
    main()
