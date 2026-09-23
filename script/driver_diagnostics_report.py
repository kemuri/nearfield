#!/usr/bin/env python3
"""Summarize Nearfield driver diagnostics from the unified log.

The diagnostic driver (./script/install_router_driver.sh --diagnostics) and
driver 1.1.0 with diagnostics enabled write "NearfieldDiag:" records. This
script reads them from `log show` (or a saved log file) and reports underruns
with the timing, buffer and lifecycle context around each one.

    ./script/driver_diagnostics_report.py --last 1d
    ./script/driver_diagnostics_report.py --file saved.log
"""

import argparse
import ctypes
import re
import statistics
import subprocess
import sys
from collections import Counter, defaultdict

RECORD = re.compile(r"NearfieldDiag: (?P<fields>.*)$")
FIELD = re.compile(r"(\w+)=(\S+)")
CONTEXT_KINDS = {
    "start-io", "stop-io", "output-start", "output-first-callback", "output-stop",
    "sample-rate", "buffer-sizes", "resync", "overrun", "trim", "safety-gap",
}


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def host_ticks_per_second():
    info = Timebase()
    ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(info))
    return 1e9 * info.denom / info.numer


def read_lines(args):
    if args.file:
        with open(args.file, encoding="utf-8", errors="replace") as handle:
            return handle.readlines()
    command = [
        "/usr/bin/log", "show", "--style", "compact", "--last", args.last,
        "--predicate", 'eventMessage CONTAINS "NearfieldDiag:"',
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        sys.exit(result.stderr.strip() or "log show failed")
    return result.stdout.splitlines()


def parse(lines):
    records = []
    for line in lines:
        match = RECORD.search(line)
        if not match:
            continue
        fields = dict(FIELD.findall(match.group("fields")))
        kind = fields.pop("kind", "unknown")
        values = {}
        for key, value in fields.items():
            try:
                values[key] = float(value)
            except ValueError:
                values[key] = value
        records.append((kind, values))
    return records


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))]


def describe(label, values, unit):
    if not values:
        print(f"  {label}: no data")
        return
    print(
        f"  {label}: median {statistics.median(values):.1f}{unit}, "
        f"p99 {percentile(values, 0.99):.1f}{unit}, max {max(values):.1f}{unit} "
        f"({len(values)} samples)"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--last", default="1d", help="log show time window (default: 1d)")
    parser.add_argument("--file", help="read a saved `log show --style compact` output instead")
    parser.add_argument("--context", type=float, default=2.0, help="seconds of context around each underrun")
    args = parser.parse_args()

    records = parse(read_lines(args))
    if not records:
        print("No NearfieldDiag records found. Is the diagnostic driver installed and has audio played?")
        return 1

    ticks_per_second = host_ticks_per_second()
    counts = Counter(kind for kind, _ in records)
    by_kind = defaultdict(list)
    for kind, values in records:
        by_kind[kind].append(values)

    hosts = [values["host"] for _, values in records if isinstance(values.get("host"), float)]
    span_hours = (max(hosts) - min(hosts)) / ticks_per_second / 3600 if len(hosts) > 1 else 0
    print(f"Records: {len(records)} over {span_hours:.2f} h")
    print("Counts: " + ", ".join(f"{kind}={count}" for kind, count in sorted(counts.items())))

    print("\nAudio threads (per ~1 s window)")
    writer = by_kind.get("writer", [])
    reader = by_kind.get("reader", [])
    describe("writer wake-up lateness", [w["i1"] for w in writer], " us")
    describe("writer lock wait", [w["i2"] for w in writer], " us")
    describe("reader wake-up lateness", [r["i1"] for r in reader], " us")
    describe("reader lock wait", [r["i2"] for r in reader], " us")
    describe("reader min buffered frames", [r["d0"] for r in reader], " fr")
    describe("reader max callback interval", [r["d2"] for r in reader], " ms")
    zero_waits = [values.get("maxWaitUs", 0.0) for values in by_kind.get("zero-timestamp-lock", [])]
    describe("zero-timestamp lock wait", zero_waits, " us")

    clock = by_kind.get("clock", [])
    describe("clock correction", [c["d0"] for c in clock], " ppm")

    cold = [c["d0"] for c in by_kind.get("output-first-callback", [])]
    print("\nCold starts (output start request to first callback)")
    describe("cold start", cold, " ms")

    underruns = by_kind.get("underrun", [])
    print(f"\nUnderruns: {len(underruns)}" + (f" ({len(underruns) / span_hours:.1f}/h)" if span_hours else ""))
    context_window = args.context * ticks_per_second
    timeline = [(values.get("host", 0.0), kind, values) for kind, values in records]
    for values in underruns:
        host = values.get("host", 0.0)
        print(
            f"- missing {values.get('i0', 0):.0f} fr, buffered before read {values.get('d0', 0):.0f} fr, "
            f"gap {values.get('d1', 0):.0f} fr, callback lateness {values.get('d2', 0):.0f} us"
        )
        for other_host, kind, other in timeline:
            if kind not in CONTEXT_KINDS or abs(other_host - host) > context_window:
                continue
            offset = (other_host - host) / ticks_per_second
            details = " ".join(f"{key}={value:g}" for key, value in other.items()
                               if key != "host" and isinstance(value, float) and value)
            print(f"    {offset:+.3f} s {kind} {details}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
