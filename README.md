# A206 — Raspberry Pi Spotify Connect speaker

Unattended Raspberry Pi OS Lite (arm64) build that turns a Raspberry Pi 3B v1.2
into a dedicated Spotify Connect speaker on the LAN, playing over HDMI, with a
full-screen now-playing display on the same screen.

- **Audio:** [raspotify](https://github.com/dtcooper/raspotify) (librespot)
  at 320 kbps Ogg Vorbis, the most Spotify serves to non-SDK Connect devices
  (no lossless, see below). Output is S32 to the vc4 HDMI sink (24-bit on the
  wire), with no normalisation and a float soft volume starting at 100 %.
- **Display:** cover art, synced lyrics ([LRCLIB](https://lrclib.net)) or the
  artist's Wikipedia summary when there are no lyrics, with the progress bar and
  title / artist · album underneath. Japanese, Chinese and Korean text renders
  through a Noto Sans CJK fallback.
- **Appliance:** Ethernet only (Wi-Fi/BT off), SSH key login only, read-only
  root (overlayfs) so pulling the power is safe, and the services restart
  themselves if they crash.

## Layout

| Path | What |
|---|---|
| `boot/user-data`, `meta-data`, `network-config` | cloud-init seed (hostname `a206`, user `pi`, DHCP on eth0) |
| `boot/spotify-setup.sh` | first-boot script: apt (retries past captive portals), raspotify, HDMI format, display, lockdown, overlayfs |
| `display/nowplaying-event` | librespot `--onevent` hook → JSON in `/run/raspotify/np/` |
| `display/nowplaying.py` | pygame renderer → `/dev/fb0` (or `--render out.png`) |
| `display/*.service`, `*.conf` | systemd unit + raspotify drop-in setting `LIBRESPOT_ONEVENT` |
| `tools/build-image.sh` | download + verify Pi OS Lite and raspotify, patch the boot partition, optionally flash |
| `tools/deploy.sh` | push `display/` to a running speaker (unlocks/relocks overlayfs) |
| `tools/preview.sh` | render a frame locally with real lyrics/bio lookups |
| `tools/screenshot.sh` | grab what the speaker's screen shows right now |

## Usage

```bash
tools/build-image.sh /dev/sdX        # build + flash (asks before erasing)
```

Boot the Pi with Ethernet and HDMI plugged in. First boot takes about 10–15 min
and reboots once. Then pick **A206** in Spotify. Log: `/var/log/spotify-setup.log`.

```bash
tools/deploy.sh pi@a206.local        # update the display on a running speaker
tools/preview.sh out.png "Cure For Me" AURORA "The Gods We Can Touch" 198853 61000
```

To change anything by hand, unlock the root first:
`sudo raspi-config nonint disable_overlayfs && sudo reboot`.

## Display stack

```
Spotify app ─Connect─▶ librespot ─onevent─▶ nowplaying-event ─▶ /run/raspotify/np/*.json
                          │                                               │ polled
                          ▼                                               ▼
                    ALSA → HDMI audio          TV ◀─ HDMI ◀─ /dev/fb0 ◀─ nowplaying.py
```

`nowplaying.py` draws off-screen with SDL's dummy driver and copies each frame
to the fbdev framebuffer as RGB565. Going through KMS/EGL produced an ARGB
plane that the vc4 scanout showed as black.

## Limits

- **No lossless:** Spotify only serves FLAC to devices using its licensed SDK.
  librespot gets the 320 kbps Ogg stream
  ([librespot#1583](https://github.com/librespot-org/librespot/issues/1583)).
- **Lyrics:** coverage depends on LRCLIB. Unsynced lyrics scroll with the song,
  and when there are none the panel shows the artist bio instead.
