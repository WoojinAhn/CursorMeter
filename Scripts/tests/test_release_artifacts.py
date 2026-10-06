"""Prevent publication of different, incomplete, or unverified release artifacts."""

import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_artifacts import verify_publication


class ReleaseArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.commit = "a" * 40
        self.version = "1.2.3"
        for arch, suffix in (("arm64", ""), ("x86_64", "-x86_64")):
            name = f"CursorMeter-{self.version}{suffix}.zip"
            archive = self.root / name
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("CursorMeter.app/Contents/MacOS/CursorMeter", arch.encode())
            executable_hash = hashlib.sha256(arch.encode()).hexdigest()
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            (self.root / (name + ".sha256")).write_text(f"{digest}  {name}\n")
            self.write(f"build-{arch}.json", {
                "schema": 1, "commit": self.commit, "ref": "refs/tags/v1.2.3",
                "version": self.version, "architecture": arch,
                "archive": {"name": name, "sha256": digest},
                "executableSHA256": executable_hash,
                "build": {"configuration": "release", "channel": "release",
                          "target": f"{arch}-apple-macosx14.0", "xcode": "Xcode 16.4",
                          "swift": "Apple Swift 6.1.2", "sdk": "15.5"},
            })
            for os in (15, 26):
                runner = f"macos-{os}" + ("-intel" if arch == "x86_64" else "")
                scenarios = []
                for scenario in ("startup", "bonus"):
                    run_id = f"{runner}-{scenario}"
                    scenarios.append({
                        "scenario": scenario, "runID": run_id, "status": "passed",
                        "exitCode": 0, "timedOut": False,
                        "completion": {"schema": 1, "runID": run_id, "scenario": scenario,
                                       "status": "passed", "completedRefreshes": 2,
                                       "completedCollections": 2, "todayCursorPercent": 10,
                                       "todayOtherPercent": 20},
                    })
                self.write(f"smoke-{runner}.json", {
                    "schema": 1, "status": "passed", "version": self.version,
                    "architecture": arch, "hostArchitecture": arch, "osVersion": f"{os}.0",
                    "archive": {"name": name, "sha256": digest,
                                "sha256After": digest, "unchanged": True},
                    "executable": {"sha256": executable_hash, "sha256After": executable_hash,
                                   "unchanged": True, "signatureVerified": True},
                    "scenarios": scenarios,
                    "negativeControls": [
                        {"scenario": "stall-refresh", "status": "passed", "expectedRejection": "timeout",
                         "evidence": {"status": "failed", "failureReason": "timeout", "timedOut": True,
                                      "scenario": "stall-refresh", "runID": f"{runner}-stall"}},
                        {"scenario": "crash-refresh", "status": "passed", "expectedRejection": "SIGABRT",
                         "evidence": {"status": "failed", "failureReason": "process-exit", "exitCode": -6,
                                      "timedOut": False, "scenario": "crash-refresh", "runID": f"{runner}-crash"}},
                    ], "errors": [],
                })

    def write(self, name, payload):
        (self.root / name).write_text(json.dumps(payload))

    def check(self):
        return verify_publication(self.root, self.version, self.commit)

    def test_accepts_exact_archives_with_all_four_native_results(self):
        self.assertEqual(len(self.check()), 2)

    def test_rejects_changed_archive(self):
        (self.root / "CursorMeter-1.2.3.zip").write_bytes(b"rebuilt after smoke")
        with self.assertRaises(ValueError):
            self.check()

    def test_requires_each_runtime_receipt(self):
        (self.root / "smoke-macos-26-intel.json").unlink()
        with self.assertRaises((ValueError, FileNotFoundError)):
            self.check()

    def test_rejects_invalid_evidence_even_if_top_level_passed(self):
        name = "smoke-macos-26.json"
        original = json.loads((self.root / name).read_text())
        mutations = [
            lambda r: r.update(hostArchitecture="x86_64"),
            lambda r: r.update(osVersion="15.0"),
            lambda r: r["archive"].update(sha256="c" * 64),
            lambda r: r["executable"].update(sha256After="c" * 64),
            lambda r: r["scenarios"][1].update(exitCode=-6),
            lambda r: r["scenarios"][1].update(exitCode=False),
            lambda r: r["scenarios"][1]["completion"].update(completedRefreshes=1),
            lambda r: r["scenarios"][1]["completion"].update(completedRefreshes=3),
            lambda r: r["scenarios"][1]["completion"].update(schema=True),
            lambda r: r["scenarios"][1]["completion"].pop("completedCollections"),
            lambda r: r["scenarios"][1]["completion"].update(completedCollections=0),
            lambda r: r["scenarios"][1]["completion"].update(todayCursorPercent=0),
            lambda r: r["scenarios"][1]["completion"].pop("todayOtherPercent"),
            lambda r: r["scenarios"][1]["completion"].update(runID="stale"),
            lambda r: r["negativeControls"][0]["evidence"].update(timedOut=False),
            lambda r: r["negativeControls"][1]["evidence"].update(exitCode=0),
            lambda r: r["negativeControls"][1]["evidence"].update(timedOut=True),
            lambda r: r["negativeControls"][0]["evidence"].update(scenario="startup"),
            lambda r: r["negativeControls"][0]["evidence"].update(runID=r["scenarios"][0]["runID"]),
            lambda r: r.update(errors=["unexpected request"]),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(original)
                mutation(changed)
                self.write(name, changed)
                with self.assertRaises(ValueError):
                    self.check()

    def test_rejects_other_commit_or_dev_build(self):
        name = "build-arm64.json"
        original = json.loads((self.root / name).read_text())
        for field, value in (("commit", "d" * 40), ("ref", "refs/tags/v1.2.2")):
            changed = copy.deepcopy(original)
            changed[field] = value
            self.write(name, changed)
            with self.assertRaises(ValueError):
                self.check()
        changed = copy.deepcopy(original)
        changed["build"]["channel"] = "dev"
        self.write(name, changed)
        with self.assertRaises(ValueError):
            self.check()


if __name__ == "__main__":
    unittest.main()
