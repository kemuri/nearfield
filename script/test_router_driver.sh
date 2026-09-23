#!/usr/bin/env bash
# Builds the driver regression tests three times and runs them:
#   plain          all tests, including the allocation guard for audio callbacks
#   address + UB   all tests except the allocation guard (the sanitizer owns malloc)
#   thread         the tests that run audio threads concurrently
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nearfield-driver-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
DRIVER_DIR="$ROOT_DIR/Vendor/app-router-audio-device"

build() {
  local output="$1"
  shift
  xcrun clang++ -std=gnu++17 -fblocks -g -O1 -Wno-deprecated-declarations "$@" \
    -I "$DRIVER_DIR/shared" \
    -I "$DRIVER_DIR/proxyAudioDevice" \
    -I "$DRIVER_DIR/proxyAudioDevice/PublicUtility" \
    "$ROOT_DIR/Tests/DriverTests/AudioLifecycleTests.cpp" \
    "$DRIVER_DIR/shared/AudioDevice.cpp" \
    "$DRIVER_DIR/proxyAudioDevice/PublicUtility/CAMutex.cpp" \
    "$DRIVER_DIR/proxyAudioDevice/PublicUtility/CADebugMacros.cpp" \
    "$DRIVER_DIR/proxyAudioDevice/PublicUtility/CADebugPrintf.cpp" \
    -framework CoreAudio -framework CoreFoundation -framework CoreServices -framework IOKit -framework Security \
    -o "$output"
}

build "$TEST_DIR/plain"
build "$TEST_DIR/address" -fsanitize=address,undefined -fno-sanitize-recover=undefined
build "$TEST_DIR/thread" -fsanitize=thread

echo "== plain"
"$TEST_DIR/plain" all
echo "== address and undefined behavior sanitizers"
"$TEST_DIR/address" sanitized
echo "== thread sanitizer"
TSAN_OPTIONS="halt_on_error=1" "$TEST_DIR/thread" concurrency
