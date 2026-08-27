# macOS 0.1.0 acceptance checklist

Run this on a macOS 14 or later Mac that does not have Xcode, Apple development certificates, or a previous Foundation-signed Signstr installation.

- Download the DMG and checksum from the `v0.1.0` GitHub prerelease.
- Verify `shasum -a 256 -c Signstr-0.1.0-macOS.dmg.sha256` succeeds.
- Open the DMG and copy Signstr to Applications.
- Launch Signstr normally and confirm Gatekeeper does not require a bypass.
- Import a disposable Nostr key and unlock it with Touch ID or the Mac login password.
- Pair with a compatible client and approve the connection.
- Sign a request, then confirm the connected-app metadata reflects the activity.
- Quit and relaunch Signstr; confirm the key, connection, and signing flow still work.
- Disconnect the client and confirm later requests are rejected.
- Install a newer Foundation-signed test build over the app without deleting Signstr data; confirm the Keychain key and connection survive.
- Confirm the app reports bundle ID `org.trustroots.signstr.mac` and version `0.1.0` in System Information or signature inspection.

Record the Mac model, macOS version, build numbers tested, checksum, and any failure. Do not publish if any item fails.
