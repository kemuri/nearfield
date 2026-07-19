#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER_SOURCE="$("$ROOT_DIR/script/build_router_driver.sh" | tail -1)"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
DRIVER_DEST="$HAL_DIR/NearfieldAudioDevice.driver"
LEGACY_ROUTER_DEST="$HAL_DIR/StudioPairRouterAudioDevice.driver"
LEGACY_PROXY_DEST="$HAL_DIR/ProxyAudioDevice.driver"
TEMP_DRIVER_DEST="$DRIVER_DEST.nearfield-installing"
DRIVER_SERVICE_HELPER="com.apple.audio.Core-Audio-Driver-Service.helper"

if [[ ! -d "$DRIVER_SOURCE" ]]; then
  echo "Router driver build did not produce $DRIVER_SOURCE" >&2
  exit 1
fi

sudo mkdir -p "$HAL_DIR"
sudo pkill -f "$DRIVER_SERVICE_HELPER" || true
sudo rm -rf "$DRIVER_DEST.studiopair-installing"
sudo rm -rf "$DRIVER_DEST.nearfield-installing"
sudo rm -rf "$LEGACY_ROUTER_DEST.studiopair-installing"
sudo rm -rf "$LEGACY_ROUTER_DEST.nearfield-installing"
sudo rm -rf "$LEGACY_PROXY_DEST.studiopair-installing"
sudo rm -rf "$LEGACY_PROXY_DEST.nearfield-installing"
sudo ditto "$DRIVER_SOURCE" "$TEMP_DRIVER_DEST"
sudo xattr -cr "$TEMP_DRIVER_DEST" || true
sudo chown -R root:wheel "$TEMP_DRIVER_DEST"
sudo codesign --force --deep --sign - "$TEMP_DRIVER_DEST" >/dev/null
sudo xattr -cr "$TEMP_DRIVER_DEST" || true
sudo rm -rf "$DRIVER_DEST"
sudo rm -rf "$LEGACY_ROUTER_DEST"
sudo rm -rf "$LEGACY_PROXY_DEST"
sudo mv "$TEMP_DRIVER_DEST" "$DRIVER_DEST"
sudo xattr -cr "$DRIVER_DEST" || true
sudo killall coreaudiod || true

echo "Installed $DRIVER_DEST"
echo "CoreAudio restarted. Relaunch Nearfield, then enable App Audio Routing if needed."
