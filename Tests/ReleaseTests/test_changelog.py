import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "script/update_release_changelog.py"
spec = importlib.util.spec_from_file_location("changelog", SCRIPT)
changelog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changelog)


class ChangelogTests(unittest.TestCase):
    def setUp(self):
        self.history = [{"version": "0.1.9", "date": "2026-08-06", "changes": ["Fixed startup."]}]
        self.notes = {"version": "0.1.10", "changes": ["Fixed volume recovery."]}

    def test_adds_release_in_numeric_order_and_preserves_history(self):
        result = changelog.updated_releases(self.history, "0.1.10", "2026-09-07", self.notes)
        self.assertEqual(result[0], {**self.notes, "date": "2026-09-07"})
        self.assertEqual(result[1:], self.history)
        self.assertEqual(len(self.history), 1)

    def test_retry_is_idempotent_and_can_reuse_published_notes(self):
        result = changelog.updated_releases(self.history, "0.1.10", "2026-09-07", self.notes)
        self.assertEqual(changelog.updated_releases(result, "0.1.10", "2026-09-07", self.notes), result)
        self.assertEqual(changelog.updated_releases(result, "0.1.10", "2026-09-07"), result)

    def test_missing_notes_wrong_version_and_empty_summaries_fail(self):
        for notes in [None, {"version": "0.1.11", "changes": ["Fix."]},
                      {"version": "0.1.10", "changes": []},
                      {"version": "0.1.10", "changes": [" "]}]:
            with self.subTest(notes=notes), self.assertRaises(ValueError):
                changelog.updated_releases(self.history, "0.1.10", "2026-09-07", notes)

    def test_retries_cannot_rewrite_historical_date_or_summary(self):
        for published, notes in [("2026-08-07", None),
                                 ("2026-08-06", {"version": "0.1.9", "changes": ["Different."]})]:
            with self.subTest(published=published), self.assertRaises(ValueError):
                changelog.updated_releases(self.history, "0.1.9", published, notes)

    def test_duplicate_versions_and_invalid_dates_fail(self):
        for history in [self.history * 2, [{**self.history[0], "date": "2026-02-30"}]]:
            with self.subTest(history=history), self.assertRaises(ValueError):
                changelog.updated_releases(history, "0.1.10", "2026-09-07", self.notes)

    def test_date_comes_from_matching_appcast_item_in_its_timezone(self):
        with tempfile.TemporaryDirectory() as directory:
            appcast = Path(directory) / "appcast.xml"
            appcast.write_text('''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel><item><sparkle:shortVersionString>0.1.10</sparkle:shortVersionString>
              <pubDate>Mon, 07 Sep 2026 00:30:00 +0200</pubDate></item></channel></rss>''')
            self.assertEqual(changelog.release_date(appcast, "0.1.10"), "2026-09-07")
            with self.assertRaises(ValueError):
                changelog.release_date(appcast, "0.1.11")

    def test_cli_updates_real_files_and_failed_retry_preserves_them(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src/data").mkdir(parents=True)
            (root / "src/pages").mkdir()
            (root / "src/pages/changelog.astro").touch()
            history = root / "src/data/releases.json"
            history.write_text(json.dumps(self.history))
            notes = root / "notes.json"
            notes.write_text(json.dumps(self.notes))
            appcast = root / "appcast.xml"
            appcast.write_text('''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel><item><sparkle:shortVersionString>0.1.10</sparkle:shortVersionString>
              <pubDate>Mon, 07 Sep 2026 10:58:03 +0200</pubDate></item></channel></rss>''')
            command = [sys.executable, str(SCRIPT), "update", "--version", "0.1.10",
                       "--appcast", str(appcast), "--website", str(root), "--notes", str(notes)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "2026-09-07")
            published = history.read_bytes()
            notes.write_text(json.dumps({**self.notes, "changes": ["Rewritten history."]}))
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already exists", result.stderr)
            self.assertEqual(history.read_bytes(), published)


class ReleaseNotesDiscoveryTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.script = self.root / "script/update_release_changelog.py"
        self.script.parent.mkdir()
        shutil.copyfile(SCRIPT, self.script)
        self.notes = self.root / "release-notes/0.1.10.json"
        self.notes.parent.mkdir()
        self.content = {"version": "0.1.10", "changes": ["Fixed volume recovery."]}
        self.notes.write_text(json.dumps(self.content))
        self.cwd = self.root / "unrelated-directory"
        self.cwd.mkdir()

    def run_command(self, *arguments):
        return subprocess.run(
            [sys.executable, str(self.script), *arguments], cwd=self.cwd,
            capture_output=True, text=True,
        )

    def test_preflight_discovers_versioned_notes_independently_of_working_directory(self):
        result = self.run_command("validate-notes", "--version", "0.1.10")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.notes))

    def test_explicit_path_takes_priority_and_is_resolved_for_publisher(self):
        override = self.cwd / "custom notes.json"
        override.write_text(json.dumps(self.content))
        result = self.run_command("validate-notes", "--version", "0.1.10",
                                  "--notes", override.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(override))

        override.write_text(json.dumps({**self.content, "version": "0.1.9"}))
        result = self.run_command("validate-notes", "--version", "0.1.10",
                                  "--notes", override.name)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must name version 0.1.10", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_future_release_cannot_reuse_previous_notes(self):
        result = self.run_command("validate-notes", "--version", "0.1.11")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(self.root / "release-notes/0.1.11.json"), result.stderr)
        self.assertEqual(result.stdout, "")

    def test_discovered_notes_still_require_exact_version_and_changes(self):
        for content in [{**self.content, "version": "0.1.9"},
                        {**self.content, "changes": []}]:
            with self.subTest(content=content):
                self.notes.write_text(json.dumps(content))
                result = self.run_command("validate-notes", "--version", "0.1.10")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_publisher_uses_discovered_notes_and_appcast_date(self):
        website = self.root / "website"
        (website / "src/data").mkdir(parents=True)
        (website / "src/pages").mkdir()
        (website / "src/pages/changelog.astro").touch()
        history = website / "src/data/releases.json"
        history.write_text("[]")
        appcast = self.root / "appcast.xml"
        appcast.write_text('''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><item><sparkle:shortVersionString>0.1.10</sparkle:shortVersionString>
          <pubDate>Mon, 21 Sep 2026 10:00:00 +0200</pubDate></item></channel></rss>''')
        arguments = ("update", "--version", "0.1.10", "--website", str(website),
                     "--appcast", str(appcast))
        result = self.run_command(*arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(history.read_text()),
                         [{**self.content, "date": "2026-09-21"}])

        # Retrying a published release still works when its local notes are absent.
        self.notes.unlink()
        result = self.run_command(*arguments)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
