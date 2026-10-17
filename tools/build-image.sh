#!/bin/bash
# Build a Raspberry Pi OS Lite (arm64) image that sets itself up as the A206
# Spotify Connect speaker on first boot, and optionally flash it.
#
#   tools/build-image.sh               -> build/a206.img
#   tools/build-image.sh /dev/sdX      -> build, then write + verify on the SD card
#
# Needs: curl, xz, losetup, sudo. SSH key: $SSH_PUBKEY or ~/.ssh/id_ed25519.pub
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="${1:-}"
PUBKEY_FILE="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
mkdir -p dl build

# --- Download Pi OS Lite (latest) + raspotify (latest arm64 .deb) ---
IMG_URL=$(curl -sI https://downloads.raspberrypi.com/raspios_lite_arm64_latest |
  awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')
IMG_XZ="dl/$(basename "$IMG_URL")"
[ -f "$IMG_XZ" ] || curl -fL -o "$IMG_XZ" "$IMG_URL"
curl -fsSL "$IMG_URL.sha256" | awk -v f="$IMG_XZ" '{print $1"  "f}' | sha256sum -c -

DEB_URL=$(curl -fsSL https://api.github.com/repos/dtcooper/raspotify/releases/latest |
  grep -o 'https://[^"]*/raspotify_[^"]*_arm64\.deb' | head -1)
DEB="dl/$(basename "$DEB_URL")"
[ -f "$DEB" ] || curl -fL -o "$DEB" "$DEB_URL"

IMG=build/a206.img
echo "Decompressing $IMG_XZ -> $IMG"
xz -dc -T0 "$IMG_XZ" > "$IMG"

# --- Patch the boot partition ---
LOOP=$(sudo losetup -fP --show "$IMG")
MNT=$(mktemp -d)
cleanup() { sudo umount "$MNT" 2>/dev/null || true; sudo losetup -d "$LOOP" 2>/dev/null || true; rmdir "$MNT"; }
trap cleanup EXIT
sudo mount "${LOOP}p1" "$MNT"

sudo cp boot/meta-data boot/network-config boot/spotify-setup.sh "$DEB" "$MNT"/
sed "s|__SSH_PUBKEY__.*|$(cat "$PUBKEY_FILE")|" boot/user-data | sudo tee "$MNT/user-data" >/dev/null
sudo mkdir -p "$MNT/display"
sudo cp display/* "$MNT/display/"

# HDMI audio only; Wi-Fi and Bluetooth off (Ethernet speaker)
sudo sed -i 's/^dtparam=audio=on/dtparam=audio=off/' "$MNT/config.txt"
grep -q disable-wifi "$MNT/config.txt" || printf '%s\n' \
  '# Spotify speaker: HDMI audio only, radios off (Ethernet)' \
  'dtoverlay=disable-wifi' 'dtoverlay=disable-bt' | sudo tee -a "$MNT/config.txt" >/dev/null
# Keep HDMI (and its audio) up even if the TV is off at boot
grep -q force_hotplug "$MNT/cmdline.txt" || sudo sed -i '1 s/$/ vc4.force_hotplug=1/' "$MNT/cmdline.txt"

sync
cleanup
trap - EXIT
echo "Built $IMG"

# --- Optional: flash ---
[ -n "$DEV" ] || exit 0
[ "$(lsblk -dno RM "$DEV")" = 1 ] || { echo "$DEV is not a removable disk, refusing" >&2; exit 1; }
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS "$DEV"
read -rp "Erase $DEV and write $IMG? [y/N] " ok
[ "$ok" = y ] || exit 1
sudo umount "$DEV"?* 2>/dev/null || true
sudo wipefs -a "$DEV" >/dev/null
sudo dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
sync
sudo cmp -n "$(stat -c %s "$IMG")" "$IMG" "$DEV" && echo "Flashed and verified $DEV"
