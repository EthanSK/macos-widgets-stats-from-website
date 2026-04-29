#!/usr/bin/env bash
set -euo pipefail

xcodegen
xcodebuild -project MacosWidgetsStatsFromWebsite.xcodeproj -scheme MacosWidgetsStatsFromWebsite -configuration Debug build
