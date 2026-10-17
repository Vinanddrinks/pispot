#!/usr/bin/python3
# Full-screen "now playing" display for the A206 Spotify Connect speaker.
# Reads state written by /usr/local/bin/nowplaying-event (librespot --onevent).
import io, json, os, threading, time, urllib.request

os.environ["SDL_VIDEODRIVER"] = "dummy"  # render off-screen, push frames to /dev/fb0
os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
import pygame

NP_DIR = "/run/raspotify/np"
SPEAKER = "A206"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
WHITE, DIM, ACCENT = (245, 245, 245), (170, 170, 170), (30, 215, 96)


def load(name):
    try:
        with open(os.path.join(NP_DIR, name + ".json")) as f:
            return json.load(f)
    except Exception:
        return {}


def fmt(ms):
    s = max(0, int(ms // 1000))
    return f"{s // 60}:{s % 60:02d}"


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


def blurred(img, size):
    small = pygame.transform.smoothscale(img, (24, 24))
    big = pygame.transform.smoothscale(small, size)
    shade = pygame.Surface(size)
    shade.set_alpha(150)
    big.blit(shade, (0, 0))
    return big


def fit(font, text, width):
    if font.size(text)[0] <= width:
        return text
    while text and font.size(text + "…")[0] > width:
        text = text[:-1]
    return text + "…"


def main():
    pygame.display.init()
    pygame.font.init()
    pygame.mouse.set_visible(False)
    W, H = (int(x) for x in open("/sys/class/graphics/fb0/virtual_size").read().split(","))
    bpp = int(open("/sys/class/graphics/fb0/bits_per_pixel").read())
    pygame.display.set_mode((1, 1))
    screen = pygame.Surface((W, H))
    out = pygame.Surface((W, H), 0, bpp)  # 16 bpp = RGB565, matches vc4drmfb
    fb = open("/dev/fb0", "r+b", buffering=0)
    with open("/sys/class/graphics/fbcon/cursor_blink", "w") as f:
        f.write("0")

    def flip():
        out.blit(screen, (0, 0))
        fb.seek(0)
        fb.write(out.get_buffer().raw)
    u = H / 100
    f_title = pygame.font.Font(FONT_B, int(6.5 * u))
    f_artist = pygame.font.Font(FONT, int(4.6 * u))
    f_album = pygame.font.Font(FONT, int(3.4 * u))
    f_small = pygame.font.Font(FONT, int(2.6 * u))
    f_clock = pygame.font.Font(FONT_B, int(18 * u))
    covers = Covers()
    bg_for, bg = None, None
    clock = pygame.time.Clock()

    while True:
        for e in pygame.event.get():
            if e.type == pygame.QUIT:
                return
        track, state, vol = load("track"), load("state"), load("volume")
        now = time.time()
        active = bool(track) and not state.get("stopped") and (
            state.get("playing") or now - state.get("at", 0) < 600)

        screen.fill((12, 12, 14))
        if not active:
            t = f_clock.render(time.strftime("%H:%M"), True, WHITE)
            screen.blit(t, t.get_rect(center=(W // 2, H * 0.42)))
            s = f_artist.render(f"{SPEAKER}  ·  Spotify Connect", True, ACCENT)
            screen.blit(s, s.get_rect(center=(W // 2, H * 0.62)))
            s = f_small.render("Select this speaker in the Spotify app", True, DIM)
            screen.blit(s, s.get_rect(center=(W // 2, H * 0.70)))
            flip()
            clock.tick(1)
            continue

        covers.want(track.get("covers", []))
        art = covers.img
        if art is not None and bg_for is not art:
            bg, bg_for = blurred(art, (W, H)), art
        if art is not None:
            screen.blit(bg, (0, 0))

        side = int(min(H * 0.62, W * 0.42))
        ax, ay = int(W * 0.06), (H - side) // 2 - int(4 * u)
        if art is not None:
            screen.blit(pygame.transform.smoothscale(art, (side, side)), (ax, ay))
        else:
            pygame.draw.rect(screen, (40, 40, 44), (ax, ay, side, side))

        tx = ax + side + int(W * 0.05)
        tw = W - tx - int(W * 0.05)
        y = ay + int(side * 0.18)
        for font, text, col in ((f_title, track.get("name", ""), WHITE),
                                (f_artist, ", ".join(track.get("artists", [])), WHITE),
                                (f_album, track.get("album", ""), DIM)):
            surf = font.render(fit(font, text, tw), True, col)
            screen.blit(surf, (tx, y))
            y += surf.get_height() + int(2 * u)

        dur = track.get("duration_ms", 0)
        pos = state.get("position_ms", 0)
        if state.get("playing"):
            pos += (now - state.get("at", now)) * 1000
        pos = min(pos, dur) if dur else pos
        by, bh = ay + side + int(7 * u), max(4, int(0.8 * u))
        bx, bw = ax, W - 2 * ax
        pygame.draw.rect(screen, (90, 90, 95), (bx, by, bw, bh), border_radius=bh)
        if dur:
            pygame.draw.rect(screen, WHITE, (bx, by, int(bw * pos / dur), bh), border_radius=bh)
        for text, anchor in ((fmt(pos), "topleft"), (fmt(dur), "topright")):
            s = f_small.render(text, True, DIM)
            r = s.get_rect(**{anchor: (bx if anchor == "topleft" else bx + bw, by + bh + int(u))})
            screen.blit(s, r)

        status = ("▶ " if state.get("playing") else "❚❚ ") + f"{SPEAKER}  ·  320 kbps"
        if vol and now - vol.get("at", 0) < 4:
            status += f"  ·  volume {vol.get('volume', 0)}%"
        s = f_small.render(status, True, ACCENT)
        screen.blit(s, (ax, int(3 * u)))

        flip()
        clock.tick(4)


if __name__ == "__main__":
    main()
