# Mac App Store / TestFlight assessment

This repo is **not** configured to submit to App Store Connect yet. The current production-ready distribution path is Developer ID notarization + GitHub Releases + Sparkle.

## Why there is no App Store workflow yet

A safe App Store/TestFlight workflow needs decisions and credentials that should not be guessed in CI:

- an App Store Connect app record and bundle-id ownership confirmation
- Apple Distribution certificate and provisioning profiles for the app and widget extension
- App Store Connect API key (`Issuer ID`, `Key ID`, `.p8`) or an approved manual upload process
- entitlement review for the app group, widget extension, network access, and embedded local MCP server behavior
- product-policy review for a tool that signs users into arbitrary third-party websites and displays scraped values
- a packaging decision for the CLI/MCP helper, because Mac App Store apps cannot rely on the same Developer ID distribution assumptions as the direct download build

Until those are resolved, an automatic upload workflow would be more likely to fail or publish the wrong shape of product than to help.

## Safe future skeleton

When Ethan explicitly approves App Store work, add a separate `workflow_dispatch`-only workflow. It should be gated behind App Store-specific secrets and should never run from ordinary `main` pushes.

Likely required secrets:

| Secret | Purpose |
| --- | --- |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API issuer UUID. |
| `APP_STORE_CONNECT_KEY_ID` | API key ID. |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Contents of the `.p8` private key. |
| `APPLE_DISTRIBUTION_CERTIFICATE_P12_BASE64` | Base64 Apple Distribution certificate. |
| `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password for that `.p12`. |
| `APP_STORE_TEAM_ID` | Apple Developer team ID if different from Developer ID releases. |

Recommended first implementation:

1. archive with App Store signing/export options into an `.ipa`/`.pkg`-appropriate upload artifact for macOS
2. validate entitlements and bundle ids before upload
3. upload to TestFlight only, not App Store release
4. require manual review/promotion in App Store Connect

Do not reuse the Sparkle Developer ID release workflow for App Store submission. Keep the channels separate so direct-download users, Sparkle appcasts, and App Store/TestFlight builds cannot overwrite each other's signing assumptions.
