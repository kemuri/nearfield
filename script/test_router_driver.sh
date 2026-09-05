#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nearfield-driver-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
DRIVER_DIR="$ROOT_DIR/Vendor/app-router-audio-device"

xcrun clang++ -std=gnu++14 -fblocks -Wno-deprecated-declarations \
  -I "$DRIVER_DIR/shared" \
  -I "$DRIVER_DIR/proxyAudioDevice" \
  -I "$DRIVER_DIR/proxyAudioDevice/PublicUtility" \
  "$ROOT_DIR/Tests/DriverTests/AudioLifecycleTests.cpp" \
  "$DRIVER_DIR/proxyAudioDevice/AudioRingBuffer.cpp" \
  "$DRIVER_DIR/shared/AudioDevice.cpp" \
  "$DRIVER_DIR/proxyAudioDevice/PublicUtility/CAMutex.cpp" \
  "$DRIVER_DIR/proxyAudioDevice/PublicUtility/CADebugMacros.cpp" \
  "$DRIVER_DIR/proxyAudioDevice/PublicUtility/CADebugPrintf.cpp" \
  "$DRIVER_DIR/proxyAudioDevice/utilities.cpp" \
  -framework CoreAudio -framework CoreFoundation -framework CoreServices -framework IOKit \
  -o "$TEST_DIR/AudioLifecycleTests"

"$TEST_DIR/AudioLifecycleTests"
