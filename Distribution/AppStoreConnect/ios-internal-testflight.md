# Signeur iOS internal TestFlight

## App record

- Platform: iOS
- Name: Signeur
- Primary language: English (U.S.)
- Bundle ID: `org.trustroots.signeur`
- SKU: `signeur-ios`
- Internal group: `Trustroots Foundation`
- Distribution milestone: internal TestFlight only

Foundation input still required before upload:

- Support contact name, email, and phone
- Public privacy-policy URL
- Completed App Store Connect agreements
- Export-compliance determination for NIP-04, NIP-44, and secp256k1

Do not add `ITSAppUsesNonExemptEncryption` to the app until the Foundation has answered Apple's encryption questions. Set the property to the value resulting from that determination; leaving it unset makes App Store Connect ask during build processing.

## Beta description

Signeur is a Nostr signing app. It stores an imported secret key in the iOS Keychain and lets the owner review and approve Nostr Connect requests from other apps without sharing the secret key.

## Testing notes

Import a test Nostr secret key and authenticate with Face ID when prompted. Scan a Nostr Connect QR code from a compatible client. Review the client name, relay, requested permissions, and public key before approving or declining. After approval, confirm the client appears under Connected, can request a signature, reconnects after Signeur is relaunched, and stops working after it is disconnected.

The secret key is stored locally in the iOS Keychain. Test only with a disposable key; do not use a key that controls valuable funds or an important identity.

## Build and upload

1. Add the maintainer's Apple Account to the Trustroots Foundation developer team and App Store Connect with Developer and App Manager access as needed.
2. Register `org.trustroots.signeur` and create the app record above.
3. Set an unused integer build number. Build numbers must always increase.
4. Run:

   ```sh
   APPLE_TEAM_ID=<foundation-team-id> BUILD_NUMBER=<next-number> Scripts/archive-ios.sh
   ```

5. Open the archive in Xcode Organizer, validate it, and upload it with symbols.
6. Complete export-compliance processing using the Foundation's determination.
7. Add the accepted build to the internal `Trustroots Foundation` group.

## Acceptance pass

- Install from TestFlight on a device that has no `com.k.*` build data.
- Import a disposable key and unlock it with Face ID.
- Approve and decline QR pairing requests.
- Sign from an approved client.
- Relaunch Signeur and confirm the key and connection persist.
- Disconnect the client and confirm subsequent requests are rejected.

External TestFlight, screenshots, pricing, and public App Review are intentionally out of scope for 0.1.0.

References: [Apple export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance), [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview).
