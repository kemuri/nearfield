from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[2] / "script/packaged_runtime_paths.sh"
FRAMEWORKS = "@executable_path/../Frameworks"
METAL = ("/var/run/com.apple.security.cryptexd/mnt/"
         "com.apple.MobileAsset.MetalToolchain-v27.1.266.1.pTghMd/"
         "Metal.xctoolchain/usr/lib/swift-6.2/macosx")


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS Mach-O tools")
class RuntimePathsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="nearfield-runtime-paths-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.root = Path(cls.directory.name)
        source = cls.root / "main.c"
        source.write_text('int main(void) { return 0; }\n')
        cls.fixture = cls.root / "fixture"
        subprocess.run(["xcrun", "clang", str(source), "-o", str(cls.fixture),
                        "-Wl,-headerpad_max_install_names", "-Wl,-rpath,/usr/lib/swift",
                        "-Wl,-rpath,@loader_path", f"-Wl,-rpath,{FRAMEWORKS}"],
                       capture_output=True, text=True, check=True)

    def setUp(self):
        self.binary = self.root / "Packaged App"
        shutil.copy2(self.fixture, self.binary)

    def add_path(self, path):
        subprocess.run(["install_name_tool", "-add_rpath", path, str(self.binary)],
                       capture_output=True, text=True, check=True)

    def run_helper(self, command):
        return subprocess.run(
            ["bash", "-c", 'set -euo pipefail; source "$1"; ' + command,
             "test", str(HELPER), str(self.binary)], capture_output=True, text=True,
        )

    def test_removes_mounted_metal_and_xcode_toolchains_before_validation(self):
        for path in [METAL, "/private" + METAL,
                     "/Applications/Xcode.app/Contents/Developer/Toolchains/"
                     "XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx",
                     "/Applications/Xcode Beta.app/Contents/Developer/Toolchains/"
                     "XcodeDefault.xctoolchain/usr/lib/swift-6.3/macosx"]:
            self.add_path(path)
        result = self.run_helper('remove_build_toolchain_rpaths "$2"; '
                                 'validate_runtime_rpaths "$2"; runtime_rpaths "$2"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["/usr/lib/swift", "@loader_path", FRAMEWORKS])
        subprocess.run(["codesign", "--force", "--sign", "-", str(self.binary)],
                       capture_output=True, check=True)
        subprocess.run([str(self.binary)], check=True)

    def test_unknown_search_path_is_preserved_and_rejected(self):
        path = "/tmp/unexpected runtime/lib"
        self.add_path(path)
        result = self.run_helper('remove_build_toolchain_rpaths "$2"; validate_runtime_rpaths "$2"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"unexpected runtime search path in packaged executable: {path}", result.stderr)
        self.assertIn(path, self.run_helper('runtime_rpaths "$2"').stdout.splitlines())

    def test_framework_search_path_is_still_required(self):
        subprocess.run(["install_name_tool", "-delete_rpath", FRAMEWORKS, str(self.binary)],
                       capture_output=True, check=True)
        result = self.run_helper('validate_runtime_rpaths "$2"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"missing {FRAMEWORKS}", result.stderr)

    def test_already_clean_binary_is_unchanged(self):
        before = self.binary.read_bytes()
        result = self.run_helper('remove_build_toolchain_rpaths "$2"; validate_runtime_rpaths "$2"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, self.binary.read_bytes())


if __name__ == "__main__":
    unittest.main()
