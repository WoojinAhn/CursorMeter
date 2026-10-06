"""Exercise the artifact gate with real child failures and synthetic archives."""

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import stat
import sys
import tempfile
import time
import unittest
from unittest import mock
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "test_release_app.py"
SPEC = importlib.util.spec_from_file_location("release_app_gate", SCRIPT)
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class ScenarioTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cursormeter-gate-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.executable = self.root / "fake-app"

    def run_app(self, body, timeout=2):
        self.executable.write_text(
            f"#!{sys.executable}\n"
            "import json, os, signal, sys, time\n"
            "from pathlib import Path\n"
            "assert sys.argv[1] == '--release-smoke-test'\n"
            "scenario, destination, run_id = sys.argv[2:]\n"
            "result = dict(schema=1, runID=run_id, scenario=scenario, "
            "status='passed', completedRefreshes=2, completedCollections=2, "
            "todayCursorPercent=10, todayOtherPercent=20)\n" + body
        )
        self.executable.chmod(0o755)
        return gate.run_scenario(self.executable, "startup", timeout)

    def assert_failure(self, evidence, reason):
        self.assertEqual(evidence["status"], "failed", evidence)
        self.assertEqual(evidence["failureReason"], reason, evidence)

    def test_completed_refresh_and_clean_exit_pass(self):
        evidence = self.run_app("Path(destination).write_text(json.dumps(result))\n")
        self.assertEqual(evidence["status"], "passed", evidence)
        self.assertEqual(evidence["exitCode"], 0)
        self.assertEqual(evidence["completion"]["runID"], evidence["runID"])

    def test_success_log_without_result_fails(self):
        evidence = self.run_app("print('refresh passed', flush=True)\n")
        self.assert_failure(evidence, "missing-result")
        self.assertIn("refresh passed", evidence["stdout"])

    def test_live_process_with_success_result_times_out(self):
        started = time.monotonic()
        evidence = self.run_app(
            "Path(destination).write_text(json.dumps(result))\n"
            "print('still running', flush=True)\n"
            "time.sleep(30)\n", timeout=2
        )
        self.assert_failure(evidence, "timeout")
        self.assertTrue(evidence["timedOut"])
        self.assertLess(time.monotonic() - started, 5)
        self.assertIn("still running", evidence["stdout"])

    def test_abort_after_success_result_fails(self):
        evidence = self.run_app(
            "Path(destination).write_text(json.dumps(result))\n"
            "print('intentional abort', file=sys.stderr, flush=True)\n"
            "os.kill(os.getpid(), signal.SIGABRT)\n"
        )
        self.assert_failure(evidence, "process-exit")
        self.assertEqual(evidence["exitCode"], -signal.SIGABRT)
        self.assertIn("intentional abort", evidence["stderr"])

    def test_nonzero_exit_after_success_result_fails(self):
        evidence = self.run_app(
            "Path(destination).write_text(json.dumps(result))\n"
            "sys.exit(17)\n"
        )
        self.assert_failure(evidence, "process-exit")
        self.assertEqual(evidence["exitCode"], 17)

    def test_invalid_completion_is_rejected(self):
        cases = {
            "stale nonce": "result['runID'] = 'old-run'",
            "wrong scenario": "result['scenario'] = 'bonus'",
            "wrong schema": "result['schema'] = 2",
            "boolean schema": "result['schema'] = True",
            "failed status": "result['status'] = 'failed'",
            "missing field": "del result['completedRefreshes']",
            "no refresh": "result['completedRefreshes'] = 0",
            "partial refresh": "result['completedRefreshes'] = 1",
            "wrong count": "result['completedRefreshes'] = 3",
            "string count": "result['completedRefreshes'] = '2'",
            "float count": "result['completedRefreshes'] = 2.0",
            "boolean count": "result['completedRefreshes'] = True",
            "missing collection count": "del result['completedCollections']",
            "incomplete collections": "result['completedCollections'] = 1",
            "extra collections": "result['completedCollections'] = 3",
            "float collection count": "result['completedCollections'] = 2.0",
            "string collection count": "result['completedCollections'] = '2'",
            "boolean collection count": "result['completedCollections'] = True",
            "missing cursor percent": "del result['todayCursorPercent']",
            "missing other percent": "del result['todayOtherPercent']",
            "wrong cursor percent": "result['todayCursorPercent'] = 0",
            "wrong other percent": "result['todayOtherPercent'] = 10",
            "string cursor percent": "result['todayCursorPercent'] = '10'",
            "boolean other percent": "result['todayOtherPercent'] = True",
            "nan cursor percent": "result['todayCursorPercent'] = float('nan')",
            "infinite other percent": "result['todayOtherPercent'] = float('inf')",
            "array": "result = []",
        }
        for label, mutation in cases.items():
            with self.subTest(label=label):
                self.assert_failure(self.run_app(
                    mutation + "\nPath(destination).write_text(json.dumps(result))\n"
                ), "invalid-result")

    def test_finite_float_percentages_are_accepted(self):
        evidence = self.run_app(
            "result.update(todayCursorPercent=10.0, todayOtherPercent=20.0)\n"
            "Path(destination).write_text(json.dumps(result))\n"
        )
        self.assertEqual(evidence["status"], "passed", evidence)

    def test_malformed_result_fails(self):
        self.assert_failure(self.run_app("Path(destination).write_text('{oops')\n"),
                            "invalid-result")

    def test_duplicate_json_keys_fail(self):
        self.assert_failure(self.run_app(
            "payload = json.dumps(result)[:-1] + ', \"status\": \"passed\"}'\n"
            "Path(destination).write_text(payload)\n"
        ), "invalid-result")

    def test_result_symlink_fails(self):
        self.assert_failure(self.run_app(
            "target = Path(destination).with_name('other.json')\n"
            "target.write_text(json.dumps(result))\n"
            "Path(destination).symlink_to(target)\n"
        ), "invalid-result")

    def test_environment_and_result_directory_are_isolated(self):
        with mock.patch.dict(os.environ, {"CURSOR_SESSION_TOKEN": "secret"}):
            evidence = self.run_app(
                "assert 'CURSOR_SESSION_TOKEN' not in os.environ\n"
                "assert Path(os.environ['HOME']).is_dir()\n"
                "assert os.environ['HOME'] == os.environ['CFFIXED_USER_HOME']\n"
                "assert Path(os.environ['TMPDIR']).is_dir()\n"
                "assert Path(destination).is_absolute()\n"
                "assert not Path(destination).exists()\n"
                "assert Path.cwd() == Path(destination).parent\n"
                "Path(destination).write_text(json.dumps(result))\n"
            )
        self.assertEqual(evidence["status"], "passed", evidence)

    def test_negative_control_must_fail_for_expected_reason(self):
        valid = self.run_app("Path(destination).write_text(json.dumps(result))\n")
        self.assertFalse(gate.negative_control_passed("stall-refresh", valid))
        self.assertFalse(gate.negative_control_passed("crash-refresh", valid))
        missing = self.run_app("pass\n")
        self.assertFalse(gate.negative_control_passed("stall-refresh", missing))
        self.assertFalse(gate.negative_control_passed("crash-refresh", missing))
        timed_out = self.run_app("time.sleep(30)\n", timeout=0.1)
        self.assertTrue(gate.negative_control_passed("stall-refresh", timed_out))
        aborted = self.run_app("os.kill(os.getpid(), signal.SIGABRT)\n")
        self.assertTrue(gate.negative_control_passed("crash-refresh", aborted))


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cursormeter-archive-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "release.zip"
        self.destination = self.root / "extract"

    def write_archive(self, entries):
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name, data, mode in entries:
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = mode << 16
                archive.writestr(entry, data)

    def test_extract_preserves_executable_bytes_and_mode(self):
        name = "CursorMeter.app/Contents/MacOS/CursorMeter"
        self.write_archive([(name, b"exact signed bytes", stat.S_IFREG | 0o755)])
        before = self.archive.read_bytes()
        bundle = gate.extract_archive(self.archive, self.destination)
        binary = bundle / "Contents/MacOS/CursorMeter"
        self.assertEqual(binary.read_bytes(), b"exact signed bytes")
        self.assertTrue(os.access(binary, os.X_OK))
        self.assertEqual(self.archive.read_bytes(), before)

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS signing and archive metadata")
    def test_signed_bundle_with_appledouble_metadata_survives_extraction(self):
        bundle = self.root / "CursorMeter.app"
        binary = bundle / "Contents/MacOS/CursorMeter"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(Path("/usr/bin/true").read_bytes())
        binary.chmod(0o755)
        info = dict(CFBundleExecutable="CursorMeter", CFBundlePackageType="APPL",
                    CFBundleIdentifier="com.example.CursorMeterExtractionTest",
                    CFBundleVersion="1.0", CFBundleShortVersionString="1.0")
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        resource = bundle / "Contents/Resources/fixture.txt"
        resource.parent.mkdir()
        resource.write_text("sealed resource")
        attribute = "com.cursormeter.extraction-test"
        gate.checked_command(["/usr/bin/xattr", "-w", attribute, "archive metadata", str(resource)])
        gate.checked_command(["/usr/bin/codesign", "-s", "-", "--force", str(bundle)])
        gate.checked_command(["/usr/bin/ditto", "-c", "-k", "--keepParent",
                              str(bundle), str(self.archive)])
        before = self.archive.read_bytes()
        with zipfile.ZipFile(self.archive) as archive:
            self.assertTrue(any("/._" in entry.filename for entry in archive.infolist()))
        extracted = gate.extract_archive(self.archive, self.destination)
        gate.checked_command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(extracted)])
        restored = gate.checked_command(["/usr/bin/xattr", "-p", attribute,
                                         str(extracted / "Contents/Resources/fixture.txt")])
        self.assertEqual(restored, "archive metadata")
        self.assertFalse(list(extracted.rglob("._*")))
        self.assertEqual(self.archive.read_bytes(), before)

    def test_unsafe_and_unexpected_paths_fail_before_extraction(self):
        for name in (
            "../escaped", "/tmp/escaped", "CursorMeter.app/../../escaped",
            "Other.app/Contents/file", "readme.txt", "CursorMeter.app//file",
            "CursorMeter.app/./file", "CursorMeter.app\\escaped",
        ):
            with self.subTest(name=name):
                self.write_archive([(name, b"bad", stat.S_IFREG | 0o644)])
                with self.assertRaises(gate.GateError):
                    gate.extract_archive(self.archive, self.destination)
                self.assertFalse(self.destination.exists())

    def test_symlink_member_is_rejected(self):
        self.write_archive([
            ("CursorMeter.app/Contents/MacOS/CursorMeter", b"/tmp/target",
             stat.S_IFLNK | 0o777)
        ])
        with self.assertRaises(gate.GateError):
            gate.extract_archive(self.archive, self.destination)

    def test_case_colliding_members_are_rejected(self):
        self.write_archive([
            ("CursorMeter.app/Contents/Info.plist", b"first", stat.S_IFREG | 0o644),
            ("CursorMeter.app/Contents/info.plist", b"second", stat.S_IFREG | 0o644),
        ])
        with self.assertRaises(gate.GateError):
            gate.extract_archive(self.archive, self.destination)

    def test_empty_archive_is_rejected(self):
        self.write_archive([])
        with self.assertRaises(gate.GateError):
            gate.extract_archive(self.archive, self.destination)

    def verify_with_fake_app(self, mutation=None, negative_success=False):
        self.write_archive([
            ("CursorMeter.app/Contents/MacOS/CursorMeter", b"signed executable",
             stat.S_IFREG | 0o755)
        ])

        def inspect(bundle, architecture, version):
            binary = bundle / "Contents/MacOS/CursorMeter"
            return binary, dict(version=version, architecture=architecture,
                                hostArchitecture=architecture, signatureVerified=True,
                                sha256=gate.sha256(binary))

        def run(binary, scenario, timeout):
            if mutation is not None and scenario == "startup":
                mutation(binary)
            if scenario == "stall-refresh" and not negative_success:
                return dict(status="failed", failureReason="timeout", exitCode=-9)
            if scenario == "crash-refresh" and not negative_success:
                return dict(status="failed", failureReason="process-exit", exitCode=-6)
            return dict(scenario=scenario, status="passed", exitCode=0,
                        completion=dict(completedRefreshes=2, completedCollections=2,
                                        todayCursorPercent=10, todayOtherPercent=20))

        with mock.patch.object(gate, "inspect_bundle", side_effect=inspect), \
                mock.patch.object(gate, "run_scenario", side_effect=run):
            return gate.verify_archive(self.archive, "arm64", "1.2.3", 10,
                                       negative_controls=True)

    def test_report_binds_success_and_negative_evidence_to_archive(self):
        report = self.verify_with_fake_app()
        self.assertEqual(report["status"], "passed", report)
        self.assertEqual(report["archive"]["sha256"], gate.sha256(self.archive))
        self.assertTrue(report["archive"]["unchanged"])
        self.assertTrue(report["executable"]["unchanged"])
        self.assertEqual(report["architecture"], "arm64")
        self.assertEqual(report["version"], "1.2.3")
        self.assertEqual(len(report["scenarios"]), 2)
        self.assertEqual([control["status"] for control in report["negativeControls"]],
                         ["passed", "passed"])
        self.assertTrue(all(control["evidence"]["status"] == "failed"
                            for control in report["negativeControls"]))

    def test_report_records_runtime_build_and_ci_image(self):
        run_command = gate.checked_command

        def command_output(command):
            if command == ["/usr/bin/sw_vers", "--buildVersion"]:
                return "24F74"
            return run_command(command)

        with mock.patch.dict(os.environ, {"ImageOS": "macos15", "ImageVersion": "20261001.1"}), \
                mock.patch.object(gate, "checked_command", side_effect=command_output) as command:
            report = self.verify_with_fake_app()
        self.assertEqual(report["status"], "passed", report)
        self.assertEqual(report["osBuild"], "24F74")
        self.assertEqual(report["imageOS"], "macos15")
        self.assertEqual(report["imageVersion"], "20261001.1")
        command.assert_any_call(["/usr/bin/sw_vers", "--buildVersion"])

    def test_archive_change_during_execution_rejects_release(self):
        def change_archive(binary):
            with self.archive.open("ab") as archive:
                archive.write(b"changed after inspection")

        report = self.verify_with_fake_app(mutation=change_archive)
        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["archive"]["unchanged"])
        self.assertIn("Archive changed during verification", report["errors"])

    def test_executable_change_during_execution_rejects_release(self):
        report = self.verify_with_fake_app(mutation=lambda binary: binary.write_bytes(b"changed"))
        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["executable"]["unchanged"])

    def test_negative_control_that_succeeds_rejects_release(self):
        report = self.verify_with_fake_app(negative_success=True)
        self.assertEqual(report["status"], "failed")
        self.assertTrue(all(control["status"] == "failed"
                            for control in report["negativeControls"]))


class NativeArchitectureTests(unittest.TestCase):
    def probe(self, stdout, returncode=0):
        with mock.patch.object(gate.platform, "system", return_value="Darwin"), \
                mock.patch.object(gate.platform, "machine", return_value="x86_64"), \
                mock.patch.object(gate.subprocess, "run", return_value=mock.Mock(
                    returncode=returncode, stdout=stdout, stderr=""
                )) as command:
            architecture = gate.native_architecture()
        command.assert_called_once_with(
            ["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"],
            capture_output=True, text=True, timeout=5
        )
        return architecture

    def test_intel_missing_translation_oid_is_native(self):
        self.assertEqual(self.probe(""), "x86_64")

    def test_explicit_native_result_is_intel(self):
        self.assertEqual(self.probe("0\n"), "x86_64")

    def test_rosetta_result_identifies_arm_host(self):
        self.assertEqual(self.probe("1\n"), "arm64")

    def test_failed_or_unexpected_probe_is_rejected(self):
        for returncode, stdout in ((1, ""), (2, ""), (0, "unknown")):
            with self.subTest(returncode=returncode, stdout=stdout):
                with self.assertRaisesRegex(gate.GateError, "native host"):
                    self.probe(stdout, returncode)


class BundleInspectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cursormeter-inspection-test-")
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name) / "CursorMeter.app"
        self.binary = self.bundle / "Contents/MacOS/CursorMeter"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b"signed bytes")
        self.binary.chmod(0o755)
        self.info = dict(CFBundleExecutable="CursorMeter",
                         CFBundleIdentifier="com.woojin.CursorMeter",
                         CFBundleVersion="1.2.3", CFBundleShortVersionString="1.2.3")

    def inspect(self, host="arm64", executable_arch="arm64", signature_valid=True):
        (self.bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

        def command(args):
            if args[0] == "/usr/bin/codesign":
                self.assertEqual(args[1:], ["--verify", "--deep", "--strict", str(self.bundle)])
                if not signature_valid:
                    raise gate.GateError("invalid code signature")
                return ""
            self.assertEqual(args, ["/usr/bin/lipo", "-archs", str(self.binary)])
            return executable_arch

        with mock.patch.object(gate, "native_architecture", return_value=host), \
                mock.patch.object(gate, "checked_command", side_effect=command):
            return gate.inspect_bundle(self.bundle, "arm64", "1.2.3")

    def test_verified_bundle_identity_version_signature_and_architecture(self):
        executable, evidence = self.inspect()
        self.assertEqual(executable, self.binary)
        self.assertEqual(evidence["sha256"], gate.sha256(self.binary))
        self.assertTrue(evidence["signatureVerified"])

    def test_wrong_host_architecture_is_rejected(self):
        with self.assertRaisesRegex(gate.GateError, "native"):
            self.inspect(host="x86_64")

    def test_wrong_executable_architecture_is_rejected(self):
        with self.assertRaisesRegex(gate.GateError, "executable"):
            self.inspect(executable_arch="x86_64")

    def test_invalid_signature_is_rejected(self):
        with self.assertRaisesRegex(gate.GateError, "signature"):
            self.inspect(signature_valid=False)

    def test_wrong_version_or_development_marker_is_rejected(self):
        for key, value in (("CFBundleVersion", "old"), ("CFBundleShortVersionString", "old"),
                           ("CMDevBuildCommit", "abc123")):
            with self.subTest(key=key), mock.patch.dict(self.info, {key: value}):
                with self.assertRaises(gate.GateError):
                    self.inspect()

    def test_unexpected_executable_path_is_rejected(self):
        self.info["CFBundleExecutable"] = "../../external"
        with self.assertRaises(gate.GateError):
            self.inspect()

    def test_wrong_bundle_identifier_is_rejected(self):
        self.info["CFBundleIdentifier"] = "com.example.OtherApp"
        with self.assertRaisesRegex(gate.GateError, "identity"):
            self.inspect()


if __name__ == "__main__":
    unittest.main()
