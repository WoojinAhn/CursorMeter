# Release artifact verification

The release gate runs the executable inside the signed distribution ZIP before
creating a GitHub Release. Unit tests alone did not catch the v0.13.0 startup
crash (#140); this gate adds process-level startup and refresh coverage (#142).

## Pipeline

`test.yml` runs on pull requests and main pushes, and is also called by
`release.yml` for version tags:

1. Native macOS 15 ARM and Intel jobs run the debug suite, optimized refresh
   regressions, and Python gate/installer tests. Xcode 16.4 is selected explicitly
   to preserve the existing release compiler instead of following a moving default.
2. Each job packages its architecture once using `package_app.sh`, with
   `BUILD_CHANNEL=release`. It records the ZIP and executable hashes, source
   commit/ref, version, Swift/Xcode/SDK versions, compiler command/target,
   developer directory, runner image, and macOS build.
3. Four jobs download those same archives and execute them natively on macOS 15
   and 26, on both ARM and Intel. No compilation or re-signing occurs here.
4. The final verification job checks both archive checksums against all four
   runtime receipts, their source build records, and the expected version/commit.
   It creates the `verified-release` Actions artifact only after all checks pass.
5. For a version tag, `release.yml` downloads that artifact, rechecks it, and
   publishes its ZIPs, checksums, build records, and smoke receipts. It does not
   rebuild. Any failed prerequisite skips publication.

Pull requests use version `0.0.0-ci` and run the same packaging and verification
path without creating a release. Actions evidence is retained for 14 days;
published releases retain the JSON records with their assets.

## What the app executes

An explicit `--release-smoke-test` launch option selects fixed dependencies in
the production executable. The shared `NSApplication`, application delegate,
menu bar setup, existing-session startup, and refresh implementation still run.
The option is absent during normal use.

The fixture environment intercepts HTTP requests, supplies synthetic credentials,
and uses isolated preferences and usage storage. It does not read the real
Keychain or Cursor database, deliver notifications, watch Cursor activity, or
contact the update service. It never installs or replaces the user's app.

The `startup` and `bonus` scenarios each require two completed refreshes and cost
collections. They assert request execution, successful authentication, current
usage, complete event coverage, family attribution, and today's percentages.
The bonus scenario also verifies the capped-included reconciliation from #141.
The completion receipt is written after the verifier task and app run loop return.

The external Python supervisor requires both exit code zero and a valid receipt
matching its fresh run ID and scenario. A live process, an early success log, or
a stale receipt cannot pass. `stall-refresh` and `crash-refresh` intentionally
stall or abort only the explicitly launched fixture process; every runtime job
also confirms that these controls are rejected as timeout and SIGABRT.

## Local verification

Run the gate against a release-style archive prepared from the desired commit:

```bash
python3 Scripts/test_release_app.py CursorMeter-0.0.0-ci.zip \
  --expected-arch arm64 --expected-version 0.0.0-ci \
  --report smoke-local.json --timeout 60 \
  --negative-controls --negative-timeout 5
```

Use `x86_64` and its matching archive on an Intel Mac. The gate refuses an
architecture mismatch, invalid signature, or development-build marker. The
report includes process output for failures, archive/executable hashes, runtime
provenance, successful scenario receipts, and negative-control evidence.

## Coverage limits

This is deterministic artifact verification, not a claim that the original
Swift compiler defect has been identified or reproduced by these fixtures.
It does not verify real-account authentication, every server response, visual
layout, or all supported macOS versions. The runtime matrix currently covers
macOS 15 and 26; macOS 14 remains the deployment target.

Ad-hoc signatures and checksums detect inconsistent artifacts; publisher
authenticity still requires the separate Developer ID/notarization work (#31).
