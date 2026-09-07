# Production releases

Every production release updates the changelog at trynearfield.com with its
version, release date, and short user-facing change summaries. Review the changes
since the previous shipped release; include only changes in the build being released.

Prepare a JSON notes file with the exact version being packaged:

```json
{
  "version": "0.1.39",
  "changes": [
    "Replace this example with a short summary of a change in this release."
  ]
}
```

Pass its absolute path when running the private production entrypoint:

```sh
NEARFIELD_RELEASE_NOTES_FILE=/absolute/path/to/release-notes.json \
  ./.local-release/package_dmg.sh
```

The packager validates the notes before building. The website publisher uses
the matching appcast item's publication date, updates `src/data/releases.json`,
and includes it in the same commit as the version and downloads. Missing notes,
duplicate versions, invalid dates, or conflicting historical entries stop
publication. A retry can reuse an identical existing entry. Keep historical
dates and summaries unchanged unless correcting them deliberately.

The website changelog code and data must be on the website's release branch
before using the publisher. Its isolated checkout uses that branch, not local
uncommitted website changes. Verify `/changelog/` after deployment; the publisher
checks for the released version and date in the rendered page.

Packaging with `NEARFIELD_PUBLISH_WEBSITE=0` does not publish or update the website.
If publishing the resulting DMG later, pass the same notes file to
`.local-release/publish_website_release.sh`.

The packaging and publishing scripts remain private under `.local-release/`.
The changelog updater and its tests are tracked:

```sh
python3 -m unittest discover -s Tests/ReleaseTests -v
```
