# Signeur 0.1.0 next steps

Follow these phases in order. Do not create `v0.1.0` until phases 1–3 are complete; pushing the tag starts the macOS publishing workflow.

## 1. Return the repository to green

Owner: Signeur maintainers.

1. Finish or reconcile the current security and test-fixture changes.
2. Run `swift test` and confirm every test passes from a clean build.
3. Push the finished changes to `main` and confirm the normal GitHub Actions workflow passes.
4. Confirm there are no uncommitted release changes and no credentials, certificates, provisioning profiles, or private keys in the repository.

Stop here if tests or either unsigned build fails. The macOS release workflow repeats these checks and will refuse to publish.

## 2. Complete the Foundation Apple setup

Owner: Trustroots Foundation Apple Account Holder or Admin.

1. Add the maintainer's Apple Account to the Trustroots Foundation Apple Developer team and App Store Connect. Grant the Developer role and enough App Manager access to manage the Signeur record and TestFlight group.
2. Register these explicit App IDs:

   - `org.trustroots.signeur`
   - `org.trustroots.signeur.mac`

3. Create the iOS App Store Connect record using English (U.S.) and SKU `signeur-ios`.
4. Create a Developer ID Application certificate and a Developer ID provisioning profile for the Mac identifier. The profile must authorize the Keychain group `<Foundation Team ID>.org.trustroots.signeur.mac`.
5. Create an App Store Connect API key that can submit software to Apple's notarization service.
6. Supply the Foundation team ID, support contact, and public privacy-policy URL.
7. Accept all outstanding Apple Developer and App Store Connect agreements.
8. Complete Apple's encryption questionnaire for NIP-04, NIP-44, and secp256k1. Record Apple's determination; do not assume Signeur is exempt.

Keep certificates and private keys out of chat, issues, commits, and release artifacts.

## 3. Load the protected GitHub environment

Owner: repository administrator.

The `macos-release` environment has already been created for `guaka/signeur`. It accepts only `v*` tags and requires approval from `guaka`. Add every secret listed in [README.md](README.md#macos-github-environment), then check that none is empty.

Do not put the same values in repository variables or plaintext workflow files. The environment should remain protected after the release.

## 4. Publish the internal iOS beta

Owner: maintainer with Foundation signing access.

1. Fill in the support contact, privacy-policy URL, beta description, and testing notes from [AppStoreConnect/ios-internal-testflight.md](AppStoreConnect/ios-internal-testflight.md).
2. Choose the next unused integer build number and create the archive:

   ```sh
   APPLE_TEAM_ID=<foundation-team-id> BUILD_NUMBER=<next-number> Scripts/archive-ios.sh
   ```

3. Open the archive in Xcode Organizer, validate it, and upload it with symbols.
4. Complete build processing and export-compliance questions using the recorded Foundation determination.
5. Create the internal TestFlight group `Trustroots Foundation` and add the accepted build.
6. Install from TestFlight and complete the acceptance checklist in the iOS guide.

Stop at internal TestFlight. Do not configure external testing or submit the app for public review as part of 0.1.0.

## 5. Publish the notarized Mac beta

Owner: maintainer and Foundation release approver.

1. Confirm `main` and its CI checks are green and that GitHub does not already contain the `v0.1.0` tag or release.
2. Create and push the immutable tag:

   ```sh
   git tag -a v0.1.0 -m "Signeur 0.1.0"
   git push origin v0.1.0
   ```

3. Review and approve the pending `macos-release` environment deployment.
4. Wait for the workflow to test, build, sign, notarize, staple, validate, checksum, and publish both files.
5. Confirm the GitHub entry is a prerelease containing exactly:

   - `Signeur-0.1.0-macOS.dmg`
   - `Signeur-0.1.0-macOS.dmg.sha256`

6. Complete [macOS/acceptance-checklist.md](macOS/acceptance-checklist.md) on a clean non-development Mac.

Do not manually upload an unvalidated replacement. If a tagged release is faulty, withdraw it, increase the version and build number, and publish a new immutable tag.

## 6. Record completion

The 0.1.0 milestone is complete only when:

- The iOS build installs from the internal Foundation TestFlight group and passes its device checks.
- The Mac DMG installs without a Gatekeeper bypass and passes the clean-Mac and upgrade checks.
- The GitHub checksum matches the published DMG.
- Apple signing identities, bundle identifiers, version, entitlements, and notarization are correct.
- No release credential appears in logs, source control, the DMG, or its checksum file.

Record the iOS build number, TestFlight upload date, Mac GitHub Actions run, DMG checksum, test devices, and acceptance results in the release issue or Foundation release log—without copying any secrets.
