#!/usr/bin/env python3
"""Verify and exercise the signed app extracted from the release ZIP itself."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile


APP_NAME = "CursorMeter.app"
MAX_DIAGNOSTIC_BYTES = 16_384
MAX_RESULT_BYTES = 65_536


class GateError(Exception):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def extract_archive(archive_path, destination):
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
        if not entries:
            raise GateError("Release archive is empty")
        seen = set()
        for entry in entries:
            name = entry.orig_filename
            path = PurePosixPath(name)
            mode = entry.external_attr >> 16
            if (not name or "\x00" in name or "\\" in name or path.is_absolute()
                    or ".." in path.parts or not path.parts
                    or path.parts[0] != APP_NAME
                    or str(path) != name.rstrip("/")):
                raise GateError(f"Unexpected archive path: {name!r}")
            if stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise GateError(f"Non-regular archive member: {name!r}")
            if stat.S_ISDIR(mode) and not entry.is_dir():
                raise GateError(f"Invalid archive directory: {name!r}")
            key = str(path).casefold()
            if key in seen:
                raise GateError(f"Duplicate archive path: {name!r}")
            seen.add(key)
    destination.mkdir()
    # Preserve the macOS metadata covered by the bundle's code signature.
    checked_command(["/usr/bin/ditto", "-x", "-k", str(archive_path), str(destination)])
    return destination / APP_NAME


def checked_command(command):
    result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                            text=True, timeout=30)
    if result.returncode:
        detail = (result.stdout + result.stderr)[-MAX_DIAGNOSTIC_BYTES:]
        raise GateError(f"{Path(command[0]).name} exited {result.returncode}: {detail}")
    return result.stdout.strip()


def native_architecture():
    if platform.system() != "Darwin":
        raise GateError("The release artifact must be tested on macOS")
    architecture = platform.machine()
    if architecture == "x86_64":
        translated = subprocess.run(
            ["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"],
            capture_output=True, text=True, timeout=5
        )
        if translated.returncode == 0 and translated.stdout.strip() == "1":
            architecture = "arm64"
        # With -i, an unavailable translation OID on Intel succeeds with no output.
        elif translated.returncode != 0 or translated.stdout.strip() not in ("", "0"):
            raise GateError("Could not determine native host architecture")
    if architecture not in ("arm64", "x86_64"):
        raise GateError(f"Unsupported host architecture: {architecture}")
    return architecture


def inspect_bundle(bundle, expected_arch, expected_version):
    host_arch = native_architecture()
    if host_arch != expected_arch:
        raise GateError(f"Expected native {expected_arch} runner, got {host_arch}")
    with (bundle / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if (not isinstance(info, dict) or info.get("CFBundleExecutable") != "CursorMeter"
            or info.get("CFBundleIdentifier") != "com.woojin.CursorMeter"):
        raise GateError("Unexpected app identity or executable in Info.plist")
    if (info.get("CFBundleShortVersionString") != expected_version
            or info.get("CFBundleVersion") != expected_version):
        raise GateError(f"Expected bundle version {expected_version}")
    if "CMDevBuildCommit" in info:
        raise GateError("Release gate received a development bundle")
    executable = bundle / "Contents/MacOS/CursorMeter"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise GateError("Bundle executable is missing or is not executable")
    checked_command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)])
    architectures = checked_command(["/usr/bin/lipo", "-archs", str(executable)]).split()
    if architectures != [expected_arch]:
        raise GateError(f"Expected {expected_arch} executable, got {architectures}")
    return executable, {
        "version": expected_version,
        "architecture": expected_arch,
        "hostArchitecture": host_arch,
        "signatureVerified": True,
        "sha256": sha256(executable),
    }


def log_tail(path):
    with path.open("rb") as source:
        source.seek(0, os.SEEK_END)
        size = source.tell()
        source.seek(max(0, size - MAX_DIAGNOSTIC_BYTES))
        return source.read().decode("utf-8", errors="replace")


def unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def validate_completion(path, scenario, run_id):
    if (path.is_symlink() or not path.is_file()
            or path.stat().st_size > MAX_RESULT_BYTES):
        raise GateError("Completion must be a regular JSON file of at most 64 KiB")
    result = json.loads(path.read_text(), object_pairs_hook=unique_json_object)
    if (not isinstance(result, dict)
            or type(result.get("schema")) is not int or result["schema"] != 1
            or result.get("runID") != run_id or result.get("scenario") != scenario
            or result.get("status") != "passed"
            or type(result.get("completedRefreshes")) is not int
            or result["completedRefreshes"] != 2
            or type(result.get("completedCollections")) is not int
            or result["completedCollections"] != 2):
        raise GateError("Completion has wrong schema, nonce, scenario, status, or refresh/collection count")
    for field, expected in (("todayCursorPercent", 10), ("todayOtherPercent", 20)):
        value = result.get(field)
        if not (type(value) in (int, float) and value == expected and math.isfinite(value)):
            raise GateError(f"Completion has wrong {field}")
    return result


def run_scenario(executable, scenario, timeout):
    run_id = str(uuid.uuid4())
    evidence = {
        "scenario": scenario, "runID": run_id, "timeoutSeconds": timeout,
        "status": "failed", "exitCode": None, "timedOut": False,
    }
    with tempfile.TemporaryDirectory(prefix=f"cursormeter-{scenario}-") as directory:
        root = Path(directory).resolve()
        home, temp = root / "home", root / "tmp"
        home.mkdir()
        temp.mkdir()
        result_path = root / "completion.json"
        stdout_path, stderr_path = root / "stdout.log", root / "stderr.log"
        environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(home), "CFFIXED_USER_HOME": str(home),
            "TMPDIR": str(temp), "NSUnbufferedIO": "YES",
            "LANG": "en_US.UTF-8",
        }
        started = time.monotonic()
        try:
            with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
                child = subprocess.Popen(
                    [str(executable), "--release-smoke-test", scenario, str(result_path), run_id],
                    cwd=root, env=environment, stdin=subprocess.DEVNULL,
                    stdout=stdout, stderr=stderr, start_new_session=True,
                )
                try:
                    evidence["exitCode"] = child.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    evidence["timedOut"] = True
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    evidence["exitCode"] = child.wait(timeout=5)
        except (OSError, subprocess.SubprocessError) as error:
            evidence["failureReason"] = "launch-error"
            evidence["error"] = str(error)
        evidence["elapsedSeconds"] = round(time.monotonic() - started, 3)
        evidence["stdout"] = log_tail(stdout_path)
        evidence["stderr"] = log_tail(stderr_path)
        if "failureReason" in evidence:
            return evidence
        if evidence["timedOut"]:
            evidence["failureReason"] = "timeout"
        elif evidence["exitCode"] != 0:
            evidence["failureReason"] = "process-exit"
        elif not result_path.exists() and not result_path.is_symlink():
            evidence["failureReason"] = "missing-result"
        else:
            try:
                evidence["completion"] = validate_completion(result_path, scenario, run_id)
                evidence["status"] = "passed"
            except (GateError, ValueError, OSError) as error:
                evidence["failureReason"] = "invalid-result"
                evidence["error"] = str(error)
    return evidence


def negative_control_passed(scenario, evidence):
    if scenario == "stall-refresh":
        return evidence.get("failureReason") == "timeout"
    if scenario == "crash-refresh":
        return (evidence.get("failureReason") == "process-exit"
                and evidence.get("exitCode") == -signal.SIGABRT)
    return False


def verify_archive(archive, expected_arch, expected_version, timeout, negative_controls=False,
                   negative_timeout=5):
    report = {
        "schema": 1, "status": "failed",
        "archive": {"name": archive.name}, "scenarios": [], "negativeControls": [],
        "osVersion": platform.mac_ver()[0], "imageOS": os.environ.get("ImageOS"),
        "imageVersion": os.environ.get("ImageVersion"), "errors": [],
    }
    try:
        report["osBuild"] = checked_command(["/usr/bin/sw_vers", "--buildVersion"])
        report["archive"]["sha256"] = sha256(archive)
        with tempfile.TemporaryDirectory(prefix="cursormeter-release-") as directory:
            bundle = extract_archive(archive, Path(directory) / "extracted")
            executable, report["executable"] = inspect_bundle(
                bundle, expected_arch, expected_version
            )
            for field in ("version", "architecture", "hostArchitecture"):
                report[field] = report["executable"].pop(field)
            scenarios = ["startup", "bonus"]
            if negative_controls:
                scenarios += ["stall-refresh", "crash-refresh"]
            for scenario in scenarios:
                negative = scenario in ("stall-refresh", "crash-refresh")
                evidence = run_scenario(executable, scenario, negative_timeout if negative else timeout)
                if negative:
                    passed = negative_control_passed(scenario, evidence)
                    report["negativeControls"].append({
                        "scenario": scenario, "status": "passed" if passed else "failed",
                        "expectedRejection": "timeout" if scenario == "stall-refresh" else "SIGABRT",
                        "evidence": evidence,
                    })
                else:
                    passed = evidence["status"] == "passed"
                    report["scenarios"].append(evidence)
                if not passed:
                    report["errors"].append(f"Scenario {scenario} did not satisfy the gate")
            report["executable"]["sha256After"] = sha256(executable)
            report["executable"]["unchanged"] = (
                report["executable"]["sha256"] == report["executable"]["sha256After"]
            )
            if not report["executable"]["unchanged"]:
                report["errors"].append("Executable changed during verification")
    except (GateError, OSError, ValueError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        report["errors"].append(str(error))
    finally:
        try:
            report["archive"]["sha256After"] = sha256(archive)
            report["archive"]["unchanged"] = (
                report["archive"].get("sha256") == report["archive"]["sha256After"]
            )
            if not report["archive"]["unchanged"]:
                report["errors"].append("Archive changed during verification")
        except OSError as error:
            report["errors"].append(str(error))
    if not report["errors"]:
        report["status"] = "passed"
    return report


def positive_seconds(value):
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("Deadline must be a finite positive number")
    return seconds


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="Exact release ZIP to verify")
    parser.add_argument("--expected-arch", choices=("arm64", "x86_64"), required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--report", type=Path, required=True, help="JSON verification report path")
    parser.add_argument("--timeout", type=positive_seconds, default=30)
    parser.add_argument("--negative-controls", action="store_true",
                        help="Also prove rejection of the app's stalled and crashing refreshes")
    parser.add_argument("--negative-timeout", type=positive_seconds, default=5)
    args = parser.parse_args()
    archive, report_path = args.archive.resolve(), args.report.resolve()
    if archive == report_path:
        parser.error("Report must not overwrite the release archive")
    report = verify_archive(archive, args.expected_arch, args.expected_version, args.timeout,
                            args.negative_controls, args.negative_timeout)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{report['status'].upper()}: {archive.name}; report: {report_path}")
    for error in report["errors"]:
        print(error, file=sys.stderr)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
