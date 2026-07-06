# Nearfield

Nearfield is a small macOS menu bar app that finds two Studio Display speaker
outputs, creates a CoreAudio aggregate output named `Nearfield Target`, and
routes a volume-controllable router output named `Nearfield` into it.

## Run

```sh
./script/build_and_run.sh
```

The Codex app `Run` action is wired to the same script.

## Build

Local development builds use the normal debug path:

```sh
./script/build_and_run.sh
```

## Router Driver

Nearfield vendors a router-capable Proxy Audio Device fork under
`Vendor/app-router-audio-device`. It builds as
`NearfieldAudioDevice.driver` and exposes the user-facing output
`Nearfield`.

```sh
./script/build_router_driver.sh
```

Install or update the driver from Settings, or run:

```sh
./script/install_router_driver.sh
```

The install script copies `NearfieldAudioDevice.driver` into
`/Library/Audio/Plug-Ins/HAL`, fixes ownership, ad-hoc signs it, and restarts
CoreAudio. After CoreAudio reloads it, Nearfield configures the router output
to forward to the underlying `Nearfield Target` aggregate and selects the
router device named `Nearfield` as the system output.

## Behavior

- Starts as an icon-only menu bar app.
- Automatically creates/selects the pair on launch when two Studio Display
  speaker outputs are connected.
- Opens a Settings panel for stereo/mono output, left/right monitor assignment,
  audio routing, open-at-login, router driver setup/reinstall, and removing the
  driver plus old aggregate devices.
- Includes left/right test-tone buttons in Settings to identify the physical
  channel assignment.
- Includes a left/right balance slider for biasing output between displays.
- Uses the router output when the driver is installed, so the macOS menu
  bar and Control Center volume slider can adjust the pair.
- Falls back to keyboard volume up/down/mute handling when only the aggregate
  device is available.
- Keeps the menu bar context menu to Settings and Quit.
- Can register or unregister itself as a login item from Settings.

## Audio Note

Nearfield uses macOS's built-in CoreAudio aggregate-device API for the physical
Studio Display pair, then uses the vendored router HAL driver as a
volume-controllable output in front of that aggregate.

The active `Nearfield Target` aggregate must remain visible to CoreAudio while
using the current router architecture, because the HAL driver forwards audio
into that target. Apple's `kAudioAggregateDeviceIsPrivateKey` makes an
aggregate private to the creating process, which would prevent the out-of-process
HAL driver from reliably addressing it. Fully removing the target from the
system speaker list requires the router driver to write directly to both Studio
Displays instead of proxying through an aggregate.

## App Routing

Open Settings and enable `App Routing` to route selected apps through the router
driver. The router output appears in macOS Sound settings only after the admin
install completes and CoreAudio reloads the HAL plug-in.

Route rules are a semicolon-separated list:

```text
com.spotify.client=pair; app.zen-browser.zen=window
```

Accepted destinations are `left`, `right`, `pair`, `muted`, and `window`.
`window` is resolved by the Nearfield app into `pid:<processID>=left/right`
rules based on visible windows for that bundle ID, plus a bundle fallback based
on the largest visible window. The HAL driver applies PID rules before bundle
rules. Apps with no matching rule play as `pair`, which preserves normal stereo
across both displays.

True simultaneous per-window routing depends on macOS exposing separate audio
client processes for the windows. If multiple windows share one audio process,
Nearfield cannot split that one mixed stream by window; it routes that process
using the largest visible window for the process. This is still a driver-level
spike: the next validation step is runtime testing to confirm CoreAudio calls
the driver's per-client mix operation for real-world apps.
