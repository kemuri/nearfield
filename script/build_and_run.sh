#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PRODUCT_NAME="Nearfield"
APP_NAME="Nearfield"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
BUNDLE_ID="com.kemuri.Nearfield"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true

NEARFIELD_BUILD_CONFIGURATION=debug \
CODE_SIGN_IDENTITY=- \
"$ROOT_DIR/script/build_app_bundle.sh"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE" --args --skip-move-prompt
}

case "$MODE" in
  --stage-only|stage)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--stage-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
