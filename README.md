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
- **Appliance:** Ethernet (plus optional Wi-Fi), SSH key login only, read-only
  root (overlayfs) so pulling the power is safe, and the services restart
  themselves if they crash.
- **`sudo a206-config`:** SSH TUI to change the output device, bit depth,
  sample rate, bitrate, volume mode, speaker name, hostname and the display.
  Changes apply live and persist through the read-only root.

## Layout

| Path | What |
|---|---|
| `boot/user-data`, `meta-data` | cloud-init seed template (hostname, timezone, user `pi` + SSH key) |
| `boot/spotify-setup.sh` | first-boot script: apt (retries past captive portals), raspotify, HDMI format, display, a206-config, lockdown, overlayfs |
| `system/a206-config` | SSH TUI / CLI for audio and system settings |
| `display/nowplaying-event` | librespot `--onevent` hook → JSON in `/run/raspotify/np/` |
| `display/nowplaying.py` | pygame renderer → `/dev/fb0` (or `--render out.png`) |
| `display/*.service`, `*.conf` | systemd unit + raspotify drop-in setting `LIBRESPOT_ONEVENT` |
| `tools/build-image.sh` | wizard / CLI: build a `.img` (+ `.img.xz`), flash an SD card, or both |
| `tools/deploy.sh` | push `display/` and `a206-config` to a running speaker (unlocks/relocks overlayfs) |
| `tools/preview.sh` | render a frame locally with real lyrics/bio lookups |
| `tools/screenshot.sh` | grab what the speaker's screen shows right now |

## Usage

```bash
tools/build-image.sh                                  # wizard
tools/build-image.sh -n "Living Room" -z              # build/living-room.img + .img.xz
tools/build-image.sh -n Kitchen -w MyWiFi -p secret -c FR -f /dev/sdf   # build + flash
tools/build-image.sh -I build/a206.img -f /dev/sdf   # flash an existing image
```

A Pi boots a raw disk image, not an ISO. The `.img.xz` works with Raspberry Pi
Imager ("Use custom") or balenaEtcher. In WSL, attach the card reader first with
`usbipd attach --wsl --busid <id>`. The flasher only accepts removable disks and
asks before erasing.

Boot the Pi with Ethernet (or the configured Wi-Fi) and HDMI plugged in. First boot takes about 10–15 min
and reboots once. Then pick **A206** in Spotify. Log: `/var/log/spotify-setup.log`.

```bash
tools/deploy.sh pi@a206.local        # update the display on a running speaker
tools/preview.sh out.png "Cure For Me" AURORA "The Gods We Can Touch" 198853 61000
```

## Settings on the speaker

```bash
ssh pi@a206.local
sudo a206-config                     # menu
sudo a206-config status
sudo a206-config set format S32      # S16 S24 S24_3 S32 F32
sudo a206-config set rate 96000      # 44100 = native/bit-perfect; others via speex resampler
sudo a206-config set device hw:CARD=DAC,DEV=0
sudo a206-config set volume fixed    # or soft
sudo a206-config set hostname salon ; sudo a206-config set name "Salon"
sudo a206-config set display off
```

librespot always decodes at 44.1 kHz, so other rates go through an ALSA `plug`
(`/etc/asound.conf`, speexrate_best). That helps a DAC or amp that wants 48k, but
it can't add detail. With the read-only root active, each change is also written
to the real root through `overlayroot-chroot`. For anything else, unlock the root
from the menu or with `sudo raspi-config nonint disable_overlayfs && sudo reboot`.

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
