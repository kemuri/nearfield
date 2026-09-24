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

Run the soak at each sample rate while music plays, or with `--tone` (100 Hz
at -80 dBFS on Nearfield: inaudible even at full volume, yet never trimmed as
silence). Ending a soak early (Ctrl-C, or closing the terminal) restores the
previous sample rate.

```sh
swift script/nearfield_driver_status.swift --soak 120 --tone --sample-rate 48000
swift script/nearfield_driver_status.swift --soak 120 --tone --sample-rate 88200
swift script/nearfield_driver_status.swift --soak 120 --tone --sample-rate 96000
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
driver's settings. Also confirm that the signed Nearfield still configures the
driver (routing and display changes take effect): this is the first release
that enforces the check. If the probe is accepted, reports `unavailable`, or
Nearfield itself is rejected, add a known limitation to the README: any process
can change the driver's settings. Development drivers are unsigned and accept
every process; a development app cannot configure a Developer ID driver.

**Volume keys.** Set the balance off-center, then turn off Nearfield's own
volume key handling:

```sh
defaults write com.kemuri.Nearfield.debug systemHandlesVolumeKeys -bool true
```

Quit and reopen Nearfield Dev. With Nearfield as the output, check that the
volume keys, mute key, and Control Center slider all change Nearfield's volume and
keep the balance. If they do, remove `MediaKeyVolumeController` before release. If
not, delete the preference and keep the handler.

Decision for 0.2.0: the keys work with Nearfield's handler (checked 2026-09-24
without the preference set), so the handler stays. Removing it needs the check
above with the preference set.

## 4. Test list

- Upgrade from 0.1.39 with driver 1.0.8, once choosing **Update Driver** and once
  choosing **Later** (Nearfield keeps working with the old driver).
- Daily use for a few days with `driverDiagnostics` on.
- 2-hour soaks at 48, 88.2, and 96 kHz (above).
- Drag a playing window between displays: the sound moves within 2 seconds.
- Play a YouTube video in Safari, pause it for more than 2 minutes (the displays
  stop), then resume: sound and picture stay in sync. Check `coldStartSkippedMilliseconds`
  in the driver status grows by about 400 ms per resume. After a shorter pause,
  nothing is skipped (the displays keep running for 2 minutes after the last sound).
- Set an app (for example Music, or a call app's speaker setting) to play on one
  Studio Display at about 20% volume, then connect the second display. That
  app must not get louder; Nearfield plays at a similar level. Once the app
  stops or moves, the displays go to full volume without a jump in Nearfield's
  loudness (Console: "Waiting to raise the displays' volume").
- Play music through Nearfield on macOS 14.2 or later with no other app on the
  displays: the displays are raised right away. If they keep waiting,
  Nearfield's own output is being counted as another app.
- Unplug and replug a display; sleep and wake; reboot with the app quit (Nearfield
  is hidden while fewer than two displays are connected); uninstall.

Three displays and macOS 14, 15, and 26 cannot be tested on this setup; the
automated tests cover their logic. One path is new: before macOS 14.2 Nearfield
cannot tell which app plays on a display, so it raises the displays only once
nothing is running on them (about 2 minutes after the last sound).

## 5. Results so far

Measured on the two-Studio-Display Mac on 2026-09-24, with driver 1.1.0
(Developer ID signed) and a local build of the app:

| Check | Result |
| --- | --- |
| 2-hour soak, 48 kHz, continuous 440 Hz tone at -50 dBFS (audible at high volume; now 100 Hz at -80 dBFS) | Passed: 0 underruns, 0 overruns |
| Latency after a cold start (the displays take ~440 ms to start) | Drained at 300 ppm in ~23 min, then flat at 55.3 ms for 91 min |
| Clock correction once settled | Within about ±25 ppm |
| Driver Core Audio requests while playing | 0 (only on device changes) |
| Access control (`--probe-write`) | Other processes rejected; the signed app configures the driver |
| App CPU, no window, Nearfield playing | 0.09% |
| App CPU, Settings open | 0.47% (about 12% for the first minutes after launch) |
| App memory, no window (after Settings was open and closed) | 43.0 MB (0.1.39: 45 MB; target ~20 MB not met). Live heap 13.6 MB, down from 26 MB while Settings was open; leaks under 3 KB |
| App CPU, no window, idle | 0.12% |
| End-to-end latency (`measure_latency.swift`, from Terminal) | Nearfield measured 58.8 ms vs 56.2 ms reported (+2.6 ms); one display directly measured 23.3 ms vs 22.0 ms reported (+1.3 ms, the method's own offset). Nearfield under-reports by about 1.3 ms. With the cold-start skip and 2-minute keep-alive: 54.1 ms measured vs 52.3 ms reported (+1.8 ms, about 0.5 ms under) |
| Driver update from a signed local build (19:23) | Installed with a verified Developer ID signature; settings and diagnostics kept; the signed app configures it; other processes are still rejected |
| Soaks at 88.2 and 96 kHz | Not yet run |

Found and fixed during these runs: steering rebuilt the cold-start delay
after a trim (latency grew ~0.27 ms/s), the app counted the driver's own
host process as another app playing on the displays, the volume shift
relied on conversions Core Audio does not pass to the driver, and video in
Safari fell out of sync after a pause: the audio written while the displays
restarted (about 440 ms) was played late. The driver now skips it, as 1.0.8
did, so the start of a sound after more than 2 minutes of quiet is cut (the
displays now keep running 2 minutes after the last sound, instead of 5 seconds).

## 6. Rollback

Ship 0.2.1 with driver 1.1.1. Never reuse a driver version for changed driver code.
