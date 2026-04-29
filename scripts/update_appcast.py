#!/usr/bin/env python3
"""Update the Sparkle appcast used by GitHub Pages."""

from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ATOM_NS = "http://www.w3.org/2005/Atom"
SPARKLE = f"{{{SPARKLE_NS}}}"

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("atom", ATOM_NS)


def require(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        print(f"update_appcast.py: missing {name}", file=sys.stderr)
        sys.exit(1)
    return value


def load_or_create(path: Path) -> tuple[ET.ElementTree, ET.Element]:
    if path.exists():
        tree = ET.parse(path)
        channel = tree.getroot().find("channel")
        if channel is None:
            print(f"update_appcast.py: {path} is missing <channel>", file=sys.stderr)
            sys.exit(1)
        return tree, channel

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "macOS Stats Widget Updates"
    ET.SubElement(channel, "link").text = "https://ethansk.github.io/macos-stats-widget/"
    ET.SubElement(channel, "description").text = "Automatic update feed for macOS Stats Widget."
    ET.SubElement(channel, "language").text = "en"
    atom_link = ET.SubElement(channel, f"{{{ATOM_NS}}}link")
    atom_link.set("href", "https://ethansk.github.io/macos-stats-widget/appcast.xml")
    atom_link.set("rel", "self")
    atom_link.set("type", "application/rss+xml")
    return ET.ElementTree(rss), channel


def build_item() -> ET.Element:
    version = require("VERSION")
    display_version = require("DISPLAY_VERSION")
    build_number = require("BUILD_NUMBER")
    release_tag = require("RELEASE_TAG")
    zip_filename = require("ZIP_FILENAME")
    zip_size = require("ZIP_SIZE")
    ed_signature = require("ED_SIGNATURE")
    repo = os.environ.get("REPO", "EthanSK/macos-stats-widget")
    min_macos = os.environ.get("MIN_MACOS", "13.0")
    release_notes_url = os.environ.get(
        "RELEASE_NOTES_URL",
        f"https://github.com/{repo}/releases/tag/{release_tag}",
    )
    pub_date = os.environ.get("PUB_DATE") or datetime.now(timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S +0000"
    )

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"macOS Stats Widget v{display_version}"
    ET.SubElement(item, "pubDate").text = pub_date
    ET.SubElement(item, f"{SPARKLE}version").text = build_number
    ET.SubElement(item, f"{SPARKLE}shortVersionString").text = version
    ET.SubElement(item, f"{SPARKLE}minimumSystemVersion").text = min_macos
    ET.SubElement(item, f"{SPARKLE}releaseNotesLink").text = release_notes_url

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set(
        "url",
        f"https://github.com/{repo}/releases/download/{release_tag}/{zip_filename}",
    )
    enclosure.set("length", zip_size)
    enclosure.set("type", "application/octet-stream")
    enclosure.set(f"{SPARKLE}version", build_number)
    enclosure.set(f"{SPARKLE}shortVersionString", version)
    enclosure.set(f"{SPARKLE}edSignature", ed_signature)
    return item


def upsert_item(channel: ET.Element, item: ET.Element, version: str) -> None:
    for existing in channel.findall("item"):
        short = existing.find(f"{SPARKLE}shortVersionString")
        if short is not None and (short.text or "").strip() == version:
            index = list(channel).index(existing)
            channel.remove(existing)
            channel.insert(index, item)
            return

    for index, child in enumerate(list(channel)):
        if child.tag == "item":
            channel.insert(index, item)
            return
    channel.append(item)


def main() -> int:
    appcast_path = Path(os.environ.get("APPCAST_PATH", "appcast.xml"))
    appcast_path.parent.mkdir(parents=True, exist_ok=True)
    tree, channel = load_or_create(appcast_path)
    item = build_item()
    upsert_item(channel, item, require("VERSION"))
    ET.indent(tree, space="  ")
    tree.write(appcast_path, xml_declaration=True, encoding="utf-8")
    print(f"wrote {appcast_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
