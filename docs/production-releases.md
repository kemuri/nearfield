# Production releases

Every production release updates the changelog at trynearfield.com with its
version, release date, and short user-facing change summaries. Review the changes
since the previous shipped release; include only changes in the build being released.

Choose what to build with the private release entrypoint:

```sh
./.local-release/package_dmg.sh local      # Release .app only
./.local-release/package_dmg.sh local-dmg  # Signed, notarized .app and DMG
./.local-release/package_dmg.sh full       # DMG, Sparkle, downloads, and website
```

Running it without arguments opens a menu in an interactive terminal, including
from the **Release Build** action. Non-interactive callers must pass a mode.
`--mode local`, `--mode local-dmg`, and `--mode full` are also accepted.
Add `--dry-run` to preview the version, paths, and steps without changing files
or checking signing, notarization, or publishing prerequisites.

All modes build the Release configuration and verify the app's signature.
`local` skips notarization by default. `local-dmg` notarizes the app and DMG.
Both local modes skip release notes, Sparkle appcast generation, and all website
changes. `full` also signs the appcast, uploads the downloads, updates the website
version and changelog, deploys the website, and verifies the published release.

All three modes increment the patch version in `.local-release/VERSION`.
Local saves it after the app passes verification; Local DMG saves it after DMG
verification; Full saves it after appcast generation, before publishing.
`NEARFIELD_BUMP_VERSION=0` rebuilds without advancing the version.
`MARKETING_VERSION` sets an exact version without changing the version counter.
For a minor release such as 0.2.0, build with `MARKETING_VERSION=0.2.0`, then
write `0.2.0` to `.local-release/VERSION` after publishing so the next patch
release is 0.2.1.
The existing signing and notarization environment overrides remain available.
The mode controls `NEARFIELD_PUBLISH_WEBSITE` and `NEARFIELD_GENERATE_APPCAST`;
conflicting legacy overrides stop the script before it builds anything.

When shipping HAL driver changes, increment `CURRENT_PROJECT_VERSION` and
`MARKETING_VERSION` in all three **ProxyAudioDevice target** configurations in
`Vendor/app-router-audio-device/proxyAudioDevice.xcodeproj/project.pbxproj`.
The driver has its own version, independent of the app version. Do not reuse a
driver version for changed driver code. App-only releases can retain it.

On launch, an existing installation with an older driver is offered the newer
driver bundled with the app. Choosing Later keeps the existing driver running;
Settings continues to show Update, and the prompt returns on the next launch.
Updating requires administrator approval and restarts CoreAudio. The installer
checks the installed version and waits for CoreAudio to load the driver before
reporting success. Test an upgrade from the previous driver's version before
publishing a release that changes the driver.

Prepare `release-notes/<version>.json` with the exact version being packaged:

```json
{
  "version": "0.1.39",
  "changes": [
    "Replace this example with a short summary of a change in this release."
  ]
}
```

Full mode automatically loads the notes matching the release version. For
example, with the current version at `0.1.38`, it loads
`release-notes/0.1.39.json`:

```sh
./.local-release/package_dmg.sh full
```

To use a notes file elsewhere, pass its path explicitly:

```sh
NEARFIELD_RELEASE_NOTES_FILE=/absolute/path/to/release-notes.json \
  ./.local-release/package_dmg.sh full
```

The packager validates the notes before building or changing the version and
passes the resolved file to the website publisher. Missing notes report the
expected version and file path. To check the next release's notes without
building or publishing:

```sh
python3 script/update_release_changelog.py validate-notes --version 0.1.39
```

The website publisher uses
the matching appcast item's publication date, updates `src/data/releases.json`,
and includes it in the same commit as the version and downloads. Missing notes,
duplicate versions, invalid dates, or conflicting historical entries stop
publication. A retry can reuse an identical existing entry. Keep historical
dates and summaries unchanged unless correcting them deliberately.

The website changelog code and data must be on the website's release branch
before using the publisher. Its isolated checkout uses that branch, not local
uncommitted website changes. Verify `/changelog/` after deployment; the publisher
checks for the released version and date in the rendered page.

If website publishing fails after a Full build, retry with the existing DMG:

```sh
./.local-release/publish_website_release.sh ./dist/release/Nearfield-<version>.dmg
```

The publisher also discovers `release-notes/<version>.json`. If you used an
external notes file, pass the same `NEARFIELD_RELEASE_NOTES_FILE` override.
A Local DMG has no matching appcast generated by that run. To publish it later,
prepare notes for its version and run `.local-release/generate_appcast.sh` with
the DMG path before invoking the publisher. Use a new release version when the
DMG contains changes to a previously published version.

The packaging and publishing scripts remain private under `.local-release/`.
The changelog updater and release tests are tracked. Mode tests use temporary
fixtures and stub external commands; they skip when the private tooling is absent:

```sh
python3 -m unittest discover -s Tests/ReleaseTests -v
```
