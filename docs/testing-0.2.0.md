# Testing 0.2.0 before release

0.2.0 ships with driver 1.1.0 and goes to everyone at once, after a few days of
testing on real hardware. Only claim improvements in the release notes that the
measurements below confirm.

## 1. Baseline with 0.1.39

With 0.1.39 and driver 1.0.8 installed, Settings closed, and audio idle:

```sh
./script/measure_app_footprint.sh --seconds 300
```

Then install the diagnostic driver, use the Mac normally for a day, and summarize
underruns and the timing, buffer, and start/stop events around them:

```sh
./script/install_router_driver.sh --diagnostics
./script/driver_diagnostics_report.py --last 1d
```

## 2. Targets

Build and run 0.2.0 (`./script/build_and_run.sh`), choose **Update Driver**, and
measure each target:

| What | Before | Target | How |
| --- | --- | --- | --- |
| App memory, no window open | 45 MB | ~20 MB | `./script/measure_app_footprint.sh` after closing Settings |
| App CPU when idle | 0.2–0.8% | ~0% | same |
| Driver Core Audio queries when idle | ~24/s | 0 | `halRequests` from `swift script/nearfield_driver_status.swift`, read twice 60 s apart |
| Underruns in a 2-hour soak | 9 in 5 min | 0 | `swift script/nearfield_driver_status.swift --soak 120` |
| Reported latency | 0 | measured value | `swift script/measure_latency.swift` (compare measured with reported) |

Run the soak at each sample rate while music plays, or with `--tone`:

```sh
swift script/nearfield_driver_status.swift --soak 120 --sample-rate 48000
swift script/nearfield_driver_status.swift --soak 120 --sample-rate 88200
swift script/nearfield_driver_status.swift --soak 120 --sample-rate 96000
```

### Choosing the underrun fix

The driver has both candidate fixes: steering its clock by how full the buffer is,
and a safety gap that widens after an underrun. Both are on by default. Compare
them with soaks, then keep the one the data supports:

```sh
defaults write com.kemuri.Nearfield.debug driverUnderrunStrategy steer   # or gap, both
defaults write com.kemuri.Nearfield.debug driverDiagnostics -bool true
# Quit and reopen Nearfield Dev so it sends the settings.
```

Use `com.kemuri.Nearfield` instead of `com.kemuri.Nearfield.debug` for a release build.

## 3. Open questions

**Access control.** Install a Developer ID signed build
(`./.local-release/package_dmg.sh local`), let it install its driver, then run:

```sh
swift script/nearfield_driver_status.swift --probe-write
```

`rejected … writerVerification=enforced` means only Nearfield can change the
driver's settings. If it is accepted, reports `unavailable`, or Nearfield itself is
rejected, add a known limitation to the README: any process can change the
driver's settings. Development drivers are unsigned and accept every process.

**Volume keys.** Set the balance off-center, then turn off Nearfield's own
volume key handling:

```sh
defaults write com.kemuri.Nearfield.debug systemHandlesVolumeKeys -bool true
```

Quit and reopen Nearfield Dev. With Nearfield as the output, check that the
volume keys, mute key, and Control Center slider all change Nearfield's volume and
keep the balance. If they do, remove `MediaKeyVolumeController` before release. If
not, delete the preference and keep the handler.

## 4. Test list

- Upgrade from 0.1.39 with driver 1.0.8, once choosing **Update Driver** and once
  choosing **Later** (Nearfield keeps working with the old driver).
- Daily use for a few days with `driverDiagnostics` on.
- 2-hour soaks at 48, 88.2, and 96 kHz (above).
- Drag a playing window between displays: the sound moves within 2 seconds.
- Unplug and replug a display; sleep and wake; reboot with the app quit (Nearfield
  is hidden while fewer than two displays are connected); uninstall.

Three displays and macOS 14, 15, and 26 cannot be tested on this setup. Those code
paths are unchanged and covered by the automated tests.

## 5. Rollback

Ship 0.2.1 with driver 1.1.1. Never reuse a driver version for changed driver code.
