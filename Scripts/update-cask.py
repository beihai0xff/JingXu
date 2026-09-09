#!/usr/bin/env python3
"""Create a GitHub Contents API CAS payload from a published release digest."""
import base64
import json
from pathlib import Path
import re
import sys


def payload(release, current):
    tag = release["tag_name"]
    if release["draft"] or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("Only published numeric version releases are supported")
    version = tag[1:]
    name = f"JingXu-{version}-macOS-arm64.dmg"
    assets = [a for a in release["assets"] if a["name"] == name]
    if len(assets) != 1:
        raise ValueError("Expected exactly one DMG")
    asset = assets[0]
    expected_url = f"https://github.com/beihai0xff/JingXu/releases/download/{tag}/{name}"
    if asset["browser_download_url"] != expected_url:
        raise ValueError("Unexpected asset URL")
    digest = asset.get("digest") or ""
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("Missing or invalid server digest")
    body = base64.b64decode(current["content"]).decode()
    old = re.findall(r'^  version "(\d+\.\d+\.\d+)"$', body, re.M)
    hashes = re.findall(r'^  sha256 "([0-9a-f]{64})"$', body, re.M)
    if len(old) != 1 or len(hashes) != 1:
        raise ValueError("Unexpected cask format")
    key = lambda v: tuple(map(int, v.split(".")))
    if key(version) < key(old[0]):
        raise ValueError("Refusing cask downgrade")
    if version == old[0]:
        if hashes[0] != digest[7:]:
            raise ValueError("Existing version digest changed")
        return None
    body = body.replace(f'  version "{old[0]}"', f'  version "{version}"', 1)
    body = body.replace(f'  sha256 "{hashes[0]}"', f'  sha256 "{digest[7:]}"', 1)
    return {"message": f"chore(cask): update JingXu to {version}", "branch": "main",
            "sha": current["sha"], "content": base64.b64encode(body.encode()).decode()}


if __name__ == "__main__":
    result = payload(json.loads(Path(sys.argv[1]).read_text()),
                     json.loads(Path(sys.argv[2]).read_text()))
    if result is not None:
        print(json.dumps(result))
