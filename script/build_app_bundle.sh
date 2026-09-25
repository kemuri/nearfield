#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="Nearfield"
APP_NAME="${APP_NAME:-Nearfield}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-$APP_NAME}"
BUNDLE_ID="${BUNDLE_ID:-com.kemuri.Nearfield}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
BUILD_CONFIGURATION="${NEARFIELD_BUILD_CONFIGURATION:-debug}"
LAUNCH_DIAGNOSTICS="${NEARFIELD_LAUNCH_DIAGNOSTICS:-0}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/packaged_runtime_paths.sh"
DIST_DIR="${NEARFIELD_DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="${NEARFIELD_APP_BUNDLE:-$DIST_DIR/$APP_NAME.app}"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_DRIVERS="$APP_RESOURCES/Drivers"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$ROOT_DIR/Assets/IconOptions/nearfield/Nearfield.icns"
ROUTER_DRIVER_BUNDLE_NAME="NearfieldAudioDevice.driver"
RESOURCE_BUNDLE_NAME="${PRODUCT_NAME}_${PRODUCT_NAME}.bundle"
RESOURCE_SOURCE_ROOT="$ROOT_DIR/Sources/Nearfield/Resources"
SOURCE_MENU_BAR_ICON="$RESOURCE_SOURCE_ROOT/Icons/menubar.svg"
SOURCE_ONBOARDING_IMAGE="$RESOURCE_SOURCE_ROOT/Onboarding/intro-dither.png"
RESOURCE_BUNDLE_DESTINATION="$APP_RESOURCES/$RESOURCE_BUNDLE_NAME"
PACKAGED_MENU_BAR_ICON="$RESOURCE_BUNDLE_DESTINATION/menubar.svg"
RESOURCE_VALIDATION_ARGUMENT="--nearfield-validate-packaged-resources"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
CODE_SIGN_OPTIONS="${CODE_SIGN_OPTIONS:-}"
CODE_SIGN_TIMESTAMP="${CODE_SIGN_TIMESTAMP:-0}"
SWIFT_MODULE_CACHE_DIR="${NEARFIELD_SWIFT_MODULE_CACHE_DIR:-/private/tmp/nearfield-swift-cache}"
SWIFT_BUILD_DIR="${NEARFIELD_SWIFT_BUILD_DIR:-$ROOT_DIR/.build/nearfield-bundle}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"

mkdir -p "$SWIFT_MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR"

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

SWIFT_BUILD_ARGUMENTS=(
  build
  --disable-sandbox
  --scratch-path "$SWIFT_BUILD_DIR"
  -c "$BUILD_CONFIGURATION"
  # Swift Build, SwiftPM's default build system since Swift 6.4, records the
  # deployment target as the SDK version. macOS then runs Nearfield in
  # compatibility mode: old-style controls, and a Settings window that never
  # becomes key, so its display tiles cannot be dragged.
  -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_SYSTEM_VERSION" -Xlinker "$SDK_VERSION"
)
if [[ "$LAUNCH_DIAGNOSTICS" == "1" ]]; then
  SWIFT_BUILD_ARGUMENTS+=(-Xswiftc -DNEARFIELD_LAUNCH_DIAGNOSTICS)
fi

swift "${SWIFT_BUILD_ARGUMENTS[@]}"
BUILD_BIN_DIR="$(swift "${SWIFT_BUILD_ARGUMENTS[@]}" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$PRODUCT_NAME"
# Nearfield supports Apple silicon only; its driver is built for arm64 only.
if [[ "$(lipo -archs "$BUILD_BINARY")" != "arm64" ]]; then
  echo "Nearfield must be built for arm64 only; got: $(lipo -archs "$BUILD_BINARY")" >&2
  exit 1
fi
BUILT_SDK_VERSION="$(vtool -show-build "$BUILD_BINARY" | awk '$1 == "sdk" { print $2; exit }')"
if [[ "$BUILT_SDK_VERSION" != "$SDK_VERSION" ]]; then
  echo "Nearfield must record the macOS $SDK_VERSION SDK it was built with; got: ${BUILT_SDK_VERSION:-none}" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES" "$APP_DRIVERS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

SPARKLE_FRAMEWORK_SOURCE="$BUILD_BIN_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
  echo "Sparkle.framework was not found in the Swift build: $SPARKLE_FRAMEWORK_SOURCE" >&2
  exit 1
fi
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$APP_FRAMEWORKS/Sparkle.framework"

if [[ ! -f "$SOURCE_MENU_BAR_ICON" ]]; then
  echo "required menu-bar icon was not found: $SOURCE_MENU_BAR_ICON" >&2
  exit 1
fi
if [[ ! -f "$SOURCE_ONBOARDING_IMAGE" ]]; then
  echo "required onboarding image was not found: $SOURCE_ONBOARDING_IMAGE" >&2
  exit 1
fi
mkdir -p "$RESOURCE_BUNDLE_DESTINATION"
ditto "$SOURCE_MENU_BAR_ICON" "$PACKAGED_MENU_BAR_ICON"
ditto "$SOURCE_ONBOARDING_IMAGE" "$RESOURCE_BUNDLE_DESTINATION/intro-dither.png"
find "$RESOURCE_BUNDLE_DESTINATION" -type f \( \
  -name "menubar-bridge-template.png" -o \
  -name "menubar-waveform-template.png" -o \
  -name "menubar-pair-template.png" -o \
  -name "menubar-template.png" \
\) -delete

if [[ ! -f "$APP_ICON" ]]; then
  echo "required application icon was not found: $APP_ICON" >&2
  exit 1
fi
cp "$APP_ICON" "$APP_RESOURCES/Nearfield.icns"

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
    xcrun -sdk macosx metal -O -fmodules-cache-path="$SWIFT_MODULE_CACHE_DIR" -c "$METAL_SRC" -o "$METAL_AIR"
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
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleIconFile</key>
  <string>Nearfield</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
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
</dict>
</plist>
PLIST

if [[ "$LAUNCH_DIAGNOSTICS" == "1" ]]; then
  /usr/libexec/PlistBuddy -c "Add :NearfieldLaunchDiagnosticsEnabled bool true" "$INFO_PLIST"
fi

if [[ -n "$SPARKLE_FEED_URL" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$INFO_PLIST"
fi
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$INFO_PLIST"
fi

validate_packaged_app_layout() {
  local required_paths=(
    "$APP_BINARY"
    "$INFO_PLIST"
    "$APP_RESOURCES/Nearfield.icns"
    "$RESOURCE_BUNDLE_DESTINATION"
    "$PACKAGED_MENU_BAR_ICON"
    "$APP_FRAMEWORKS/Sparkle.framework"
    "$APP_DRIVERS/$ROUTER_DRIVER_BUNDLE_NAME"
  )
  local required_path
  for required_path in "${required_paths[@]}"; do
    if [[ ! -e "$required_path" ]]; then
      echo "required packaged app item is missing: $required_path" >&2
      return 1
    fi
  done

  local resolved_menu_bar_icon
  if ! resolved_menu_bar_icon="$("$APP_BINARY" "$RESOURCE_VALIDATION_ARGUMENT")"; then
    echo "packaged executable could not resolve its menu-bar icon" >&2
    return 1
  fi
  if [[ "$resolved_menu_bar_icon" != "$PACKAGED_MENU_BAR_ICON" ]]; then
    echo "packaged executable resolved the menu-bar icon outside the app bundle: $resolved_menu_bar_icon" >&2
    return 1
  fi

  if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
    if strings "$APP_BINARY" | /usr/bin/grep -F "$ROOT_DIR/.build/" >/dev/null; then
      echo "packaged executable contains an absolute build-directory fallback" >&2
      return 1
    fi
    validate_runtime_rpaths "$APP_BINARY"
  fi
}

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

remove_build_toolchain_rpaths "$APP_BINARY"
sign_path "$APP_FRAMEWORKS/Sparkle.framework"
sign_path "$APP_DRIVERS/$ROUTER_DRIVER_BUNDLE_NAME"
sign_path "$APP_BUNDLE"
validate_packaged_app_layout

echo "$APP_BUNDLE"
