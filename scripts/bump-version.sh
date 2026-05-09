#!/usr/bin/env bash
# bump-version.sh — increment the patch version of MARKETING_VERSION in
# project.yml (and bump CURRENT_PROJECT_VERSION by one as well, since the
# Sparkle build number must be monotonic). Then runs xcodegen to refresh
# the generated Info.plists.
#
# Usage:
#   ./scripts/bump-version.sh                    # patch bump (default)
#   ./scripts/bump-version.sh minor              # minor bump, resets patch
#   ./scripts/bump-version.sh major              # major bump, resets minor+patch
#   ./scripts/bump-version.sh set 0.13.0         # set explicit version

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="$REPO_ROOT/project.yml"

if [[ ! -f "$PROJECT_YML" ]]; then
    echo "bump-version.sh: ERROR — project.yml not found at $PROJECT_YML" >&2
    exit 1
fi

mode="${1:-patch}"
explicit=""

if [[ "$mode" == "set" ]]; then
    explicit="${2:-}"
    if [[ -z "$explicit" ]]; then
        echo "bump-version.sh: ERROR — 'set' requires an explicit X.Y.Z version" >&2
        exit 1
    fi
    if ! [[ "$explicit" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "bump-version.sh: ERROR — version must be x.y.z, got '$explicit'" >&2
        exit 1
    fi
fi

current_version="$(grep -E '^[[:space:]]*MARKETING_VERSION:[[:space:]]*"[^"]+"' "$PROJECT_YML" \
    | head -n1 \
    | sed -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([^"]+)".*$/\1/')"
current_build="$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"[^"]+"' "$PROJECT_YML" \
    | head -n1 \
    | sed -E 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"([^"]+)".*$/\1/')"

if [[ -z "$current_version" || -z "$current_build" ]]; then
    echo "bump-version.sh: ERROR — could not read MARKETING_VERSION/CURRENT_PROJECT_VERSION" >&2
    exit 1
fi

IFS='.' read -r major minor patch <<<"$current_version"

case "$mode" in
    patch)
        new_version="${major}.${minor}.$((patch + 1))"
        ;;
    minor)
        new_version="${major}.$((minor + 1)).0"
        ;;
    major)
        new_version="$((major + 1)).0.0"
        ;;
    set)
        new_version="$explicit"
        ;;
    *)
        echo "bump-version.sh: ERROR — unknown mode '$mode' (expected patch|minor|major|set)" >&2
        exit 1
        ;;
esac

new_build=$((current_build + 1))

echo "bump-version.sh: $current_version (build $current_build) -> $new_version (build $new_build)"

# In-place edit, BSD sed compatible.
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*\")[^\"]+(\")/\1${new_version}\2/" "$PROJECT_YML"
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*\")[^\"]+(\")/\1${new_build}\2/" "$PROJECT_YML"

if command -v xcodegen >/dev/null 2>&1; then
    echo "bump-version.sh: regenerating Xcode project + Info.plists with xcodegen"
    (cd "$REPO_ROOT" && xcodegen)
else
    echo "bump-version.sh: WARN — xcodegen not on PATH; skipping plist regeneration" >&2
fi

echo "bump-version.sh: done. Stage project.yml + the regenerated plists and commit."
