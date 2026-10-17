#!/bin/bash
# Push display/ and a206-config to a running speaker, keeping the read-only root afterwards.
#   tools/deploy.sh [user@host]      (default pi@a206.local)
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${1:-pi@a206.local}"

ssh_() { ssh -o ConnectTimeout=10 "$HOST" "$@"; }
wait_up() {
  sleep 15
  until ssh_ true 2>/dev/null; do sleep 5; done
}

if [ "$(ssh_ findmnt / -no FSTYPE)" = overlay ]; then
  echo "Root is read-only (overlayfs): unlocking, rebooting..."
  ssh_ 'sudo raspi-config nonint disable_overlayfs && sudo systemctl reboot' || true
  wait_up
fi

scp -q display/* system/* "$HOST":/tmp/
ssh_ 'set -e
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  python3-pygame python3-fonttools fonts-dejavu-core fonts-noto-cjk whiptail libasound2-plugins >/dev/null
sudo install -m755 /tmp/a206-config /usr/local/sbin/
if [ ! -f /etc/a206/settings ]; then
  sudo mkdir -p /etc/a206
  dev=$(sudo sed -n "s/^LIBRESPOT_DEVICE=//p" /etc/raspotify/conf | tr -d "\"")
  printf "OUT_DEVICE=\"%s\"\nOUT_RATE=\"44100\"\n" "$dev" | sudo tee /etc/a206/settings >/dev/null
fi
sudo touch /etc/cloud/cloud-init.disabled
sudo install -m755 /tmp/nowplaying-event /tmp/nowplaying.py /usr/local/bin/
sudo install -m644 /tmp/nowplaying.service /etc/systemd/system/
sudo install -Dm644 /tmp/raspotify-display.conf /etc/systemd/system/raspotify.service.d/display.conf
grep -q cpufreq.default_governor /boot/firmware/cmdline.txt ||
  sudo sed -i "1 s/$/ cpufreq.default_governor=performance/" /boot/firmware/cmdline.txt
sudo systemctl daemon-reload
echo "Re-locking root, rebooting..."
sudo raspi-config nonint enable_overlayfs
sudo systemctl reboot' || true
wait_up
ssh_ 'echo "root: $(findmnt / -no FSTYPE)"; systemctl is-active raspotify nowplaying'
