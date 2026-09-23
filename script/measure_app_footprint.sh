#!/usr/bin/env bash
# Measure Nearfield's memory footprint and idle CPU for before/after comparisons.
#
#   ./script/measure_app_footprint.sh              # 60 s window, app + driver helper
#   ./script/measure_app_footprint.sh --seconds 300 --process "Nearfield Dev"
#
# Close Nearfield's Settings window and leave audio idle for the "no window
# open" and "idle" numbers. Results are printed as one line per process.
set -euo pipefail

SECONDS_TO_SAMPLE=60
APP_PROCESS="Nearfield"
DRIVER_PROCESS_PATTERN="NearfieldAudioDevice.driver"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds)
      SECONDS_TO_SAMPLE="$2"
      shift 2
      ;;
    --process)
      APP_PROCESS="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--seconds N] [--process NAME]" >&2
      exit 2
      ;;
  esac
done

pid_for() {
  pgrep -x "$1" | head -n 1
}

footprint_mb() {
  /usr/bin/footprint -p "$1" --noCategories -f bytes 2>/dev/null |
    awk '/Footprint:/ { for (i = 1; i <= NF; i++) if ($i == "Footprint:") { printf "%.1f", $(i + 1) / 1048576; exit } }'
}

# Prints "<cpu seconds> <idle wakeups>" from the kernel's cumulative counters.
cumulative_usage() {
  /usr/bin/top -l 1 -pid "$1" -stats pid,time,idlew 2>/dev/null |
    awk -v pid="$1" '$1 == pid {
      split($2, parts, ":")
      seconds = 0
      for (i = 1; i <= length(parts); i++) seconds = seconds * 60 + parts[i]
      print seconds, $3
    }'
}

APP_PID="$(pid_for "$APP_PROCESS" || true)"
# The HAL runs the driver in "Core Audio Driver (NearfieldAudioDevice.driver)".
DRIVER_PID="$(pgrep -f "$DRIVER_PROCESS_PATTERN" | head -n 1 || true)"
if [[ -z "$APP_PID" && -z "$DRIVER_PID" ]]; then
  echo "Neither \"$APP_PROCESS\" nor the Nearfield driver helper is running." >&2
  exit 1
fi

declare -a LABELS=() PIDS=() START_USAGE=()
if [[ -n "$APP_PID" ]]; then
  LABELS+=("$APP_PROCESS")
  PIDS+=("$APP_PID")
fi
if [[ -n "$DRIVER_PID" ]]; then
  LABELS+=("driver helper")
  PIDS+=("$DRIVER_PID")
fi

for pid in "${PIDS[@]}"; do
  START_USAGE+=("$(cumulative_usage "$pid")")
done
sleep "$SECONDS_TO_SAMPLE"

echo "Window: ${SECONDS_TO_SAMPLE} s"
for index in "${!PIDS[@]}"; do
  pid="${PIDS[$index]}"
  read -r start_cpu start_wakeups <<<"${START_USAGE[$index]}"
  read -r end_cpu end_wakeups <<<"$(cumulative_usage "$pid")"
  awk -v label="${LABELS[$index]}" -v pid="$pid" -v memory="$(footprint_mb "$pid")" \
      -v cpu0="$start_cpu" -v cpu1="$end_cpu" -v wake0="$start_wakeups" -v wake1="$end_wakeups" \
      -v window="$SECONDS_TO_SAMPLE" 'BEGIN {
        if (memory == "") memory = "n/a (needs sudo)"
        printf "%s (pid %s): footprint %s%s, CPU %.2f%%, idle wakeups %.1f/s\n",
          label, pid, memory, (memory ~ /^n\/a/ ? "" : " MB"), 100 * (cpu1 - cpu0) / window, (wake1 - wake0) / window
      }'
done
