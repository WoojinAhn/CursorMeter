"""Exercise local signing without compiling, signing, or accessing Keychain."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
IDENTITY = "0123456789abcdef0123456789abcdef01234567"
MOCK_TOOL = r'''
import json
import os
from pathlib import Path
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["PACKAGE_TEST_ROOT"])
with (root / "calls.jsonl").open("a") as calls:
    calls.write(json.dumps([tool, *args]) + "\n")
if tool == "swift":
    if "--show-bin-path" in args:
        print(root / "compiled binary")
elif tool == "lipo":
    print("arm64")
elif tool == "git":
    if args[:1] == ["rev-parse"]:
        print("abc1234")
    elif args[:1] == ["rev-list"]:
        print("0")
elif tool == "codesign":
    if "--verify" in args:
        sys.exit(int(os.environ.get("TEST_VERIFY_STATUS", "0")))
    sys.exit(int(os.environ.get("TEST_SIGN_STATUS", "0")))
else:
    raise AssertionError("Unexpected application mutation: " + tool)
'''


class PackageAppTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cursormeter-package-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "repo with spaces"
        self.root.mkdir()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        for tool in ("swift", "lipo", "git", "codesign"):
            self.mock(tool)
        (self.root / "Resources").mkdir()
        (self.root / "Resources/AppIcon.icns").write_bytes(b"test icon")
        (self.root / "compiled binary").mkdir()
        (self.root / "compiled binary/CursorMeter").write_bytes(b"test executable")
        self.output = self.root / "output with spaces"
        self.app = self.output / "CursorMeter.app"
        self.app.mkdir(parents=True)
        self.sentinel = self.app / "existing-build"
        self.sentinel.write_text("preserved")
        self.env = dict(os.environ, PATH=f"{self.tools}:/usr/bin:/bin:/usr/sbin:/sbin",
                        PACKAGE_TEST_ROOT=str(self.root), BUILD_ARCH="arm64",
                        APP_OUTPUT_DIR=str(self.output), BUILD_CHANNEL="dev")
        for key in ("CM_DEV_SIGNING_IDENTITY", "TEST_SIGN_STATUS", "TEST_VERIFY_STATUS"):
            self.env.pop(key, None)

    def mock(self, tool):
        path = self.tools / tool
        path.write_text(f"#!{sys.executable}\n" + MOCK_TOOL)
        path.chmod(0o755)

    def invoke(self, **environment):
        self.env.update(environment)
        return subprocess.run(["/bin/bash", str(SCRIPTS / "package_app.sh")],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def calls(self):
        log = self.root / "calls.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def signatures(self):
        return [call for call in self.calls() if call[0] == "codesign"]

    def test_default_dev_keeps_adhoc_and_dev_marker(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        signed, verified = self.signatures()
        self.assertEqual(signed[signed.index("-s") + 1], "-")
        self.assertIn("--strict", verified)
        with (self.app / "Contents/Info.plist").open("rb") as source:
            self.assertEqual(plistlib.load(source)["CMDevBuildCommit"], "abc1234")

    def test_default_release_keeps_adhoc_without_dev_marker(self):
        result = self.invoke(BUILD_CHANNEL="release", APP_VERSION="1.2.3")
        self.assertEqual(result.returncode, 0, result.stderr)
        signed = self.signatures()[0]
        self.assertEqual(signed[signed.index("-s") + 1], "-")
        with (self.app / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        self.assertNotIn("CMDevBuildCommit", info)
        self.assertNotIn("CMDevBuildDate", info)
        self.assertEqual(info["CFBundleShortVersionString"], "1.2.3")

    def test_selected_identity_uses_narrow_requirement_and_preserves_dev_mode(self):
        result = self.invoke(CM_DEV_SIGNING_IDENTITY=IDENTITY)
        self.assertEqual(result.returncode, 0, result.stderr)
        signed, verified = self.signatures()
        self.assertEqual(signed[signed.index("--sign") + 1], IDENTITY)
        self.assertEqual(signed[signed.index("--requirements") + 1],
                         '=designated => identifier "com.woojin.CursorMeter" '
                         f'and certificate leaf = H"{IDENTITY}"')
        self.assertIn("--timestamp=none", signed)
        self.assertIn("--entitlements", signed)
        self.assertEqual(signed[-1], str(self.app))
        self.assertEqual(verified[-1], str(self.app))
        self.assertIn("--strict", verified)
        with (self.app / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        self.assertEqual(info["CFBundleIdentifier"], "com.woojin.CursorMeter")
        self.assertIn("CMDevBuildCommit", info)

    def test_invalid_explicit_identity_preserves_output_before_build(self):
        for identity in ("", "-", "Apple Development: Name", "0" * 39, "G" * 40,
                         IDENTITY + "\n", " " + IDENTITY):
            with self.subTest(identity=identity):
                result = self.invoke(CM_DEV_SIGNING_IDENTITY=identity)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.sentinel.read_text(), "preserved")
                self.assertEqual(self.calls(), [])

    def test_release_override_rejected_before_build(self):
        for identity in (IDENTITY, ""):
            with self.subTest(identity=identity):
                result = self.invoke(BUILD_CHANNEL="release", CM_DEV_SIGNING_IDENTITY=identity)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.sentinel.read_text(), "preserved")
                self.assertEqual(self.calls(), [])

    def test_sign_failure_propagates_without_adhoc_fallback(self):
        result = self.invoke(CM_DEV_SIGNING_IDENTITY=IDENTITY, TEST_SIGN_STATUS="17")
        self.assertEqual(result.returncode, 17)
        self.assertEqual(len(self.signatures()), 1)
        self.assertEqual(self.signatures()[0][self.signatures()[0].index("--sign") + 1], IDENTITY)
        self.assertNotIn("Done!", result.stdout)

    def test_verify_failure_propagates_without_retry(self):
        result = self.invoke(CM_DEV_SIGNING_IDENTITY=IDENTITY, TEST_VERIFY_STATUS="23")
        self.assertEqual(result.returncode, 23)
        self.assertEqual(len(self.signatures()), 2)
        self.assertNotIn("Done!", result.stdout)

    def test_capture_packaging_failure_never_stops_or_replaces_app(self):
        scripts = self.root / "Scripts"
        scripts.mkdir()
        shutil.copy2(SCRIPTS / "capture-settings.sh", scripts)
        (scripts / "package_app.sh").write_text("#!/bin/bash\nexit 47\n")
        for tool in ("pkill", "rm", "cp", "open", "osascript", "sleep"):
            self.mock(tool)
        result = subprocess.run(["/bin/bash", str(scripts / "capture-settings.sh"),
                                 str(self.root / "captures")], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 47, result.stderr)
        self.assertFalse(any(call[0] != "git" for call in self.calls()), self.calls())
        self.assertEqual(self.sentinel.read_text(), "preserved")


if __name__ == "__main__":
    unittest.main()
