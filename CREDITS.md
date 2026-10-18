# Credits

pispot is a thin layer of scripts on top of other people's work. Thank you to
everyone behind the projects below.

The MIT license in [`LICENSE`](LICENSE) covers only the code in this repository.
The images built by `tools/build-image.sh` download and install the software
below, which stays under its own license.

## On the speaker

| Project | Used for | License |
|---|---|---|
| [librespot](https://github.com/librespot-org/librespot) | Spotify Connect client: playback, discovery, `--onevent` hook | MIT |
| [raspotify](https://github.com/dtcooper/raspotify) | librespot packaged for Debian with a hardened systemd service | MIT |
| [Raspberry Pi OS](https://www.raspberrypi.com/software/) / [Debian](https://www.debian.org/) | base system (Lite, arm64) | various free licenses |
| [raspi-config](https://github.com/RPi-Distro/raspi-config) | overlay filesystem and Wi-Fi country setup | MIT |
| [cloud-init](https://github.com/canonical/cloud-init) | unattended first boot from the boot partition | Apache-2.0 or GPL-3.0 |
| [netplan](https://github.com/canonical/netplan) | Ethernet / Wi-Fi configuration | GPL-3.0 |
| overlayroot ([cloud-initramfs-tools](https://launchpad.net/cloud-initramfs-tools)) | read-only root and `overlayroot-chroot` | GPL-3.0+ |
| [ALSA](https://www.alsa-project.org/): [alsa-lib](https://github.com/alsa-project/alsa-lib), [alsa-utils](https://github.com/alsa-project/alsa-utils), [alsa-plugins](https://github.com/alsa-project/alsa-plugins) | audio output, `aplay` probes, `plug` resampling | LGPL-2.1 / GPL-2.0 / LGPL-2.1 |
| [SpeexDSP](https://github.com/xiph/speexdsp) | `speexrate_best` resampler for non-44.1 kHz rates | BSD-3-Clause |
| [Avahi](https://github.com/avahi/avahi) | mDNS: `<host>.local` and Spotify Connect discovery | LGPL-2.1 |
| [systemd](https://systemd.io/) | services, restarts, sandboxing | LGPL-2.1+ |
| [newt / whiptail](https://pagure.io/newt) | `pispot-config` menus | LGPL-2.0 |
| [Python](https://www.python.org/) | display and event hook | PSF-2.0 |
| [pygame](https://www.pygame.org/) | off-screen rendering for the now-playing display | LGPL-2.1 |
| [SDL](https://github.com/libsdl-org/SDL) | pygame's backend | Zlib |
| [fontTools](https://github.com/fonttools/fonttools) | reading font cmaps for the CJK fallback | MIT |
| [DejaVu fonts](https://dejavu-fonts.github.io/) | main display font | Bitstream Vera license (+ public domain changes) |
| [Noto Sans CJK](https://github.com/notofonts/noto-cjk) | Japanese / Chinese / Korean text | SIL OFL 1.1 |
| [Mesa](https://www.mesa3d.org/) | EGL/GLES runtime installed with the display | MIT |

## Data shown on screen

| Source | Used for | Terms |
|---|---|---|
| [LRCLIB](https://lrclib.net) ([source](https://github.com/tranxuanthang/lrclib)) | synced and plain lyrics | free public API, no key. Lyrics belong to their rights holders |
| [Wikipedia](https://www.wikipedia.org/) REST API | artist summaries when no lyrics exist | text under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), credited on screen |
| Spotify | track metadata and cover art, via librespot | artwork belongs to its rights holders |

### README screenshots

| Content | Credit | License |
|---|---|---|
| "Monkeys Spinning Monkeys" (title, artist) | Kevin MacLeod, [incompetech.com](https://incompetech.com) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Kevin MacLeod summary | [Wikipedia](https://en.wikipedia.org/wiki/Kevin_MacLeod) contributors | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| 「さくらさくら」 (Sakura Sakura) lyrics | traditional, 1888 version | public domain |
| Cover art | drawn by `tools/make-screenshots.sh` | MIT, like the rest of this repo |

## Building and development

| Project | Used for | License |
|---|---|---|
| [usbipd-win](https://github.com/dorssel/usbipd-win) | passing the USB SD card reader into WSL | GPL-3.0 |
| [WSL](https://github.com/microsoft/WSL) | Linux build environment on Windows | MIT |
| [util-linux](https://github.com/util-linux/util-linux), [XZ Utils](https://tukaani.org/xz/), [curl](https://curl.se/) | loop devices / flashing, image (de)compression, downloads | GPL-2.0 (mostly), 0BSD (mostly), curl license |
| [ShellCheck](https://github.com/koalaman/shellcheck) | linting the shell scripts | GPL-3.0 |

## Trademarks

Spotify and Spotify Connect are trademarks of Spotify AB. Raspberry Pi is a
trademark of Raspberry Pi Ltd. pispot is an independent project and is not
affiliated with, endorsed by, or sponsored by either company.
