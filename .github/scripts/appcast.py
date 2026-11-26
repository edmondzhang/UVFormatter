"""Build a Sparkle feed from verified GitHub Release metadata."""

import base64
import datetime
import email.utils
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)
MINIMUM_OS = "14.0"


def version_parts(tag):
    parts = re.fullmatch(r"v(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})", tag)
    if parts is None:
        raise ValueError("Release tag must be vX.Y.Z with components in 0…999")
    return [int(part) for part in parts.groups()]


def build_number(tag):
    major, minor, patch = version_parts(tag)
    return str(1 + ((major * 1000) + minor) * 1000 + patch)


def decode_key(value, size):
    decoded = base64.b64decode(value, validate=True)
    if len(decoded) != size:
        raise ValueError("Invalid Sparkle signature or public key length")
    return decoded


def record(tag, archive):
    """Record the archive digest and Sparkle signature for durable feed reconstruction."""
    metadata = ET.fromstring("<asset " + sys.stdin.read().strip().replace("sparkle:", "") + "/>")
    signature = metadata.attrib["edSignature"]
    decode_key(signature, 64)
    data = archive.read_bytes()
    if len(data) != int(metadata.attrib["length"]):
        raise ValueError("Sparkle archive length does not match")
    # Validate the signature with the key users actually have in the App.
    subprocess.run(
        ["swift", ".github/scripts/verify-update.swift", str(archive), signature],
        check=True,
    )
    return {
        "tag": tag,
        "build": build_number(tag),
        "asset": archive.name,
        "length": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "signature": signature,
    }


def gh_json(*args):
    return json.loads(subprocess.check_output(["gh", *args], text=True))


def sparkle(name):
    return f"{{{SPARKLE_NS}}}{name}"


def publish_feed(directory):
    """Include only public stable releases with intact signed publication records."""
    repo = os.environ["GITHUB_REPOSITORY"]
    releases = gh_json("release", "list", "--repo", repo, "--exclude-drafts",
                       "--exclude-pre-releases", "--limit", "100", "--json",
                       "tagName,publishedAt")
    entries = []
    for release in releases:
        tag = release["tagName"]
        details = gh_json("release", "view", tag, "--repo", repo, "--json", "assets,url")
        assets = {asset["name"]: asset for asset in details["assets"]}
        if "update.json" not in assets:
            continue
        metadata = gh_json("release", "download", tag, "--repo", repo,
                           "--pattern", "update.json", "--output", "-")
        expected_name = f"UVFormatter-{tag}.zip"
        asset = assets[expected_name]
        if metadata["tag"] != tag or metadata["build"] != build_number(tag):
            raise ValueError(f"Release version mismatch for {tag}")
        if (metadata["asset"] != expected_name or asset["size"] != metadata["length"]
                or asset["digest"] != "sha256:" + metadata["sha256"]):
            raise ValueError(f"Release asset integrity mismatch for {tag}")
        decode_key(metadata["signature"], 64)
        entries.append((metadata, asset, details["url"], release["publishedAt"]))
    if os.environ["VERSION_TAG"] not in {entry[0]["tag"] for entry in entries}:
        raise ValueError("The requested release is missing from the generated appcast")

    requested_asset = next(asset for metadata, asset, _, _ in entries
                           if metadata["tag"] == os.environ["VERSION_TAG"])
    subprocess.run(["curl", "--head", "--location", "--fail", "--silent",
                    "--show-error", "--retry", "3", "--max-time", "30",
                    "--output", os.devnull, requested_asset["url"]], check=True)

    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "UVFormatter"
    for metadata, asset, url, published in sorted(entries, key=lambda item: int(item[0]["build"]), reverse=True):
        tag = metadata["tag"]
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = f"UVFormatter {tag}"
        ET.SubElement(item, "link").text = url
        date = datetime.datetime.fromisoformat(published.replace("Z", "+00:00"))
        ET.SubElement(item, "pubDate").text = email.utils.format_datetime(date)
        ET.SubElement(item, sparkle("version")).text = metadata["build"]
        ET.SubElement(item, sparkle("shortVersionString")).text = tag[1:]
        ET.SubElement(item, sparkle("minimumSystemVersion")).text = MINIMUM_OS
        ET.SubElement(item, "enclosure", {
            "url": asset["url"],
            "type": "application/octet-stream",
            "length": str(metadata["length"]),
            sparkle("edSignature"): metadata["signature"],
        })
    directory.mkdir(parents=True, exist_ok=True)
    ET.indent(root, space="  ")
    ET.ElementTree(root).write(directory / "appcast.xml", encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    action, *arguments = sys.argv[1:]
    if action == "validate-tag":
        version_parts(arguments[0])
    elif action == "public-key":
        decode_key(os.environ["SPARKLE_PUBLIC_KEY"], 32)
    elif action == "build-number":
        print(build_number(arguments[0]))
    elif action == "record":
        print(json.dumps(record(arguments[0], pathlib.Path(arguments[1]))))
    elif action == "publish-feed":
        publish_feed(pathlib.Path(arguments[0]))
    else:
        raise ValueError("Unknown release metadata action")
