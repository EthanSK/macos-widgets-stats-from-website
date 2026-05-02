#!/usr/bin/env bash
set -euo pipefail

xcodegen
xcodebuild -project MacosWidgetsStatsFromWebsite.xcodeproj -scheme MacosWidgetsStatsFromWebsite -configuration Debug build

# Defensively reset any stale TCC SystemPolicyAppData grant for this bundle.
# Debug builds use unsandboxed entitlements so this prompt should never fire,
# but if a previous (sandboxed) Debug build left an auth_value=5 row in TCC.db,
# resetting it ensures the next launch starts clean.
# Failure here is non-fatal — the bundle just may not have a row yet.
tccutil reset SystemPolicyAppData com.ethansk.macos-widgets-stats-from-website >/dev/null 2>&1 || true
