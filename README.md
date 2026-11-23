# Simulator Manager

A native macOS app for keeping Xcode's simulators under control.

- **Devices:** launch any installed simulator, shut it down or delete it.
- **Running:** see booted simulators, bring a device's window to the front, or shut it down.
- **Runtimes:** see each simulator runtime's version, build and size, and delete the ones you don't need.
- **Data Folders:** see how much space each simulator's data uses, delete folders, and clean up orphans:
  folders whose runtime is gone, or that CoreSimulator no longer knows about. Cleanup can run
  automatically after you delete runtimes, or on launch (Settings).
- Every table sorts by OS version and supports multi-select. The bar above each table selects rows by
  version, for example "iOS runtimes lower than 18.0", so you can delete them all at once.
- Everything runs in the background, so the window never stalls.
- Updates itself with [Sparkle](https://sparkle-project.org): it checks daily, and you can choose
  **Simulator Manager › Check for Updates…** at any time.

Requires macOS 15 and Xcode (for `xcrun simctl`).

## Build & run

```bash
xcodebuild -project SimulatorManager.xcodeproj -scheme SimulatorManager -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/SimulatorManager.app
```

Debug builds are named **Simulator Manager Debug** with their own bundle ID, and never update
themselves, so they can sit alongside an installed release.

Launching or bringing a simulator to the front opens it in Simulator (Xcode 26 and earlier) or
DeviceHub (Xcode 27, which replaced Simulator), then selects that device using the Accessibility API.
Grant access in System Settings › Privacy & Security › Accessibility (Settings has a shortcut).
Without it, the app still boots the simulator and opens the viewer, but you pick the device yourself.

## Releasing

`scripts/release.sh` builds a DMG that's signed with Developer ID and notarized, so it opens on any
Mac without Gatekeeper warnings. It archives a Release build, re-signs Sparkle's helpers, checks the
signatures and hardened runtime, notarizes and staples the app, then packages, signs, notarizes and
staples the DMG. The result is `build/release/SimulatorManager-<version>.dmg`.

To run it locally you need a Developer ID Application certificate in your keychain and notary
credentials saved as a profile:

```bash
xcrun notarytool store-credentials SimulatorManager-Notary --apple-id <your Apple ID> --team-id B4H429V95D
```

To test without notarizing, run `SKIP_NOTARIZATION=1 scripts/release.sh`.

### Automatic releases

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs the same script on GitHub
Actions each time you push to `main`. Pushes that only change docs are skipped. It publishes a GitHub
release tagged `vX.Y.Z`, with the notarized DMG, its SHA-256 checksum and the Sparkle update feed
(`appcast.xml`) attached. Installed copies read the feed from the newest release
(`…/releases/latest/download/appcast.xml`), so publishing a release is all it takes to offer the
update. The release notes list the commit messages since the previous release, so write them for users.

- **Version:** each release bumps the patch number of the newest `vX.Y.Z` tag. Write `#minor` or
  `#major` in a commit message to bump that part instead, or raise `MARKETING_VERSION` in the project
  to jump ahead. The build number is the workflow's run number.
- **Skipping:** write `[skip release]` in a commit message to push without releasing.
- **Manual release:** Actions › Release › Run workflow, then pick patch, minor or major.

Secrets (Settings › Secrets and variables › Actions):

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | The Developer ID Application certificate and private key, as a base64 .p12. |
| `DEVELOPER_ID_P12_PASSWORD` | The .p12's password. |
| `NOTARY_API_KEY_P8`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID` | An App Store Connect API key (Developer role) for notarization. Alternatively set `NOTARY_APPLE_ID` and `NOTARY_APP_PASSWORD`. |
| `SPARKLE_PRIVATE_KEY` | The private EdDSA key that signs updates. |

### Update signing

Sparkle only installs an update whose feed and DMG are signed with the private key matching
`SUPublicEDKey` in [`SimulatorManager/Info.plist`](SimulatorManager/Info.plist), and whose app is signed
by the same Developer ID team. Keep a backup of the private key: if it's lost, installed copies can't
verify new updates. The feed is downloaded without authentication, so the repository must be public.
