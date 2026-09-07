#!/usr/bin/env python3
"""Require release notes and update the website from the matching Sparkle item."""

import argparse
from datetime import date
from email.utils import parsedate_to_datetime
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


VERSION = re.compile(r"\d+\.\d+\.\d+")
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def version_key(version):
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError("Expected a release version in MAJOR.MINOR.PATCH format")
    return tuple(int(part) for part in version.split("."))


def validate_notes(notes, version):
    version_key(version)
    if not isinstance(notes, dict) or notes.get("version") != version:
        raise ValueError(f"Release notes must name version {version}")
    changes = notes.get("changes")
    if not isinstance(changes, list) or not changes or any(
        not isinstance(change, str) or not change.strip() for change in changes
    ):
        raise ValueError("Release notes must contain a nonempty list of change summaries")
    return [change.strip() for change in changes]


def release_date(appcast, version):
    version_key(version)
    items = [item for item in ET.parse(appcast).findall("./channel/item")
             if item.findtext(f"{SPARKLE}shortVersionString") == version]
    if len(items) != 1:
        raise ValueError(f"Expected exactly one appcast item for version {version}")
    published = parsedate_to_datetime(items[0].findtext("pubDate", ""))
    if published.tzinfo is None:
        raise ValueError("The appcast release date must include a timezone")
    return published.date().isoformat()


def updated_releases(releases, version, published, notes=None):
    version_key(version)
    date.fromisoformat(published)
    if not isinstance(releases, list):
        raise ValueError("Website changelog must be a JSON array")
    seen = set()
    for entry in releases:
        if not isinstance(entry, dict):
            raise ValueError("Every changelog entry must be an object")
        existing_version = entry.get("version")
        version_key(existing_version)
        validate_notes(entry, existing_version)
        existing_date = entry.get("date")
        if not isinstance(existing_date, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", existing_date):
            raise ValueError("Changelog dates must use YYYY-MM-DD")
        date.fromisoformat(existing_date)
        if existing_version in seen:
            raise ValueError(f"Duplicate changelog version: {existing_version}")
        seen.add(existing_version)

    existing = next((entry for entry in releases if entry["version"] == version), None)
    changes = validate_notes(notes, version) if notes is not None else None
    if existing:
        if existing["date"] != published or (changes is not None and existing["changes"] != changes):
            raise ValueError(f"Changelog for {version} already exists with different content; review it explicitly")
        return releases
    if changes is None:
        raise ValueError(f"Missing changelog for {version}; set NEARFIELD_RELEASE_NOTES_FILE")
    return sorted([*releases, {"version": version, "date": published, "changes": changes}],
                  key=lambda entry: version_key(entry["version"]), reverse=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preflight = commands.add_parser("validate-notes")
    preflight.add_argument("--version", required=True)
    preflight.add_argument("--notes", required=True, type=Path)
    update = commands.add_parser("update")
    update.add_argument("--version", required=True)
    update.add_argument("--appcast", required=True, type=Path)
    update.add_argument("--website", required=True, type=Path)
    update.add_argument("--notes", type=Path)
    args = parser.parse_args()
    try:
        notes = json.loads(args.notes.read_text()) if args.notes else None
        if args.command == "validate-notes":
            validate_notes(notes, args.version)
            return 0
        published = release_date(args.appcast, args.version)
        path = args.website / "src/data/releases.json"
        if not (args.website / "src/pages/changelog.astro").is_file():
            raise ValueError("Website changelog page is missing; synchronize the website changes first")
        # A missing history file is an integration error, never a reason to discard history.
        releases = json.loads(path.read_text())
        updated = updated_releases(releases, args.version, published, notes)
        if updated != releases:
            temporary = path.with_suffix(".json.tmp")
            temporary.write_text(json.dumps(updated, indent=2, ensure_ascii=False) + "\n")
            temporary.replace(path)
        print(published)
        return 0
    except (OSError, ValueError, TypeError, ET.ParseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
