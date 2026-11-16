#!/usr/bin/env python3
"""Describe a built IPA for the release feed.

SideStore (and AltStore) refuse to install an app whose download doesn't match
what the source promised: the version, the build number, the exact byte size
and the SHA-256 are all checked against the IPA after it downloads. So nothing
in the feed is typed by hand or derived from a tag name - this script reads the
values out of the IPA that was actually built and writes them to a small JSON
file that ships as a release asset next to it. `build_source.py` assembles the
feed from those files.

    python3 scripts/ipa_info.py HIIT-unsigned.ipa \
        --entitlements app-entitlements.plist \
        --expect-version 1.0.31 --expect-build 57 --min-sdk 27.1 \
        --output release.json

Standard library only, so it runs on a bare CI runner.
"""

import argparse
import hashlib
import json
import os
import plistlib
import re
import sys
import zipfile

SCHEMA = 1

# NSCameraUsageDescription, NSHealthShareUsageDescription, ... - the keys iOS
# shows the user when it asks for a permission.
PRIVACY_KEY = re.compile(r"^NS[A-Za-z0-9]+UsageDescription$")

# Present in every signed app and different for every signer - not a
# capability worth listing.
IGNORED_ENTITLEMENTS = {"application-identifier", "com.apple.developer.team-identifier"}


class IPAError(Exception):
    """The archive isn't a usable IPA, or doesn't match what was expected."""


def _version_tuple(text):
    numbers = re.findall(r"\d+", text or "")
    return tuple(int(n) for n in numbers)


def _load_entitlements(path):
    """Keys of a `codesign -d --entitlements` plist; {} for an unsigned binary."""
    with open(path, "rb") as handle:
        data = handle.read()
    start = data.find(b"<?xml")
    if start < 0:
        start = data.find(b"<plist")
    if start < 0:
        return {}
    try:
        loaded = plistlib.loads(data[start:])
    except Exception as error:  # plistlib raises several unrelated types
        raise IPAError(f"{path}: not a readable entitlements plist ({error})") from error
    return loaded if isinstance(loaded, dict) else {}


def describe(ipa_path, entitlement_plists=()):
    """Return the release description for the IPA at `ipa_path`."""
    try:
        archive = zipfile.ZipFile(ipa_path)
    except (zipfile.BadZipFile, OSError) as error:
        raise IPAError(f"{ipa_path}: not a readable IPA ({error})") from error

    with archive:
        names = archive.namelist()
        app_plists = [n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(app_plists) != 1:
            raise IPAError(f"{ipa_path}: expected exactly one app in Payload/, found {len(app_plists)}")
        app_root = app_plists[0][: -len("Info.plist")]
        extension_pattern = re.compile(re.escape(app_root) + r"PlugIns/[^/]+\.appex/Info\.plist")
        extension_plists = sorted(n for n in names if extension_pattern.fullmatch(n))
        try:
            info = plistlib.loads(archive.read(app_plists[0]))
            extensions = [plistlib.loads(archive.read(n)) for n in extension_plists]
        except Exception as error:
            raise IPAError(f"{ipa_path}: unreadable Info.plist ({error})") from error

    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
        if not isinstance(info.get(key), str) or not info[key]:
            raise IPAError(f"{ipa_path}: Info.plist has no {key}")

    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    for extension in extensions:
        identifier = extension.get("CFBundleIdentifier", "?")
        if extension.get("CFBundleShortVersionString") != version or extension.get("CFBundleVersion") != build:
            raise IPAError(
                f"extension {identifier} is version "
                f"{extension.get('CFBundleShortVersionString')} ({extension.get('CFBundleVersion')}) "
                f"but the app is {version} ({build}) - iOS rejects mismatched extensions")

    privacy = {}
    for bundle in [info] + extensions:
        for key, value in bundle.items():
            if PRIVACY_KEY.match(key) and isinstance(value, str) and key not in privacy:
                privacy[key] = value

    entitlements = set()
    for path in entitlement_plists:
        for key, value in _load_entitlements(path).items():
            if key in IGNORED_ENTITLEMENTS:
                continue
            if key == "get-task-allow" and value is False:
                continue
            entitlements.add(key)

    digest = hashlib.sha256()
    with open(ipa_path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)

    # Xcode writes per-device lists under "~iphone" / "~ipad" keys; a plain
    # key applies to every device. This is an iPhone app, so take both.
    orientations = set(info.get("UISupportedInterfaceOrientations") or [])
    orientations.update(info.get("UISupportedInterfaceOrientations~iphone") or [])
    return {
        "schema": SCHEMA,
        "ipaName": os.path.basename(ipa_path),
        "bundleIdentifier": info["CFBundleIdentifier"],
        "name": info.get("CFBundleDisplayName") or info.get("CFBundleName") or info["CFBundleIdentifier"],
        "version": version,
        "buildVersion": build,
        "minOSVersion": str(info.get("MinimumOSVersion", "")),
        "size": os.path.getsize(ipa_path),
        "sha256": digest.hexdigest(),
        "sdk": str(info.get("DTSDKName", "")),
        "xcode": str(info.get("DTXcode", "")),
        "orientations": sorted(str(o) for o in orientations),
        "extensions": sorted(str(e.get("CFBundleIdentifier", "")) for e in extensions),
        "entitlements": sorted(entitlements),
        "privacy": dict(sorted(privacy.items())),
    }


def check(description, expect_version=None, expect_build=None, min_sdk=None, require_orientations=False):
    """Raise IPAError when the build isn't the one the pipeline meant to make."""
    if expect_version and description["version"] != expect_version:
        raise IPAError(
            f"the IPA is version {description['version']} but {expect_version} was expected - "
            "the version override didn't reach the build")
    if expect_build and description["buildVersion"] != expect_build:
        raise IPAError(
            f"the IPA is build {description['buildVersion']} but {expect_build} was expected - "
            "the build-number override didn't reach the build")
    if not re.fullmatch(r"\d+\.\d+\.\d+", description["version"]):
        raise IPAError(
            f"version {description['version']!r} isn't MAJOR.MINOR.PATCH - SideStore compares versions "
            "semantically and would not see later builds as updates")
    if min_sdk:
        built_with = _version_tuple(description["sdk"])
        if not built_with or built_with < _version_tuple(min_sdk):
            raise IPAError(
                f"built with SDK {description['sdk'] or 'unknown'}; {min_sdk} or later is required "
                "(older SDKs run letterboxed on iPhone Duo)")
    if require_orientations:
        wanted = {
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        }
        missing = wanted - set(description["orientations"])
        if missing:
            raise IPAError(
                "the app doesn't declare " + ", ".join(sorted(missing)) + " - without every orientation "
                "iPhone Duo scales the app on its inner display instead of laying it out natively")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("ipa")
    parser.add_argument("--entitlements", action="append", default=[], metavar="PLIST",
                        help="output of `codesign -d --entitlements`; repeat for each signed bundle")
    parser.add_argument("--expect-version")
    parser.add_argument("--expect-build")
    parser.add_argument("--min-sdk")
    parser.add_argument("--require-all-orientations", action="store_true")
    parser.add_argument("--output", "-o", default="-")
    args = parser.parse_args(argv)

    try:
        description = describe(args.ipa, args.entitlements)
        check(description, args.expect_version, args.expect_build, args.min_sdk, args.require_all_orientations)
    except IPAError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    text = json.dumps(description, indent=2, sort_keys=False) + "\n"
    if args.output == "-":
        sys.stdout.write(text)
    else:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(text)
        print(f"{description['name']} {description['version']} ({description['buildVersion']}) - "
              f"{description['size']:,} bytes, SDK {description['sdk']}, iOS {description['minOSVersion']}+")
    return 0


if __name__ == "__main__":
    sys.exit(main())
