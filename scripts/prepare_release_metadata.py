#!/usr/bin/env python3
"""Prepare version/build metadata for signed GitHub releases.

The checked-in Info.plists carry the human app version and a small base build
number. For branch/manual GitHub Actions releases, this script can patch the
working tree's Info.plists to a monotonic Sparkle-compatible build number while
leaving the marketing version stable.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP_NAME = "MacosWidgetsStatsFromWebsite"
REPO = "EthanSK/macos-widgets-stats-from-website"
INFO_PLISTS = [
    Path("MacosWidgetsStatsFromWebsite/Apps/MainApp/Info.plist"),
    Path("MacosWidgetsStatsFromWebsite/Apps/WidgetExtension/Info.plist"),
    Path("MacosWidgetsStatsFromWebsite/Apps/CLI/Info.plist"),
]
TAG_RE = re.compile(r"^v(?P<version>\d+\.\d+\.\d+)(?:-build\.(?P<build>\d+))?$")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"prepare_release_metadata.py: {message}", file=sys.stderr)
    sys.exit(1)


def read_plist(relative_path: Path) -> dict:
    path = ROOT / relative_path
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except FileNotFoundError:
        fail(f"missing plist: {relative_path}")


def write_plist(relative_path: Path, payload: dict) -> None:
    path = ROOT / relative_path
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)


def git_tag_exists(tag: str) -> bool:
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}"],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def release_values_for_ref(version: str, base_build: int) -> dict[str, str]:
    ref_type = os.environ.get("GITHUB_REF_TYPE", "branch")
    ref_name = os.environ.get("GITHUB_REF_NAME", "local")
    run_number_raw = os.environ.get("GITHUB_RUN_NUMBER", "0")
    sha = os.environ.get("GITHUB_SHA", "local")

    if not run_number_raw.isdigit():
        fail(f"GITHUB_RUN_NUMBER must be numeric, got {run_number_raw!r}")
    run_number = int(run_number_raw)

    canonical_tag = f"v{version}"
    release_tag = canonical_tag
    build_number = base_build
    release_title = f"macOS Widgets Stats from Website v{version}"
    release_channel = "branch"

    if ref_type == "tag":
        match = TAG_RE.match(ref_name)
        if not match:
            fail(
                f"tag {ref_name!r} is not supported; use v{version} or "
                f"v{version}-build.<number>"
            )
        if match.group("version") != version:
            fail(f"tag {ref_name!r} does not match CFBundleShortVersionString {version!r}")
        release_tag = ref_name
        release_channel = "tag"
        if match.group("build"):
            build_number = base_build * 100000 + int(match.group("build"))
            release_title = f"macOS Widgets Stats from Website v{version} (build {match.group('build')})"
    else:
        # Producer Player-style branch releases: use the canonical version tag
        # once, then deterministic build tags once that tag exists. This keeps
        # Sparkle's numeric build version monotonic for repeat main/master runs
        # without requiring a marketing-version bump on every commit.
        if git_tag_exists(canonical_tag):
            release_tag = f"{canonical_tag}-build.{run_number}"
            build_number = base_build * 100000 + run_number
            release_title = f"macOS Widgets Stats from Website v{version} (build {run_number})"

    zip_filename = f"{APP_NAME}-{release_tag}.zip"
    latest_zip_filename = f"{APP_NAME}-latest.zip"
    release_notes_url = f"https://github.com/{REPO}/releases/tag/{release_tag}"

    return {
        "RELEASE_VERSION": version,
        "RELEASE_DISPLAY_VERSION": version,
        "RELEASE_BASE_BUILD_NUMBER": str(base_build),
        "RELEASE_BUILD_NUMBER": str(build_number),
        "RELEASE_TAG": release_tag,
        "RELEASE_TITLE": release_title,
        "RELEASE_CHANNEL": release_channel,
        "RELEASE_COMMIT_SHA": sha,
        "RELEASE_REPO": REPO,
        "RELEASE_NOTES_URL": release_notes_url,
        "ASSET_ZIP_FILENAME": zip_filename,
        "LATEST_ZIP_FILENAME": latest_zip_filename,
        "LATEST_ZIP_URL": f"https://github.com/{REPO}/releases/latest/download/{latest_zip_filename}",
        "VERSIONED_ZIP_URL": f"https://github.com/{REPO}/releases/download/{release_tag}/{zip_filename}",
    }


def patch_info_plists(version: str, build_number: str) -> None:
    for relative_path in INFO_PLISTS:
        payload = read_plist(relative_path)
        payload["CFBundleShortVersionString"] = version
        payload["CFBundleVersion"] = build_number
        write_plist(relative_path, payload)


def write_key_values(path: str | None, values: dict[str, str]) -> None:
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        for key, value in values.items():
            if "\n" in value:
                fail(f"refusing to write multiline value for {key}")
            handle.write(f"{key}={value}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply-plists", action="store_true", help="patch Info.plists to RELEASE_BUILD_NUMBER")
    parser.add_argument("--github-env", default=os.environ.get("GITHUB_ENV"), help="append release env vars to this file")
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"), help="append release outputs to this file")
    args = parser.parse_args()

    main_plist = read_plist(INFO_PLISTS[0])
    version = str(main_plist.get("CFBundleShortVersionString", "")).strip()
    base_build_raw = str(main_plist.get("CFBundleVersion", "")).strip()

    if not SEMVER_RE.match(version):
        fail(f"CFBundleShortVersionString must be x.y.z, got {version!r}")
    if not base_build_raw.isdigit():
        fail(f"CFBundleVersion must be numeric, got {base_build_raw!r}")

    base_build = int(base_build_raw)
    values = release_values_for_ref(version, base_build)

    if args.apply_plists:
        patch_info_plists(version, values["RELEASE_BUILD_NUMBER"])

    write_key_values(args.github_env, values)
    write_key_values(args.github_output, values)

    for key in sorted(values):
        print(f"{key}={values[key]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
