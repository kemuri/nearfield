import json
import os
from pathlib import Path
import pty
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGER = ROOT / ".local-release/package_dmg.sh"

# Run the actual packaging entrypoint with stand-ins for expensive commands.
# Nothing in this fixture can sign, notarize, mount a disk, or publish a release.
STUB = r'''
import json
import os
from pathlib import Path
import shutil
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TEST_EVENTS"], "a") as log:
    log.write(json.dumps({"command": command, "args": args,
                          "version": os.environ.get("MARKETING_VERSION"),
                          "configuration": os.environ.get("NEARFIELD_BUILD_CONFIGURATION"),
                          "notes": os.environ.get("NEARFIELD_RELEASE_NOTES_FILE")}) + "\n")
if os.environ.get("TEST_FAIL_STEP") == command:
    sys.exit(1)
if command == "build_app_bundle.sh":
    Path(os.environ["NEARFIELD_APP_BUNDLE"]).mkdir(parents=True)
elif command == "security":
    print("Developer ID Application: Test Identity")
elif command == "hdiutil":
    if args[0] == "create":
        Path(args[-1]).touch()
    elif args[0] == "attach":
        print("/dev/disk-test Apple_HFS Nearfield")
    elif args[0] == "convert":
        Path(args[args.index("-o") + 1]).touch()
elif command == "ditto":
    if "-c" in args:
        Path(args[-1]).touch()
    elif Path(args[0]).is_dir():
        shutil.copytree(args[0], args[1])
    else:
        shutil.copyfile(args[0], args[1])
elif command == "osascript":
    sys.stdin.read()
elif command == "generate_appcast.sh":
    assert Path(args[0]).is_file()
elif command == "publish_website_release.sh":
    assert Path(args[0]).is_file()
    assert Path(os.environ["NEARFIELD_RELEASE_NOTES_FILE"]).is_file()
'''


@unittest.skipUnless(PACKAGER.is_file(), "Private release tooling is not installed")
class ReleaseModeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="nearfield-release-modes-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.private = self.root / ".local-release"
        self.private.mkdir()
        self.script = self.private / "package_dmg.sh"
        for name in ("package_dmg.sh", "versioning.sh"):
            shutil.copy2(ROOT / ".local-release" / name, self.private / name)
        self.version = self.private / "VERSION"
        self.version.write_text("0.1.39\n")
        (self.private / "assets").mkdir()
        (self.private / "assets/dmg-background.png").touch()
        (self.root / "script").mkdir()
        shutil.copy2(ROOT / "script/update_release_changelog.py", self.root / "script")
        self.notes = self.root / "release-notes/0.1.40.json"
        self.notes.parent.mkdir()
        self.notes.write_text(json.dumps({"version": "0.1.40", "changes": ["Test release."]}))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        stub = self.bin / "stub"
        stub.write_text(f"#!{sys.executable}\n" + STUB)
        stub.chmod(0o755)
        for name in ("security", "codesign", "xcrun", "hdiutil", "ditto",
                     "spctl", "osascript", "bless", "sync"):
            (self.bin / name).symlink_to(stub)
        (self.root / "script/build_app_bundle.sh").symlink_to(stub)
        for name in ("generate_appcast.sh", "publish_website_release.sh"):
            (self.private / name).symlink_to(stub)
        self.log = self.root / "events.jsonl"
        # Do not inherit real release settings or credentials into the fixture.
        self.env = {"PATH": f"{self.bin}:{Path(sys.executable).parent}:/usr/bin:/bin",
                    "TEST_EVENTS": str(self.log),
                    "CODE_SIGN_IDENTITY": "Developer ID Application: Test Identity"}
        self.dist = self.root / "dist/release"
        self.cwd = self.root / "unrelated directory"
        self.cwd.mkdir()

    def run_release(self, *arguments, **environment):
        return subprocess.run(
            ["/bin/bash", str(self.script), *arguments], cwd=self.cwd,
            env={**self.env, **environment}, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=30,
        )

    def events(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def commands(self):
        return [event["command"] for event in self.events()]

    def assert_no_work(self):
        self.assertEqual(self.events(), [])
        self.assertFalse(self.dist.exists())
        self.assertEqual(self.version.read_text(), "0.1.39\n")

    def test_help_dry_run_and_invalid_arguments_have_no_side_effects(self):
        for arguments, expected_status in [
            (("--help",), 0), (("local", "--dry-run"), 0),
            (("--mode", "local-dmg", "--dry-run"), 0),
            (("--mode=full", "--dry-run"), 0),
            ((), 2), (("--mode",), 2), (("--mode=unknown",), 2),
            (("unknown",), 2), (("full", "local"), 2),
        ]:
            with self.subTest(arguments=arguments):
                result = self.run_release(*arguments)
                self.assertEqual(result.returncode, expected_status, result.stderr)
                self.assert_no_work()

    def test_interactive_menu_selects_each_mode_and_defaults_to_local(self):
        for selection, mode in [(b"\n", "local"), (b"1\n", "local"),
                                (b"2\n", "local-dmg"), (b"3\n", "full")]:
            with self.subTest(mode=mode, selection=selection):
                master, slave = pty.openpty()
                try:
                    with subprocess.Popen(
                        ["/bin/bash", str(self.script), "--dry-run"], cwd=self.cwd,
                        env=self.env, stdin=slave, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True,
                    ) as process:
                        os.write(master, selection)
                        stdout, stderr = process.communicate(timeout=10)
                        self.assertEqual(process.returncode, 0, stderr)
                        self.assertIn(f"Release mode: {mode}\n", stdout)
                finally:
                    os.close(master)
                    os.close(slave)
                self.assert_no_work()

    def test_local_builds_only_the_app_without_notes_or_notary_credentials(self):
        self.notes.unlink()
        result = self.run_release("local")
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.dist / "Nearfield.app"
        self.assertEqual(list(self.dist.iterdir()), [app])
        self.assertEqual(result.stdout.splitlines()[-1], str(app))
        self.assertEqual(self.commands(), ["build_app_bundle.sh", "codesign"])
        self.assertEqual(self.events()[0]["configuration"], "release")
        self.assertEqual(self.events()[0]["version"], "0.1.40")
        self.assertEqual(self.version.read_text(), "0.1.40\n")

    def test_local_dmg_notarizes_both_artifacts_without_appcast_or_website(self):
        self.notes.unlink()
        result = self.run_release("--mode", "local-dmg")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.dist / "Nearfield.app").is_dir())
        dmg = self.dist / "Nearfield-0.1.40.dmg"
        self.assertTrue(dmg.is_file())
        self.assertEqual(result.stdout.splitlines()[-1], str(dmg))
        submissions = [event["args"][2] for event in self.events()
                       if event["command"] == "xcrun" and event["args"][:2] == ["notarytool", "submit"]]
        self.assertEqual(submissions, [str(self.dist / "Nearfield-0.1.40.zip"), str(dmg)])
        self.assertNotIn("generate_appcast.sh", self.commands())
        self.assertNotIn("publish_website_release.sh", self.commands())
        self.assertEqual(self.version.read_text(), "0.1.40\n")

    def test_full_bumps_version_and_publishes_after_appcast_with_resolved_notes(self):
        result = self.run_release("full")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.version.read_text(), "0.1.40\n")
        self.assertEqual(self.commands()[-2:], ["generate_appcast.sh", "publish_website_release.sh"])
        self.assertEqual(self.events()[-1]["notes"], str(self.notes))
        self.assertEqual(self.events()[-1]["args"], [str(self.dist / "Nearfield-0.1.40.dmg")])

    def test_full_missing_or_mismatched_notes_fails_before_build_or_version_change(self):
        self.notes.write_text(json.dumps({"version": "0.1.39", "changes": ["Old notes."]}))
        result = self.run_release("full")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must name version 0.1.40", result.stderr)
        self.assert_no_work()
        self.notes.unlink()
        result = self.run_release("full")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(self.notes), result.stderr)
        self.assert_no_work()

    def test_conflicting_legacy_overrides_fail_before_any_work(self):
        for mode, environment in [
            ("local", {"NEARFIELD_PUBLISH_WEBSITE": "1"}),
            ("local-dmg", {"NEARFIELD_GENERATE_APPCAST": "1"}),
            ("full", {"NEARFIELD_PUBLISH_WEBSITE": "0"}),
            ("full", {"NEARFIELD_GENERATE_APPCAST": "0"}),
        ]:
            with self.subTest(mode=mode, environment=environment):
                result = self.run_release(mode, **environment)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("conflicts", result.stderr)
                self.assert_no_work()

    def test_explicit_version_and_notes_path_are_preserved(self):
        custom_notes = self.cwd / "custom notes.json"
        custom_notes.write_text(json.dumps({"version": "0.2.0", "changes": ["Test release."]}))
        result = self.run_release("full", MARKETING_VERSION="0.2.0",
                                  NEARFIELD_RELEASE_NOTES_FILE=custom_notes.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.version.read_text(), "0.1.39\n")
        self.assertEqual(self.events()[-1]["notes"], str(custom_notes))
        self.assertTrue((self.dist / "Nearfield-0.2.0.dmg").is_file())

    def test_local_can_disable_version_bump(self):
        result = self.run_release("local", NEARFIELD_BUMP_VERSION="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.version.read_text(), "0.1.39\n")

    def test_app_only_notarization_override_never_creates_a_dmg(self):
        result = self.run_release("local", NEARFIELD_NOTARIZE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("xcrun", self.commands())
        self.assertNotIn("hdiutil", self.commands())
        self.assertEqual(list(self.dist.iterdir()), [self.dist / "Nearfield.app"])

    def test_build_and_appcast_failures_cannot_publish_or_advance_version(self):
        for step in ("build_app_bundle.sh", "hdiutil", "generate_appcast.sh"):
            with self.subTest(step=step):
                if self.log.exists():
                    self.log.unlink()
                if self.dist.exists():
                    shutil.rmtree(self.dist)
                result = self.run_release("full", TEST_FAIL_STEP=step)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("publish_website_release.sh", self.commands())
                self.assertEqual(self.version.read_text(), "0.1.39\n")

    def test_publisher_failure_preserves_packaged_version_for_retry(self):
        result = self.run_release("full", TEST_FAIL_STEP="publish_website_release.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.version.read_text(), "0.1.40\n")
        self.assertTrue((self.dist / "Nearfield-0.1.40.dmg").is_file())


if __name__ == "__main__":
    unittest.main()
