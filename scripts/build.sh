#!/usr/bin/env bash
set -euo pipefail

xcodegen
xcodebuild -project MacosStatsWidget.xcodeproj -scheme MacosStatsWidget -configuration Debug build
