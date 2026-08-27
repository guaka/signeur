# Signstr 0.1.0 distribution

Start with [NEXT_STEPS.md](NEXT_STEPS.md) for the ordered Foundation and maintainer handoff.

Trustroots Foundation owns and signs the iOS and macOS releases. The release identities are:

- iOS: `org.trustroots.signstr`
- macOS: `org.trustroots.signstr.mac`
- Version/tag: `0.1.0` / `v0.1.0`
- Mac artifact: `Signstr-0.1.0-macOS.dmg`

These bundle identifiers create a clean installation boundary. Existing `com.k.*` builds remain separate and their Keychain items are not migrated. The URL schemes (`nostrconnect`, `nostrsigner`, and `signstr`) and platform icons are unchanged.

`MARKETING_VERSION` and the initial `CURRENT_PROJECT_VERSION` live in `project.yml`. Release automation overrides the build number with GitHub's monotonically increasing run number. Local iOS archives require an explicitly supplied, unused build number.

## Foundation prerequisites

Before either signed release can run, the Foundation must:

1. Register both bundle identifiers in Certificates, Identifiers & Profiles.
2. Add the maintainer's Apple Account with the necessary Developer and App Manager roles.
3. Accept the current Apple Developer and App Store Connect agreements.
4. Supply the Apple team ID, support contact, and privacy-policy URL.
5. Complete Apple's encryption questionnaire for NIP-04, NIP-44, and secp256k1.

The repository deliberately does not assert an export-compliance exemption. Follow the resulting Apple determination when setting the app property and answering build-processing questions.

## iOS

Follow [AppStoreConnect/ios-internal-testflight.md](AppStoreConnect/ios-internal-testflight.md). This milestone ends after an accepted build has passed the internal TestFlight checklist.

## macOS GitHub environment

The protected GitHub environment named `macos-release` already exists, is limited to `v*` tags, and requires approval from `guaka`. Add these secrets:

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Trustroots Foundation's 10-character team ID |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded Foundation Developer ID Application certificate plus private key |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Password protecting that PKCS#12 file |
| `TEMP_KEYCHAIN_PASSWORD` | Random single-purpose password for the ephemeral CI Keychain |
| `MACOS_DEVELOPER_ID_PROFILE_BASE64` | Base64-encoded Developer ID provisioning profile for `org.trustroots.signstr.mac` and its Keychain group |
| `MACOS_PROVISIONING_PROFILE_NAME` | The profile's exact Name field |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID authorized for notarization |
| `APP_STORE_CONNECT_ISSUER_ID` | API issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Complete contents of the `.p8` private key |

The Developer ID profile must authorize the Keychain group `<Foundation Team ID>.org.trustroots.signstr.mac`. App Sandbox must remain disabled for this direct-download build. Release configuration enables Hardened Runtime.

## macOS release

After all prerequisites and secrets are ready:

1. Ensure `main` is green and the version in `project.yml` is final.
2. Create and push the immutable annotated tag `v0.1.0`.
3. Approve the protected `macos-release` environment deployment.
4. Confirm the workflow publishes the signed DMG and `.sha256` file as a prerelease.
5. Install on a clean, non-development Mac without bypassing Gatekeeper and complete the functional acceptance pass in the release plan.

The workflow refuses mismatched tags and existing releases. It runs tests and unsigned Release builds before importing secrets, then builds a universal Developer ID archive, checks its identity, version, architectures, Keychain entitlement, and Hardened Runtime, creates and signs a DMG, notarizes and staples it, runs Apple signature and Gatekeeper checks, and only then publishes.

Never replace a tag or overwrite a released artifact. Withdraw a faulty prerelease and ship a higher version.

Reference: [Apple notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
