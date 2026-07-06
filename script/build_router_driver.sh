#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER_PROJECT="$ROOT_DIR/Vendor/app-router-audio-device/proxyAudioDevice.xcodeproj"
BUILD_DIR="${NEARFIELD_ROUTER_DRIVER_BUILD_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/nearfield-router-driver.XXXXXX")}"
PRODUCT_NAME="NearfieldAudioDevice"
XCODE_HOME="$BUILD_DIR/Home"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"

mkdir -p "$XCODE_HOME" "$MODULE_CACHE_DIR"

HOME="$XCODE_HOME" xcodebuild \
  -project "$DRIVER_PROJECT" \
  -scheme ProxyAudioDevice \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  SYMROOT="$BUILD_DIR" \
  OBJROOT="$BUILD_DIR/Intermediates" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
  PRODUCT_NAME="$PRODUCT_NAME" \
  PRODUCT_BUNDLE_IDENTIFIER=com.kemuri.Nearfield.AudioDevice \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  CODE_SIGN_STYLE=Manual \
  build

echo "$BUILD_DIR/Release/$PRODUCT_NAME.driver"
