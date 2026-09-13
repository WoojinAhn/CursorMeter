"""Exercise architecture selection without network access or a live app."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"
BASE_URL = "https://github.com/WoojinAhn/CursorMeter/releases/download/v0.11.0/"
ARM_ZIP = "CursorMeter-0.11.0.zip"
INTEL_ZIP = "CursorMeter-0.11.0-x86_64.zip"

MOCK_TOOL = r'''
import json
import os
from pathlib import Path
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["INSTALL_TEST_ROOT"])
config = json.loads((root / "config.json").read_text())
with (root / "calls.jsonl").open("a") as calls:
    calls.write(json.dumps([command, *args]) + "\n")

if command == "uname":
    assert args == ["-m"], args
    print(config["arch"])
    sys.exit(config.get("uname_status", 0))
elif command == "sysctl":
    assert args == ["-in", "sysctl.proc_translated"], args
    print(config["translated"])
    sys.exit(config.get("sysctl_status", 0))
elif command == "curl":
    url = args[1]
    if url.endswith("/releases/latest"):
        print((root / "release.json").read_text())
    else:
        assert args[2] == "-o", args
        Path(args[3]).write_bytes((root / "assets" / url.rsplit("/", 1)[1]).read_bytes())
elif command == "ditto":
    assert args[0] == "-xk", args
    binary = Path(args[2]) / "CursorMeter.app/Contents/MacOS/CursorMeter"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(Path(args[1]).read_bytes())
    binary.chmod(0o755)
elif command == "pgrep":
    sys.exit(1)
elif command in ("xattr", "open"):
    pass
else:
    raise AssertionError("Unexpected side effect: " + command)
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cursormeter-install-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for command in ("uname", "sysctl", "curl", "ditto", "xattr", "pgrep", "pkill", "open", "sleep"):
            mock = self.bin / command
            mock.write_text(f"#!{sys.executable}\n" + MOCK_TOOL)
            mock.chmod(0o755)
        self.app = self.root / "CursorMeter.app"
        self.binary = self.app / "Contents/MacOS/CursorMeter"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_text("existing installation")

    def run_installer(self, arch="arm64", translated="", assets=None,
                      corrupt=None, checksums=True, **config):
        config.update(arch=arch, translated=translated)
        (self.root / "config.json").write_text(json.dumps(config))
        asset_dir = self.root / "assets"
        asset_dir.mkdir()
        names = []
        for name in assets if assets is not None else (INTEL_ZIP, ARM_ZIP):
            payload = f"new installation: {name}".encode()
            (asset_dir / name).write_bytes(payload)
            names.append(name)
            if checksums:
                digest = "0" * 64 if name == corrupt else hashlib.sha256(payload).hexdigest()
                (asset_dir / f"{name}.sha256").write_text(f"{digest}  {name}\n")
                names.append(f"{name}.sha256")
        release = {"tag_name": "v0.11.0", "assets": [
            {"name": name, "browser_download_url": BASE_URL + name} for name in names
        ]}
        (self.root / "release.json").write_text(json.dumps(release, indent=2))
        env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                   APP_DEST=str(self.app), INSTALL_TEST_ROOT=str(self.root))
        self.result = subprocess.run(["/bin/bash", str(INSTALLER)], env=env,
                                     capture_output=True, text=True)
        self.calls = [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]
        return self.result.stdout + self.result.stderr

    def assert_installed(self, name):
        self.assertEqual(self.result.returncode, 0, self.result.stdout + self.result.stderr)
        self.assertEqual(self.binary.read_text(), f"new installation: {name}")
        downloads = [call[2] for call in self.calls if call[0] == "curl" and "-o" in call]
        self.assertEqual(downloads, [BASE_URL + name, BASE_URL + name + ".sha256"])

    def assert_untouched(self):
        self.assertNotEqual(self.result.returncode, 0)
        self.assertEqual(self.binary.read_text(), "existing installation")
        self.assertFalse(any(call[0] in ("ditto", "xattr", "pkill", "open") for call in self.calls))

    def test_native_apple_silicon(self):
        self.run_installer()
        self.assert_installed(ARM_ZIP)
        self.assertFalse(any(call[0] == "sysctl" for call in self.calls))

    def test_intel_with_absent_rosetta_key(self):
        self.run_installer(arch="x86_64")
        self.assert_installed(INTEL_ZIP)

    def test_intel_with_zero_rosetta_flag(self):
        self.run_installer(arch="x86_64", translated="0")
        self.assert_installed(INTEL_ZIP)

    def test_rosetta_selects_native_apple_silicon(self):
        self.run_installer(arch="x86_64", translated="1")
        self.assert_installed(ARM_ZIP)

    def test_unsupported_architecture(self):
        output = self.run_installer(arch="riscv64")
        self.assert_untouched()
        self.assertIn("Unsupported architecture", output)
        self.assertFalse(any(call[0] == "curl" for call in self.calls))

    def test_uname_failure(self):
        output = self.run_installer(uname_status=1)
        self.assert_untouched()
        self.assertIn("Could not determine", output)

    def test_rosetta_probe_failure(self):
        output = self.run_installer(arch="x86_64", sysctl_status=1)
        self.assert_untouched()
        self.assertIn("Could not determine", output)

    def test_unexpected_rosetta_value(self):
        output = self.run_installer(arch="x86_64", translated="unexpected")
        self.assert_untouched()
        self.assertIn("Unexpected Rosetta", output)

    def test_missing_intel_asset_never_downloads_arm(self):
        output = self.run_installer(arch="x86_64", assets=(ARM_ZIP,))
        self.assert_untouched()
        self.assertIn(f"no asset named {INTEL_ZIP}", output)
        self.assertFalse(any(call[0] == "curl" and "-o" in call for call in self.calls))

    def test_intel_checksum_mismatch_preserves_old_app(self):
        output = self.run_installer(arch="x86_64", corrupt=INTEL_ZIP)
        self.assert_untouched()
        self.assertIn(f"checksum mismatch for {INTEL_ZIP}", output)

    def test_arm_checksum_mismatch_preserves_old_app(self):
        output = self.run_installer(corrupt=ARM_ZIP)
        self.assert_untouched()
        self.assertIn(f"checksum mismatch for {ARM_ZIP}", output)

    def test_legacy_arm_release_without_checksums(self):
        output = self.run_installer(assets=(ARM_ZIP,), checksums=False)
        self.assertEqual(self.result.returncode, 0, output)
        self.assertEqual(self.binary.read_text(), f"new installation: {ARM_ZIP}")
        self.assertIn("publishes no checksum; skipping verification", output)


if __name__ == "__main__":
    unittest.main()
