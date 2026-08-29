<p align="center">
  <img src="iOSApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="180" alt="Signeur app icon">
</p>

<h1 align="center">Signeur</h1>

Signeur is a Nostr signer for iPhone and Mac. Both apps share the same NIP-46,
NIP-55, relay, permission, and signing core while using platform-native SwiftUI
shells.

[Browse the latest SigneurCore coverage report](https://guaka.github.io/signeur/),
published from each successful `main` build with per-file annotated source.

## How to use Signeur

1. Open **Keys** and create a new key, or import an existing `nsec` private key.
2. In a Nostr app, choose **Nostr Connect** or **remote signer**, then scan its
   code on iPhone or paste its connection link on Mac.
3. Read each request and approve only the actions you expect.

**Nostr** is an open social network where apps exchange messages through relays.
Your **public key** (`npub`) is your shareable identity. Your **private key**
(`nsec`) controls that identity: keep it secret, and only import it into apps
you trust. Signeur keeps the private key on your device and uses it when you
approve a request.

Source code: [github.com/guaka/signeur](https://github.com/guaka/signeur)

## Run the apps

Open `Signeur.xcodeproj` and select either the `Signeur` iOS scheme or the
`SigneurMac` macOS scheme. The Mac app pairs through Nostr Connect links opened
directly or pasted from the clipboard; QR camera scanning is available in the
iPhone app.

Private keys are stored as biometric-protected Keychain items. Key use requires
Touch ID on Mac or Face ID/Touch ID on iPhone when available, with the device
password/passcode as the system fallback. Apple Secure Enclave hardware cannot
perform Nostr's secp256k1 signatures directly, so Signeur performs the Nostr
operation in memory only after the Keychain access check succeeds.

## Distribution

Release preparation lives in [Distribution/README.md](Distribution/README.md). For the ordered 0.1.0 handoff, start with [Distribution/NEXT_STEPS.md](Distribution/NEXT_STEPS.md).

## License

Signeur is licensed under the [GNU Affero General Public License v3.0](LICENSE).
