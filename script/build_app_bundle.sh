#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="Nearfield"
APP_NAME="${APP_NAME:-Nearfield}"
BUNDLE_ID="${BUNDLE_ID:-com.kemuri.Nearfield}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
BUILD_CONFIGURATION="${NEARFIELD_BUILD_CONFIGURATION:-debug}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${NEARFIELD_DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="${NEARFIELD_APP_BUNDLE:-$DIST_DIR/$APP_NAME.app}"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_DRIVERS="$APP_RESOURCES/Drivers"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$ROOT_DIR/Assets/IconOptions/nearfield/Nearfield.icns"
ROUTER_DRIVER_BUNDLE_NAME="NearfieldAudioDevice.driver"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
CODE_SIGN_OPTIONS="${CODE_SIGN_OPTIONS:-}"
CODE_SIGN_TIMESTAMP="${CODE_SIGN_TIMESTAMP:-0}"
SWIFT_MODULE_CACHE_DIR="${NEARFIELD_SWIFT_MODULE_CACHE_DIR:-/private/tmp/nearfield-swift-cache}"
SWIFT_BUILD_DIR="${NEARFIELD_SWIFT_BUILD_DIR:-$ROOT_DIR/.build/nearfield-bundle}"

mkdir -p "$SWIFT_MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR"

swift build --disable-sandbox --scratch-path "$SWIFT_BUILD_DIR" -c "$BUILD_CONFIGURATION"
BUILD_BIN_DIR="$(swift build --disable-sandbox --scratch-path "$SWIFT_BUILD_DIR" -c "$BUILD_CONFIGURATION" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$PRODUCT_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS" "$APP_DRIVERS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -d "$BUILD_BIN_DIR/${PRODUCT_NAME}_${PRODUCT_NAME}.bundle" ]]; then
  cp -R "$BUILD_BIN_DIR/${PRODUCT_NAME}_${PRODUCT_NAME}.bundle" "$APP_RESOURCES/"
  find "$APP_RESOURCES/${PRODUCT_NAME}_${PRODUCT_NAME}.bundle" -type f \( \
    -name "menubar-bridge-template.png" -o \
    -name "menubar-waveform-template.png" -o \
    -name "menubar-pair-template.png" -o \
    -name "menubar-template.png" \
  \) -delete
fi

if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$APP_RESOURCES/Nearfield.icns"
fi

ROUTER_DRIVER_SOURCE="$("$ROOT_DIR/script/build_router_driver.sh" | tail -n 1)"
if [[ ! -d "$ROUTER_DRIVER_SOURCE" ]]; then
  echo "router driver build did not produce a bundle: $ROUTER_DRIVER_SOURCE" >&2
  exit 1
fi
rm -rf "$APP_DRIVERS/$ROUTER_DRIVER_BUNDLE_NAME"
cp -R "$ROUTER_DRIVER_SOURCE" "$APP_DRIVERS/$ROUTER_DRIVER_BUNDLE_NAME"

METAL_SRC="$ROOT_DIR/Sources/Nearfield/WaveLabEffects.metal"
if [[ -f "$METAL_SRC" ]]; then
  if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    METAL_AIR="$(mktemp -t WaveLabEffects).air"
    xcrun -sdk macosx metal -O -c "$METAL_SRC" -o "$METAL_AIR"
    xcrun -sdk macosx metallib "$METAL_AIR" -o "$APP_RESOURCES/default.metallib"
    rm -f "$METAL_AIR"
    echo "compiled Metal effects -> $APP_RESOURCES/default.metallib"
  else
    echo "warning: Metal toolchain unavailable; Wave Lab effects will use the SwiftUI fallback." >&2
    echo "         install it with: xcodebuild -downloadComponent MetalToolchain" >&2
    rm -f "$APP_RESOURCES/default.metallib"
  fi
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>Nearfield</string>
  <key>CFBundleDisplayName</key>
  <string>Nearfield</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
PLIST

cat >>"$INFO_PLIST" <<PLIST
</dict>
</plist>
PLIST

sign_path() {
  local path="$1"
  local args=(--force --deep --sign "$CODE_SIGN_IDENTITY")
  if [[ -n "$CODE_SIGN_OPTIONS" ]]; then
    args+=(--options "$CODE_SIGN_OPTIONS")
  fi
  if [[ "$CODE_SIGN_TIMESTAMP" == "1" && "$CODE_SIGN_IDENTITY" != "-" ]]; then
    args+=(--timestamp)
  fi
  codesign "${args[@]}" "$path" >/dev/null
}

sign_path "$APP_DRIVERS/$ROUTER_DRIVER_BUNDLE_NAME"
sign_path "$APP_BUNDLE"

echo "$APP_BUNDLE"
