Signstr 0.1.0 is a beta release for macOS 14 Sonoma and later.

## Install

1. Download `Signstr-0.1.0-macOS.dmg` and its `.sha256` checksum.
2. Verify the checksum with `shasum -a 256 -c Signstr-0.1.0-macOS.dmg.sha256`.
3. Open the DMG and drag Signstr into Applications.
4. Open Signstr normally. The app is signed by Trustroots Foundation and notarized by Apple, so bypassing Gatekeeper is not required.

## Security and updates

Signstr keeps imported Nostr secret keys in the system Keychain and asks for biometric or device authentication before sensitive operations. Pairing requests must be explicitly approved.

This beta does not update itself. Follow the GitHub Releases page for newer versions, then replace the app in Applications. Do not delete the key from inside Signstr when upgrading; Keychain data is expected to remain available to releases using the same Foundation identity.

The new `org.trustroots.signstr.mac` identity is separate from older `com.k.*` development builds. Keys and connections from those builds are not migrated.
