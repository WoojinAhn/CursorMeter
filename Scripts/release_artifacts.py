"""Record release build provenance and bind publication to native smoke receipts."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def binary_digest(archive):
    with zipfile.ZipFile(archive) as bundle:
        return hashlib.sha256(bundle.read("CursorMeter.app/Contents/MacOS/CursorMeter")).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def exact_int(value, expected):
    return type(value) is int and value == expected


def exact_number(value, expected):
    return type(value) in (int, float) and value == expected


def read_json(root, name):
    return json.loads((root / name).read_text())


def verify_publication(root, version, commit, ref=None):
    ref = ref or f"refs/tags/v{version}"
    verified = []
    for arch, suffix in (("arm64", ""), ("x86_64", "-x86_64")):
        name = f"CursorMeter-{version}{suffix}.zip"
        archive = root / name
        archive_hash = digest(archive)
        require((root / f"{name}.sha256").read_text().split() == [archive_hash, name],
                f"Checksum mismatch: {name}")
        executable_hash = binary_digest(archive)
        build = read_json(root, f"build-{arch}.json")
        require(exact_int(build["schema"], 1) and build["commit"] == commit and build["ref"] == ref
                and build["version"] == version and build["architecture"] == arch
                and build["archive"] == {"name": name, "sha256": archive_hash}
                and build["executableSHA256"] == executable_hash,
                f"Build provenance mismatch: {name}")
        configuration = build["build"]
        require(configuration["configuration"] == "release" and configuration["channel"] == "release"
                and configuration["target"] == f"{arch}-apple-macosx14.0"
                and all(configuration.get(key) for key in ("xcode", "swift", "sdk")),
                f"Missing release toolchain provenance: {name}")
        for major in (15, 26):
            runner = f"macos-{major}" + ("-intel" if arch == "x86_64" else "")
            report = read_json(root, f"smoke-{runner}.json")
            require(exact_int(report["schema"], 1) and report["status"] == "passed" and report["errors"] == []
                    and report["architecture"] == report["hostArchitecture"] == arch
                    and report["version"] == version and report["osVersion"].split(".")[0] == str(major),
                    f"Wrong or failed native runtime: {runner}")
            receipt = report["archive"]
            require(receipt["name"] == name and receipt["sha256"] == receipt["sha256After"] == archive_hash
                    and receipt["unchanged"] is True, f"Smoke tested a different ZIP: {runner}")
            executable = report["executable"]
            require(executable["sha256"] == executable["sha256After"] == executable_hash
                    and executable["unchanged"] is True and executable["signatureVerified"] is True,
                    f"Smoke tested a different executable: {runner}")
            scenarios = report["scenarios"]
            require(len(scenarios) == 2 and {s["scenario"] for s in scenarios} == {"startup", "bonus"},
                    f"Missing refresh scenarios: {runner}")
            run_ids = [s["runID"] for s in scenarios]
            for scenario in scenarios:
                completion = scenario["completion"]
                require(scenario["status"] == "passed" and exact_int(scenario["exitCode"], 0)
                        and scenario["timedOut"] is False and exact_int(completion["schema"], 1)
                        and completion["status"] == "passed" and completion["runID"] == scenario["runID"]
                        and completion["scenario"] == scenario["scenario"]
                        and exact_int(completion["completedRefreshes"], 2)
                        and exact_int(completion.get("completedCollections"), 2)
                        and exact_number(completion.get("todayCursorPercent"), 10)
                        and exact_number(completion.get("todayOtherPercent"), 20),
                        f"Refresh did not complete: {runner}/{scenario['scenario']}")
            controls = report["negativeControls"]
            require(len(controls) == 2 and {c["scenario"] for c in controls} == {"stall-refresh", "crash-refresh"},
                    f"Missing failure controls: {runner}")
            for control in controls:
                evidence = control["evidence"]
                run_ids.append(evidence["runID"])
                require(control["status"] == "passed" and evidence["status"] == "failed"
                        and evidence["scenario"] == control["scenario"],
                        f"Failure control passed unexpectedly: {runner}")
                if control["scenario"] == "stall-refresh":
                    require(control["expectedRejection"] == "timeout" and evidence["failureReason"] == "timeout"
                            and evidence["timedOut"] is True, f"Timeout not detected: {runner}")
                else:
                    require(control["expectedRejection"] == "SIGABRT" and evidence["failureReason"] == "process-exit"
                            and exact_int(evidence["exitCode"], -6) and evidence["timedOut"] is False,
                            f"Crash not detected: {runner}")
            require(all(isinstance(value, str) and value for value in run_ids) and len(set(run_ids)) == 4,
                    f"Missing or reused run ID: {runner}")
        verified.append({"name": name, "sha256": archive_hash})
    return verified


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def record_build(args):
    target = f"{args.arch}-apple-macosx14.0"
    manifest = {
        "schema": 1, "commit": command("git", "rev-parse", "HEAD"),
        "ref": os.environ["GITHUB_REF"], "version": args.version, "architecture": args.arch,
        "archive": {"name": args.archive.name, "sha256": digest(args.archive)},
        "executableSHA256": binary_digest(args.archive),
        "build": {"configuration": "release", "channel": "release", "target": target,
                  "command": ["swift", "build", "-c", "release", "--triple", target],
                  "xcode": command("xcodebuild", "-version"), "swift": command("swift", "--version"),
                  "sdk": command("xcrun", "--show-sdk-version"), "sdkPath": command("xcrun", "--show-sdk-path"),
                  "developerDir": os.environ.get("DEVELOPER_DIR"),
                  "imageOS": os.environ.get("ImageOS"), "imageVersion": os.environ.get("ImageVersion"),
                  "osVersion": command("sw_vers", "-productVersion"), "osBuild": command("sw_vers", "-buildVersion"),
                  "hostArchitecture": command("uname", "-m")},
    }
    require(manifest["commit"] == os.environ["GITHUB_SHA"], "Build does not match workflow commit")
    args.output.write_text(json.dumps(manifest, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    record = sub.add_parser("record-build")
    record.add_argument("archive", type=Path)
    record.add_argument("--arch", required=True, choices=("arm64", "x86_64"))
    record.add_argument("--version", required=True)
    record.add_argument("--output", type=Path, required=True)
    verify = sub.add_parser("verify-publication")
    verify.add_argument("directory", type=Path)
    verify.add_argument("--version", required=True)
    verify.add_argument("--commit", required=True)
    verify.add_argument("--ref", required=True)
    args = parser.parse_args()
    if args.command == "record-build":
        record_build(args)
    else:
        print(json.dumps(verify_publication(args.directory, args.version, args.commit, args.ref), indent=2))


if __name__ == "__main__":
    main()
