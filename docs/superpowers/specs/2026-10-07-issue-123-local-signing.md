# Local development signing (#123)

Status: reviewed; isolated continuity gate passed on macOS 26.6.2 arm64.

## Goal and boundaries

Allow an explicitly selected, reusable local signing identity without changing
CursorMeter authentication, credential storage, release signing, or app behavior.
Issue: https://github.com/WoojinAhn/CursorMeter/issues/123.

The outcome is **Keychain access after replacing a build**, not merely equal
designated requirements (DRs). macOS also applies partition authorization; a
self-signed identity may still receive a build-specific partition. Do not claim
that any signing setup removes prompts until a controlled experiment demonstrates it. If that experiment fails, record the result and resolve the
design before implementing or closing the issue. Do not weaken access controls
to force the experiment to pass.

The supported setup now uses an Apple-issued **Apple Development** identity from
Xcode, including a free Personal Team. The owner selected this route and issued a
certificate. Self-signed identity setup remains unproven and is not the documented
setup. The packaging interface still selects an exact certificate fingerprint;
it does not enroll accounts, generate identities, export keys, or change trust.

This improves opted-in local builds only. Published releases continue using their
existing ad-hoc signing, so their update-time Keychain prompts are not resolved by
this issue. General-user distribution signing belongs to #31.

Public Developer ID distribution/notarization (#31), automatic certificate
creation, real Cursor credentials, migration of existing Keychain ACLs, and live
app replacement are out of scope.

## Packaging contract

- `CM_DEV_SIGNING_IDENTITY` is opt-in and local. Its value must be exactly the
  40 hexadecimal digits of the selected certificate's SHA-1 fingerprint.
  Certificate names, an empty explicit value, and `-` are rejected.
- If unset, existing ad-hoc signing and dev metadata remain unchanged.
- If set with `BUILD_CHANNEL=release`, fail before building or altering output.
  The release workflow remains unchanged.
- Validate syntax before building or altering output. Signing or verification
  failures stop the command; never fall back to ad-hoc signing.
- Selected-identity signing uses the existing bundle ID and entitlements, no
  timestamp server (`--timestamp=none`), and an explicit DR requiring both
  `identifier "com.woojin.CursorMeter"` and the exact leaf certificate hash.
- Preserve strict post-sign verification. Identity/private-key availability is
  ultimately determined by signing, rather than by certificate-name matching or
  a trust-filtered `find-identity -v` precheck.
- No key, password, machine fingerprint, or local signing preference enters git.
- The screenshot caller must package successfully before stopping or replacing
  the installed app. This is the only caller behavior change.

## Keychain continuity experiment

Use two distinct test binaries with the same identifier/certificate and different
CDHashes, replacing the executable at the same path. Both must satisfy the same
DR. Use a synthetic secret in a disposable private file-based Keychain, never the
login Keychain. Capture the default Keychain and search list before and after;
assert no change. Use explicit Keychain scope for every operation and disable
user interaction within the probe process. Verify the displayed A/B/D requirement
is exactly the intended identifier and selected leaf, and evaluate each against its
own explicit requirement; verify C is ad-hoc. Do not opt into the Data Protection
Keychain. Verify the created item reference belongs to the disposable file
Keychain, and require requested/opened/item-owner paths to agree.

Mirror the app's `SecItemAdd` / `SecItemCopyMatching` generic-password shape and
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Only the service/account and
explicit private-Keychain scope differ for isolation. Create the item from build
A itself. Use `SecKeychainSetUserInteractionAllowed(false)` in every probe process;
do not rely only on Data Protection Keychain UI options for a file-based Keychain.

The creating build must read its synthetic item successfully. After replacement,
the second build must read it with interaction disabled. An ad-hoc-signed replacement must be denied. An additional binary signed with
the same certificate but a different identifier must also be denied. Check that
build B can update the synthetic value and build A can read the new value. Do not grant all-apps access, remove partition protection,
or edit the item ACL to accommodate a new binary. Clean up the private Keychain and temporary binaries. Never delete or export the
owner-issued signing identity; only disposable self-signed experiments have
ephemeral signing material. Report OS version, statuses, DR equality, and
negative controls without printing any secrets.

Keep these outcomes distinct: signing/identity setup incomplete, observation
inconclusive, measured same-signer denial, and successful continuity. A setup
failure is not an A/B Keychain result. An A/B denial leaves feature acceptance
unmet and requires a design decision before packaging implementation. Unexpected
statuses remain inconclusive. No existing login-Keychain permission may be changed
for this experiment. Do not authorize an unexpected measurement-time dialog.

A bare-binary probe success permits packaging implementation only; it does not
establish that the installed CursorMeter.app no longer prompts. A probe success
demonstrates that isolated setup only. Initial transition from
an existing ad-hoc app or a different signer can still require user authorization;
do not claim the experiment migrates existing production permissions.

## Tests and documentation

Hermetic packaging tests cover default dev/release, selected identity and DR,
invalid explicit inputs, release rejection, signing/verification failures,
paths containing spaces, and screenshot-caller failure before app replacement.
Existing Swift and installer tests must remain green. Perform two real local app
build/signature checks if a usable identity is available without broadening the
authorized Keychain setup.

Document setup, explicit selection, validation, returning to ad-hoc signing,
signer changes, and the limits demonstrated by the experiment. Keep English and
Korean documentation paired, with concise Build from Source links in the README
locales. Do not promise continuity on untested signing/trust configurations.

## Acceptance

- [x] Reusable-identity packaging is opt-in; defaults and releases are unchanged.
- [x] Explicit misconfiguration/signing failures cannot silently change signers.
- [x] Distinct builds satisfy the same narrow designated requirement.
- [x] Synthetic A/B reads and B update → A updated-value read succeed without UI.
- [x] C (ad-hoc) and D (same signer, different identifier) cannot read the item.
- [x] Item owner is the disposable file Keychain; search/default preferences and
  Keychain protections remain unchanged, and cleanup succeeds.
- [x] Tests, setup/verification/reset documentation, and review pass.

## Evidence

- [Apple requirement language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html)
- [Apple Keychain client partitions](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp)
- [Apple self-signed certificate setup](https://support.apple.com/guide/keychain-access/create-self-signed-certificates-kyca8916/mac)

## Apple Development amendment evidence

- Apple WWDR CPS v3.0 section 4.2 permits Apple Development certificates without
  paid Developer Program membership; this does not grant Developer ID distribution.
- The owner issued an Apple Development identity on 2026-10-07. Initial signing
  failed because its WWDR G3 issuer was missing from the local certificate chain.
  Supplying the official G3 certificate made offline code-signing chain validation
  succeed. Adding only that public intermediate (no trust overrides) made identity
  validation and a temporary binary's signing/strict verification pass.
- These are signing setup results, not yet an A/B credential-continuity result.
- Cursor review quota is unavailable. The owner identified their separate Grok
  rescue installation; subsequent external review uses that route, with Astra
  adjudication. Prior four-model review findings remain applicable.

References: [Apple certificate policy](https://images.apple.com/certificateauthority/pdf/Apple_WWDR_CPS_v3.0.pdf),
[Apple signing-chain diagnosis](https://developer.apple.com/forums/thread/712043).

## Amendment adjudication

Grok direct CLI reviewed the amendment and requested stronger scope/DR checks.
Astra and an independent native Codex reviewer accepted those checks and the
stronger acceptance wording. The suggestion to write the global search list was
rejected: prior measurements on this Mac show create/delete preserve it; forced
restoration can overwrite concurrent user changes and conceal invariant failures.
The probe remains fail-closed on preference changes, with explicit cleanup.
No success claim is based solely on the setup JSON or equal DR strings.

## Measured continuity result (2026-10-08)

The isolated probe passed on macOS 26.6.2 arm64 using the selected Apple Development
identity. A/B had different CDHashes and the exact same leaf-pinned requirement.
A and B read successfully; B updated the synthetic value and A/B read it back.
The ad-hoc and different-identifier controls both returned errSecAuthFailed
(-25293), with metadata present and item ownership verified in the private Keychain.
Authentication UI was disabled, search/default preferences stayed unchanged, and
the disposable Keychain was deleted successfully. This permits implementation of
the opt-in packaging route, subject to packaging tests and actual app signature
checks. It does not establish migration of an existing login-Keychain grant.

Packaging validation: eight hermetic signing/caller tests and all 62 Python tests
passed. The unchanged Swift baseline passed 1,107 tests. Two actual packaged apps
passed strict verification with identical DRs and distinct CDHashes; no installed
app or existing credential was accessed. Independent native Codex implementation
review approved the diff; the PR receives a separate Grok/Astra review.
