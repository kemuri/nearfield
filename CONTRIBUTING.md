# Contributing to Nearfield

Thanks for helping improve Nearfield. Bug reports, focused fixes, tests, and
documentation improvements are welcome.

## Before opening an issue

- Search existing issues first.
- Include your macOS version, Mac model, Studio Display count, and connection
  layout when reporting device-detection or routing problems.
- Include exact reproduction steps and relevant logs, but remove usernames,
  device serial numbers, signing identities, tokens, and other private data.
- Use the process in [SECURITY.md](SECURITY.md) for vulnerabilities.

## Development setup

Nearfield requires macOS 14 or later and Xcode with the macOS SDK and command-line
tools.

```sh
git clone https://github.com/kemuri/nearfield.git
cd nearfield
swift build
swift test
```

Launch a development app with:

```sh
./script/build_and_run.sh
```

Installing the HAL driver modifies `/Library/Audio/Plug-Ins/HAL`, requires an
administrator password, and restarts CoreAudio. Most unit-test and UI work does
not require installing the driver.

## Pull requests

1. Keep each pull request focused on one change.
2. Add or update regression tests for behavior changes.
3. Run `swift build`, `swift test`, and `git diff --check`.
4. Explain user-visible behavior, permissions, or driver changes in the pull
   request description.
5. Never commit credentials, provisioning profiles, or locally generated app
   artifacts.

The active HAL driver fork lives in `Vendor/app-router-audio-device`. Changes to
the driver should build through `./script/build_router_driver.sh` and preserve
the license in that directory.

## Style

- Follow the existing Swift and C++ style in the file you are editing.
- Prefer small, explicit changes over unrelated cleanup.
- Keep user-facing copy direct and describe any required macOS permission before
  requesting it.
