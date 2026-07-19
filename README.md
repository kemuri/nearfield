# Nearfield

Nearfield is an open-source macOS menu bar app that turns the speakers in two
Apple Studio Displays into one volume-controllable stereo output.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> [!TIP]
> Prefer a ready-to-install version? [Buy Nearfield at trynearfield.com](https://trynearfield.com).

## What it does

- Detects two connected Studio Display speaker outputs.
- Publishes a single `Nearfield` stereo output with system volume control.
- Lets you swap left and right displays, adjust balance, and play test tones.
- Supports stereo and mono output modes.
- Can route selected apps or app windows to the left display, right display,
  both displays, or mute.
- Includes an optional Wave Lab visualization and can launch at login.

Nearfield is an early-stage project. App and per-window routing are experimental,
and macOS may expose several windows from one app as a single audio process. In
that case, Nearfield cannot split those windows into separate audio streams.

## Requirements

- macOS 14 Sonoma or later
- Two Apple Studio Displays connected to the same Mac
- Xcode with the macOS SDK and command-line tools
- Administrator access to install the CoreAudio HAL driver

## Run from source

```sh
git clone https://github.com/kemuri/nearfield.git
cd nearfield
./script/build_and_run.sh
```

This builds an ad-hoc-signed `Nearfield Dev.app` under `dist/` and launches it.
Complete the onboarding flow to install the bundled audio driver. Driver
installation asks for an administrator password and restarts CoreAudio, which
briefly interrupts system audio.

To install or update only the driver:

```sh
./script/install_router_driver.sh
```

## Development

Build and run the Swift package tests with:

```sh
swift build
swift test
```

Useful scripts:

| Command | Purpose |
| --- | --- |
| `./script/build_and_run.sh` | Build and launch the development app |
| `./script/build_and_run.sh --debug` | Build and run under LLDB |
| `./script/build_router_driver.sh` | Build the vendored HAL driver |

The Metal toolchain is optional. Without it, Wave Lab uses its SwiftUI
fallback. Xcode can install it with:

```sh
xcodebuild -downloadComponent MetalToolchain
```

## Permissions and system changes

- The HAL driver is installed at
  `/Library/Audio/Plug-Ins/HAL/NearfieldAudioDevice.driver`.
- Installing, updating, or removing that driver requires administrator access
  and restarts CoreAudio.
- Screen Recording permission is requested only for features that inspect
  windows or capture system output for visualization.
- Nearfield can register itself as a macOS login item when you enable that
  setting.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
for the development workflow. Please report security issues as described in
[SECURITY.md](SECURITY.md), not in a public issue.

## License

Nearfield is available under the [MIT License](LICENSE). The vendored
proxy-audio-device code retains its own public-domain [license](Vendor/app-router-audio-device/LICENSE).
