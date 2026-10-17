#!/bin/bash
# Build a Raspberry Pi OS Lite (arm64) image that sets itself up as a Spotify
# Connect speaker on first boot, and/or flash it to an SD card.
#
#   tools/build-image.sh                    interactive wizard
#   tools/build-image.sh [options]
#
# Options:
#   -n NAME     speaker name shown in Spotify          (default: A206)
#   -H HOST     hostname, reachable as HOST.local       (default: from NAME)
#   -t TZ       timezone                                (default: Europe/Paris)
#   -k FILE     SSH public key for user pi              (default: ~/.ssh/id_ed25519.pub)
#   -w SSID     also join this Wi-Fi network (Ethernet always works)
#   -p PASS     Wi-Fi password
#   -c CC       Wi-Fi country code                      (default: FR)
#   -o FILE     output image                            (default: build/HOST.img)
#   -z          also write FILE.xz (for Raspberry Pi Imager / balenaEtcher)
#   -f DEV      flash to DEV (e.g. /dev/sdf) after building
#   -I IMG      flash an existing image instead of building (with -f)
#   -y          don't ask before erasing DEV
#
# A Pi boots a raw disk image (.img), not an ISO: the .img / .img.xz is what
# Raspberry Pi Imager ("Use custom") or Etcher flash.
# Needs: curl, xz, losetup, sudo.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="A206" HOST="" TZ_="Europe/Paris" KEY="$HOME/.ssh/id_ed25519.pub"
WIFI_SSID="" WIFI_PASS="" WIFI_COUNTRY="FR" OUT="" XZ=0 DEV="" IMG_IN="" YES=0

die() { echo "build-image: $*" >&2; exit 1; }
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
slug() { echo "$1" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null | tr 'A-Z' 'a-z' |
  sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-63; }

removable_disks() { lsblk -dpno NAME,RM,SIZE,TRAN,MODEL | awk '$2 == 1 && $3 != "0B"'; }

# ------------------------------------------------------------------ wizard ---
ask() { # var prompt default
  local v
  read -rp "$2 [${3}]: " v
  printf -v "$1" '%s' "${v:-$3}"
}

wizard() {
  echo "== Spotify Connect speaker image =="
  echo "1) Build an image file"
  echo "2) Build and flash an SD card"
  echo "3) Flash an existing image"
  local mode
  ask mode "Choice" 2
  if [ "$mode" = 3 ]; then
    ask IMG_IN "Image to flash" "$(ls -t build/*.img 2>/dev/null | head -1)"
  else
    ask NAME "Speaker name in Spotify" "$NAME"
    ask HOST "Hostname" "$(slug "$NAME")"
    ask TZ_ "Timezone" "$TZ_"
    ask KEY "SSH public key" "$KEY"
    ask WIFI_SSID "Wi-Fi SSID (empty = Ethernet only)" ""
    if [ -n "$WIFI_SSID" ]; then
      read -rsp "Wi-Fi password: " WIFI_PASS; echo
      ask WIFI_COUNTRY "Wi-Fi country code" "$WIFI_COUNTRY"
    fi
    local z
    ask z "Also write a compressed .img.xz? (y/n)" n
    [ "$z" = y ] && XZ=1
  fi
  if [ "$mode" != 1 ]; then
    echo; echo "Removable disks:"
    if ! removable_disks | grep .; then
      echo "  none found."
      grep -qi microsoft /proc/version 2>/dev/null && cat <<'EOF'
  In WSL, attach the card reader first (admin PowerShell):
    usbipd list
    usbipd bind --busid <BUSID>
    usbipd attach --wsl --busid <BUSID>
EOF
      die "no SD card to flash"
    fi
    ask DEV "Device to flash" "$(removable_disks | awk 'NR==1{print $1}')"
  fi
}

if [ $# -eq 0 ] && [ -t 0 ]; then
  wizard
else
  while getopts "n:H:t:k:w:p:c:o:zf:I:yh" o; do
    case "$o" in
      n) NAME=$OPTARG ;; H) HOST=$OPTARG ;; t) TZ_=$OPTARG ;; k) KEY=$OPTARG ;;
      w) WIFI_SSID=$OPTARG ;; p) WIFI_PASS=$OPTARG ;; c) WIFI_COUNTRY=$OPTARG ;;
      o) OUT=$OPTARG ;; z) XZ=1 ;; f) DEV=$OPTARG ;; I) IMG_IN=$OPTARG ;; y) YES=1 ;;
      h) usage ;; *) usage 1 ;;
    esac
  done
fi

# ------------------------------------------------------------------- flash ---
flash() { # image device
  local img=$1 dev=$2
  [ -b "$dev" ] || die "$dev is not a block device"
  [ "$(lsblk -dno RM "$dev")" = 1 ] || die "$dev is not a removable disk, refusing"
  echo; lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS "$dev"
  if [ "$YES" != 1 ]; then
    local ok
    read -rp "Erase $dev and write $img? [y/N] " ok
    [ "$ok" = y ] || die "aborted"
  fi
  sudo umount "$dev"?* 2>/dev/null || true
  sudo wipefs -a "$dev" >/dev/null
  sudo dd if="$img" of="$dev" bs=4M conv=fsync status=progress
  sync
  echo "Verifying..."
  sudo cmp -n "$(stat -c %s "$img")" "$img" "$dev" && echo "Flashed and verified $dev"
}

if [ -n "$IMG_IN" ]; then
  [ -f "$IMG_IN" ] || die "$IMG_IN not found"
  [ -n "$DEV" ] || die "-I needs -f DEV"
  flash "$IMG_IN" "$DEV"
  exit 0
fi

# ------------------------------------------------------------------- build ---
HOST=${HOST:-$(slug "$NAME")}
[[ "$HOST" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "bad hostname '$HOST'"
[ -f "$KEY" ] || die "SSH key $KEY not found (ssh-keygen -t ed25519)"
[ -f "/usr/share/zoneinfo/$TZ_" ] || echo "warning: timezone $TZ_ unknown here, using it anyway"
[ -z "$WIFI_SSID" ] || [ ${#WIFI_PASS} -ge 8 ] || die "Wi-Fi password must be at least 8 characters"
OUT=${OUT:-build/$HOST.img}
mkdir -p dl "$(dirname "$OUT")"

echo "== Building $OUT: '$NAME' ($HOST.local), $TZ_, ${WIFI_SSID:+Wi-Fi '$WIFI_SSID' + }Ethernet"

IMG_URL=$(curl -sI https://downloads.raspberrypi.com/raspios_lite_arm64_latest |
  awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')
[ -n "$IMG_URL" ] || die "could not resolve the latest Pi OS Lite image"
IMG_XZ="dl/$(basename "$IMG_URL")"
[ -f "$IMG_XZ" ] || curl -fL -o "$IMG_XZ" "$IMG_URL"
curl -fsSL "$IMG_URL.sha256" | awk -v f="$IMG_XZ" '{print $1"  "f}' | sha256sum -c -

DEB_URL=$(curl -fsSL https://api.github.com/repos/dtcooper/raspotify/releases/latest |
  grep -o 'https://[^"]*/raspotify_[^"]*_arm64\.deb' | head -1)
[ -n "$DEB_URL" ] || die "could not find the latest raspotify arm64 .deb"
DEB="dl/$(basename "$DEB_URL")"
[ -f "$DEB" ] || curl -fL -o "$DEB" "$DEB_URL"

echo "Decompressing $IMG_XZ"
xz -dc -T0 "$IMG_XZ" > "$OUT"

LOOP=$(sudo losetup -fP --show "$OUT")
MNT=$(mktemp -d)
cleanup() { sudo umount "$MNT" 2>/dev/null || true; sudo losetup -d "$LOOP" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
sudo mount "${LOOP}p1" "$MNT"

yq() { # YAML double-quoted string
  local s=${1//\\/\\\\}
  printf '"%s"' "${s//\"/\\\"}"
}
sh_q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# cloud-init seed
sed -e "s|__HOSTNAME__|$HOST|" -e "s|__TIMEZONE__|$TZ_|" -e "s|__SSH_PUBKEY__|$(cat "$KEY")|" \
  -e '/__PLACEHOLDERS__/d' boot/user-data | sudo tee "$MNT/user-data" >/dev/null
sudo cp boot/meta-data "$MNT/"
{
  echo "network:"
  echo "  version: 2"
  echo "  ethernets:"
  echo "    eth0:"
  echo "      dhcp4: true"
  echo "      dhcp6: true"
  echo "      optional: $([ -n "$WIFI_SSID" ] && echo true || echo false)"
  if [ -n "$WIFI_SSID" ]; then
    echo "  wifis:"
    echo "    wlan0:"
    echo "      dhcp4: true"
    echo "      optional: true"
    echo "      regulatory-domain: $WIFI_COUNTRY"
    echo "      access-points:"
    echo "        $(yq "$WIFI_SSID"):"
    echo "          password: $(yq "$WIFI_PASS")"
  fi
} | sudo tee "$MNT/network-config" >/dev/null
{
  echo "# Written by tools/build-image.sh, read by spotify-setup.sh"
  echo "SPEAKER_NAME=$(sh_q "$NAME")"
  echo "WIFI_SSID=$(sh_q "$WIFI_SSID")"
  echo "WIFI_COUNTRY=$(sh_q "$WIFI_COUNTRY")"
} | sudo tee "$MNT/a206.conf" >/dev/null

# first-boot script, raspotify, display and the a206-config TUI
sudo cp boot/spotify-setup.sh "$DEB" "$MNT"/
sudo mkdir -p "$MNT/display" "$MNT/system"
sudo cp display/* "$MNT/display/"
sudo cp system/* "$MNT/system/"

# HDMI audio only; Bluetooth off; Wi-Fi off unless configured
sudo sed -i 's/^dtparam=audio=on/dtparam=audio=off/' "$MNT/config.txt"
if ! grep -q "^# Spotify speaker" "$MNT/config.txt"; then
  {
    echo "# Spotify speaker: HDMI audio only, Bluetooth off$([ -n "$WIFI_SSID" ] || echo ", Wi-Fi off (Ethernet)")"
    [ -n "$WIFI_SSID" ] || echo "dtoverlay=disable-wifi"
    echo "dtoverlay=disable-bt"
  } | sudo tee -a "$MNT/config.txt" >/dev/null
fi
# Keep HDMI up with the TV off at boot, never blank the console/now-playing
# screen, hide the cursor, run the CPU at full clock (no scaling glitches)
grep -q force_hotplug "$MNT/cmdline.txt" || sudo sed -i '1 s/$/ vc4.force_hotplug=1 consoleblank=0 vt.global_cursor_default=0 cpufreq.default_governor=performance/' "$MNT/cmdline.txt"

sync
cleanup
trap - EXIT
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"

if [ "$XZ" = 1 ]; then
  echo "Compressing $OUT.xz"
  xz -kf -T0 "$OUT"
  echo "Wrote $OUT.xz ($(du -h "$OUT.xz" | cut -f1))"
fi

[ -z "$DEV" ] || flash "$OUT" "$DEV"
