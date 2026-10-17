#!/bin/bash
# First-boot setup: turns this Pi into a dedicated Spotify Connect speaker.
# Run once by cloud-init (see user-data). Log: /var/log/spotify-setup.log
set -euo pipefail
exec > >(tee -a /var/log/spotify-setup.log) 2>&1
echo "=== spotify-setup start $(date -Is) ==="

SPEAKER_NAME="A206"
BOOT=/boot/firmware
export DEBIAN_FRONTEND=noninteractive

# Wait for Ethernet + DNS (up to ~5 min)
for i in $(seq 1 60); do
  getent hosts deb.debian.org >/dev/null && break
  echo "waiting for network ($i)..."; sleep 5
done

# Captive portals (e.g. the campus network login) make apt fetch HTML instead of
# package lists, so retry until apt works for real (up to ~2 h)
for i in $(seq 1 120); do
  rm -rf /var/lib/apt/lists/*
  apt-get update 2>&1 | tee /tmp/apt-update.log
  grep -qE '^(E|W): ' /tmp/apt-update.log || break
  echo "apt not usable yet (captive portal?), retry $i in 60s"; sleep 60
done
apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
# raspotify .deb was shipped on the boot partition; apt pulls the missing deps (libpulse0)
apt-get -y install "$BOOT"/raspotify_*.deb

# --- Pick the HDMI ALSA device and the highest sample format it accepts ---
DEVICE="hdmi:CARD=vc4hdmi,DEV=0"
aplay -L | grep -q '^hdmi:CARD=vc4hdmi,DEV=0' || DEVICE="$(aplay -L | grep -m1 '^hdmi:' || echo default)"
# vc4 HDMI takes S32 (sent as 24-bit). The probe only works while the TV is on,
# so keep S32 unless the probe actively proves only S16 works.
FORMAT=S32
if ! timeout 5 aplay -q -D "$DEVICE" -f S32_LE -r 44100 -c 2 -d 1 /dev/zero 2>/dev/null &&
   timeout 5 aplay -q -D "$DEVICE" -f S16_LE -r 44100 -c 2 -d 1 /dev/zero 2>/dev/null; then
  FORMAT=S16
fi
echo "Using ALSA device=$DEVICE format=$FORMAT"

cat > /etc/raspotify/conf <<EOF
# Managed by spotify-setup.sh
LIBRESPOT_NAME="$SPEAKER_NAME"
LIBRESPOT_DEVICE_TYPE=speaker
LIBRESPOT_BACKEND=alsa
LIBRESPOT_DEVICE="$DEVICE"
# Highest quality Spotify serves to Connect receivers (Ogg Vorbis 320 kbps)
LIBRESPOT_BITRATE=320
# Widest output sample format the HDMI sink accepted; no dither at 32-bit
LIBRESPOT_FORMAT=$FORMAT
# Volume: 64-bit float soft volume, starts at 100% (bit-transparent at full volume).
# For strictly fixed output (control volume on the TV/amp), replace these two
# lines with: LIBRESPOT_MIXER=softvol and LIBRESPOT_VOLUME_CTRL=fixed
LIBRESPOT_MIXER=softvol
LIBRESPOT_INITIAL_VOLUME=100
# No normalisation / limiter, no disk audio cache, discovery via mDNS on LAN
LIBRESPOT_DISABLE_AUDIO_CACHE=
LIBRESPOT_DISABLE_CREDENTIAL_CACHE=
LIBRESPOT_QUIET=
EOF

# Auto-restart librespot if it ever exits
mkdir -p /etc/systemd/system/raspotify.service.d
cat > /etc/systemd/system/raspotify.service.d/override.conf <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Restart=always
RestartSec=5
Nice=-10
EOF

# --- Appliance lockdown: strip what a speaker doesn't need ---
systemctl disable --now bluetooth.service hciuart.service wpa_supplicant.service \
  ModemManager.service triggerhappy.service cups.service 2>/dev/null || true
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer man-db.timer 2>/dev/null || true
systemctl enable avahi-daemon.service raspotify.service
# Performance CPU governor (avoids clock-scaling glitches)
apt-get -y install cpufrequtils || true
echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils

systemctl daemon-reload
systemctl restart raspotify.service || true

# Read-only root (overlayfs): SD card survives power pulls. Disable later with:
#   sudo raspi-config nonint disable_overlayfs && sudo reboot
raspi-config nonint enable_overlayfs || echo "WARN: overlayfs not enabled"

touch /etc/spotify-setup.done
echo "=== spotify-setup done $(date -Is), rebooting ==="
systemctl reboot
