#!/usr/bin/env bash
set -euo pipefail

# Use a stable derived-data path so the post-build verify/sign step can
# locate the .app reliably and so the running binary path stays consistent
# across rebuilds (also helps TCC keep its grants attached to one path).
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build/manual-test-derived}"

xcodegen

# Build Debug with the project's normal automatic signing. This uses
# Ethan's developer cert and produces a signed binary with the
# Debug.entitlements file (app-sandbox=false) embedded — which is what
# stops the macOS Sonoma+ "would like to access data from other apps"
# TCC re-prompt from firing on every rebuild.
#
# Do NOT pass CODE_SIGNING_ALLOWED=NO here. Without signing, the
# entitlements are never embedded, and TCC re-prompts every launch.
xcodebuild \
  -project MacosWidgetsStatsFromWebsite.xcodeproj \
  -scheme MacosWidgetsStatsFromWebsite \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/MacosWidgetsStatsFromWebsite.app"
DEBUG_ENTITLEMENTS="MacosWidgetsStatsFromWebsite/Apps/MainApp/MacosWidgetsStatsFromWebsite.Debug.entitlements"

if [[ ! -d "$APP_PATH" ]]; then
  echo "build.sh: ERROR — expected .app bundle not found at $APP_PATH" >&2
  exit 1
fi

# Verify the build embedded the Debug entitlements (sandbox=false).
# If it didn't (e.g. a previous unsigned build is still cached, or the
# build was run with CODE_SIGNING_ALLOWED=NO outside of this script),
# fall back to ad-hoc signing with the Debug.entitlements file so the
# binary still gets a stable per-machine identity AND the sandbox-off
# entitlement, which is what TCC keys its grant to.
ENTITLEMENTS_OUT=$(codesign -d --entitlements - "$APP_PATH" 2>&1 || true)
if ! grep -q "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS_OUT"; then
  echo "build.sh: entitlements missing after xcodebuild — falling back to ad-hoc sign"
  codesign \
    --force \
    --deep \
    --sign - \
    --entitlements "$DEBUG_ENTITLEMENTS" \
    "$APP_PATH"
  ENTITLEMENTS_OUT=$(codesign -d --entitlements - "$APP_PATH" 2>&1 || true)
fi

# Hard gate: refuse to leave a build artifact without the sandbox=false
# entitlement embedded — without it, TCC will re-prompt on the next launch
# and the c00f30e fix is silently inert.
if ! grep -q "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS_OUT"; then
  echo "build.sh: ERROR — app-sandbox entitlement still not embedded after sign" >&2
  echo "$ENTITLEMENTS_OUT" >&2
  exit 1
fi
echo "build.sh: entitlements verified (com.apple.security.app-sandbox embedded)"

# Defensively reset any stale TCC SystemPolicyAppData grant for this bundle.
# Debug builds use unsandboxed entitlements so this prompt should never fire,
# but if a previous (sandboxed) Debug build left an auth_value=5 row in TCC.db,
# resetting it ensures the next launch starts clean.
# Failure here is non-fatal — the bundle just may not have a row yet.
tccutil reset SystemPolicyAppData com.ethansk.macos-widgets-stats-from-website >/dev/null 2>&1 || true
