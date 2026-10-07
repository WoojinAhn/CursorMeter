# Local development signing

CursorMeter normally packages apps with ad-hoc signing. You can opt into a reusable
Apple Development identity so successive local builds have a stable signing
requirement. This is for developers replacing their own local builds. It does not
change downloaded releases or resolve their update-time Keychain prompts; public
Developer ID signing and notarization are tracked separately in [#31](https://github.com/WoojinAhn/CursorMeter/issues/31).

## One-time setup

1. In Xcode, open **Settings → Accounts**, sign in to your Apple Account, and select
   your team. A free account appears as **Personal Team**.
2. Open **Manage Certificates → + → Apple Development**. Keep the certificate and
   its private key on this Mac. A certificate without its private key cannot sign.
3. List usable signing identities:

   ```bash
   security find-identity -v -p codesigning
   ```

   Copy the 40 hexadecimal characters for your Apple Development identity.
   The signing option accepts this fingerprint, not the display name.

Apple Development certificates can be issued without paid Developer Program
membership ([Apple WWDR certificate policy, §4.2](https://images.apple.com/certificateauthority/pdf/Apple_WWDR_CPS_v3.0.pdf)).
This does not include Developer ID signing or notarization for public distribution.

If Xcode shows the certificate but the command lists no valid identity, inspect
its certificate chain. A missing WWDR intermediate can cause this. Follow
[Apple's targeted issuer diagnosis](https://developer.apple.com/forums/thread/712043)
and install the matching public intermediate from [Apple PKI](https://www.apple.com/certificateauthority/).
Apple-issued certificates use system trust defaults; do not override them to
Always Trust. Do not export your private key to the repository.

## Build and verify

From the repository root:

```bash
CM_DEV_SIGNING_IDENTITY='YOUR_40_HEX_SHA1' bash Scripts/package_app.sh
codesign --verify --deep --strict CursorMeter.app
codesign -d -r- CursorMeter.app
```

Replace the placeholder with your fingerprint. The designated requirement must
contain `com.woojin.CursorMeter` and your exact leaf certificate fingerprint.
Paths containing spaces are supported through the existing `APP_OUTPUT_DIR` option.
The app remains a dev build; selecting a certificate does not enable release updates.

The value applies only to that invocation. To use it for multiple local builds,
export it in your current shell and reuse the same certificate. Do not commit a
machine-specific signing setting. The screenshot helper also inherits this
variable and packages successfully before stopping or replacing the installed app.

An explicitly empty value, a certificate name, `-`, malformed fingerprints, or
any explicit override with `BUILD_CHANNEL=release` fails. Signing or verification
failures stop packaging; the script never retries with ad-hoc signing.

## Keychain behavior and limits

Reusing the certificate and bundle identifier preserves the signing requirement
across builds. macOS still applies Keychain access controls separately. The first
transition from an ad-hoc build or another signer can require authorization.
Switching to a downloaded release can require authorization again.

Verification for this change uses a synthetic item in a disposable private
Keychain: different A/B builds must read and update it with authentication UI
disabled; ad-hoc and different-identifier controls must fail to read it. This does
not migrate your existing login-Keychain item's permissions or prove behavior on
all macOS versions. It does not grant all-apps access or alter item partitions.

Retain the same identity. Certificate replacement changes the leaf-pinned
requirement and can require a new access grant; check expiration in Xcode.
Never remove an existing credential or relax its access controls to bypass a prompt.

Measured on macOS 26.6.2 (Apple Silicon): the isolated read/update and negative
controls passed, cleanup succeeded, and search/default preferences were unchanged.
Two packaged CursorMeter apps also passed strict signature checks with identical
requirements and different CDHashes; neither app was installed or used to read
existing credentials.

## Return to the default

```bash
unset CM_DEV_SIGNING_IDENTITY
bash Scripts/package_app.sh
```

Unsetting restores ad-hoc signing. Setting the variable to an empty string is an
explicit misconfiguration and fails. No certificate is revoked or deleted by
changing this option. The published release workflow is unchanged.
